@preconcurrency import CoreBluetooth
import Foundation

private let logger = TaggedLogger(tag: "AsyncGattClient")

/// A Bluetooth LE GATT client for one connected peripheral, where each operation awaits
/// CoreBluetooth's answer. Get one from AsyncBleCentral.connect.
///
/// One operation runs at a time: a second call waits until the first has its answer, or times
/// out. If the link drops or Bluetooth is switched off, the pending operation and every queued
/// one fail with GattDisconnectedError.
///
/// CoreBluetooth's answers carry no request id, only the characteristic. A late answer for an
/// operation that already timed out is ignored, unless the operation now waiting is the same kind
/// on the same characteristic: then the late answer completes it. So after a
/// GattOperationTimeoutError, treat the connection as unreliable and close it rather than
/// retrying on it.
///
/// CoreBluetooth also reports read results and notifications through the same callback: a value
/// for the characteristic being read completes the read, and any other value is a notification.
///
/// All state lives on the Bluetooth queue (so the class is safe to share between tasks);
/// connectionState and maximumWriteLength are read there.
final class AsyncGattClient: GattClient, GattPeripheralEvents, @unchecked Sendable {
    let peripheral: GattPeripheral
    private let queue: DispatchQueue
    private let timeouts: GattTimeouts
    private let onClose: (AsyncGattClient) -> Void
    private let operationLock: AsyncFifoLock
    private var pendingOperation: PendingOperation?

    private(set) var connectionState: GattConnectionState = .connecting

    /// Values pushed by the remote server, in arrival order. Meant for a single listener.
    let notifications: AsyncThrowingStream<GattNotification, Error>
    private let notificationContinuation: AsyncThrowingStream<GattNotification, Error>.Continuation

    /// The longest value one write without response can carry: the ATT MTU iOS negotiated, minus 3.
    var maximumWriteLength: Int {
        peripheral.maximumWriteValueLength(for: .withoutResponse)
    }

    private struct PendingOperation {
        let id: UUID
        let operation: GattOperation
        let characteristicUuid: CBUUID?
        let continuation: CheckedContinuation<Any, Error>
        /// A write without response waiting for room in iOS's send buffer.
        var writeWaitingForRoom: (characteristic: CBCharacteristic, value: Data)?
    }

    init(
        peripheral: GattPeripheral,
        queue: DispatchQueue,
        timeouts: GattTimeouts,
        onClose: @escaping (AsyncGattClient) -> Void
    ) {
        self.peripheral = peripheral
        self.queue = queue
        self.timeouts = timeouts
        self.onClose = onClose
        operationLock = AsyncFifoLock(queue: queue)
        var streamContinuation: AsyncThrowingStream<GattNotification, Error>.Continuation?
        notifications = AsyncThrowingStream { streamContinuation = $0 }
        // AsyncThrowingStream runs its build closure before returning, so this is always set
        guard let continuation = streamContinuation else {
            preconditionFailure("Notification stream has no continuation")
        }
        notificationContinuation = continuation
    }

    /// connectionState, read from any task.
    func currentConnectionState() async -> GattConnectionState {
        await onQueue { self.connectionState }
    }

    /// maximumWriteLength, read from any task.
    func currentMaximumWriteLength() async -> Int {
        await onQueue { self.maximumWriteLength }
    }

    private func onQueue<T>(_ read: @escaping () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: read()) }
        }
    }

    // MARK: operations

    func discoverServices(_ serviceUuids: [CBUUID]?) async throws -> [CBService] {
        try await runOperation(.discoverServices) { _ in
            self.peripheral.discoverServices(serviceUuids)
        }
    }

    func discoverCharacteristics(for service: CBService) async throws {
        let _: Void = try await runOperation(.discoverCharacteristics, characteristicUuid: service.uuid) { _ in
            self.peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    /// findService with the default retries.
    func findService(_ serviceUuid: CBUUID) async throws -> CBService {
        try await findService(serviceUuid, attempts: 3, retryDelay: 0.5)
    }

    /// Discovers services until [serviceUuid] appears, then its characteristics. Discovery right
    /// after connecting can come back incomplete, so it is retried [attempts] times.
    func findService(
        _ serviceUuid: CBUUID,
        attempts: Int,
        retryDelay: TimeInterval
    ) async throws -> CBService {
        for attempt in 1...attempts {
            let services = try await discoverServices([serviceUuid])
            if let service = services.first(where: { $0.uuid == serviceUuid }) {
                try await discoverCharacteristics(for: service)
                return service
            }
            if attempt < attempts { try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000)) }
        }
        throw GattAttributeNotFoundError(attribute: "Service \(serviceUuid)")
    }

    func read(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws -> [UInt8] {
        try await runOperation(.readCharacteristic, characteristicUuid: characteristicUuid) { _ in
            let characteristic = try self.findCharacteristic(serviceUuid, characteristicUuid)
            self.peripheral.readValue(for: characteristic)
        }
    }

    /// Writes without a response from the server; returns once iOS has taken the value. When iOS's
    /// send buffer is full, waits until iOS says it has room.
    func writeWithoutResponse(serviceUuid: CBUUID, characteristicUuid: CBUUID, value: [UInt8]) async throws {
        let operation = GattOperation.writeCharacteristic
        let _: Void = try await runOperation(operation, characteristicUuid: characteristicUuid) { operationId in
            let characteristic = try self.findCharacteristic(serviceUuid, characteristicUuid)
            let data = Data(value)
            if self.peripheral.canSendWriteWithoutResponse {
                self.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                self.finishOperation(operationId, with: .success(()))
            } else {
                self.pendingOperation?.writeWaitingForRoom = (characteristic, data)
            }
        }
    }

    /// Subscribes to notifications (or indications). iOS writes the characteristic's CCCD itself,
    /// choosing 0x0001 or 0x0002 by what the characteristic supports, and confirms when done.
    func enableNotifications(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws {
        let _: Void = try await runOperation(.enableNotifications, characteristicUuid: characteristicUuid) { _ in
            let characteristic = try self.findCharacteristic(serviceUuid, characteristicUuid)
            guard !characteristic.properties.isDisjoint(with: [.notify, .indicate]) else {
                throw GattOperationFailedError(
                    operation: .enableNotifications,
                    detail: "\(characteristicUuid) cannot notify or indicate"
                )
            }
            self.peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// Unsubscribes: iOS writes 0x0000 to the CCCD. ISO 18013-5 clause 8.3.3.1.1.7 asks the client
    /// to unsubscribe before disconnecting.
    func disableNotifications(serviceUuid: CBUUID, characteristicUuid: CBUUID) async throws {
        let _: Void = try await runOperation(.disableNotifications, characteristicUuid: characteristicUuid) { _ in
            let characteristic = try self.findCharacteristic(serviceUuid, characteristicUuid)
            self.peripheral.setNotifyValue(false, for: characteristic)
        }
    }

    /// Disconnects and releases everything. Pending and later operations fail.
    func close() {
        queue.async {
            logger.debug("GATT client closed")
            self.connectionState = .disconnected
            self.failPendingOperation(GattDisconnectedError(reason: nil))
            self.notificationContinuation.finish()
            self.onClose(self)
        }
    }

    // MARK: connection lifecycle (called by AsyncBleCentral on the Bluetooth queue)

    func markConnected() {
        connectionState = .connected
    }

    func linkLost(_ reason: LinkLossReason) {
        guard connectionState == .connected else { return }
        logger.info("GATT link lost: \(reason)")
        connectionState = .lost(reason)
        failPendingOperation(GattDisconnectedError(reason: reason))
        // values already received are still delivered, then the listener gets the error
        notificationContinuation.finish(throwing: GattDisconnectedError(reason: reason))
    }

    // MARK: operation plumbing

    /// Runs one GATT operation: waits for its turn, asks iOS to [start] it on the Bluetooth queue,
    /// then waits for the matching answer (or the timeout). [start] may throw if it cannot begin.
    private func runOperation<T>(
        _ operation: GattOperation,
        characteristicUuid: CBUUID? = nil,
        start: @escaping (_ operationId: UUID) throws -> Void
    ) async throws -> T {
        await operationLock.lock()
        defer { operationLock.unlock() }
        let operationId = UUID()
        let cancellation = CancellationFlag()
        let answer = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                let pending = PendingOperation(
                    id: operationId,
                    operation: operation,
                    characteristicUuid: characteristicUuid,
                    continuation: continuation
                )
                queue.async { self.begin(pending, cancellation: cancellation, start: start) }
            }
        } onCancel: {
            queue.async {
                cancellation.isCancelled = true
                self.finishOperation(operationId, with: .failure(CancellationError()))
            }
        }
        guard let typedAnswer = answer as? T else {
            throw GattOperationFailedError(operation: operation, detail: "unexpected answer \(answer)")
        }
        return typedAnswer
    }

    /// On the Bluetooth queue: makes [pending] the pending operation, arms its timeout, starts it.
    private func begin(
        _ pending: PendingOperation,
        cancellation: CancellationFlag,
        start: (_ operationId: UUID) throws -> Void
    ) {
        guard !cancellation.isCancelled else { return pending.continuation.resume(throwing: CancellationError()) }
        do {
            try ensureConnected()
        } catch {
            return pending.continuation.resume(throwing: error)
        }
        pendingOperation = pending
        let timeout = timeouts.operation
        queue.asyncAfter(deadline: .now() + timeout) {
            let timedOut = GattOperationTimeoutError(operation: pending.operation, timeout: timeout)
            self.finishOperation(pending.id, with: .failure(timedOut))
        }
        do {
            try start(pending.id)
        } catch {
            finishOperation(pending.id, with: .failure(error))
        }
    }

    /// Completes operation [operationId] if it is still the pending one.
    @discardableResult
    private func finishOperation(_ operationId: UUID, with result: Result<Any, Error>) -> Bool {
        guard let pending = pendingOperation, pending.id == operationId else { return false }
        pendingOperation = nil
        // cancellations are deliberate, and a lost link is already logged as such
        if case let .failure(failure) = result, !(failure is CancellationError), !(failure is GattDisconnectedError) {
            logger.warning("\(failure)")
        }
        pending.continuation.resume(with: result)
        return true
    }

    /// Completes the pending operation if it is the one this answer is for.
    @discardableResult
    private func completePendingOperation(
        _ operation: GattOperation,
        _ characteristicUuid: CBUUID?,
        _ result: Result<Any, Error>
    ) -> Bool {
        guard let pending = pendingOperation, pending.operation == operation,
              pending.characteristicUuid == nil || pending.characteristicUuid == characteristicUuid
        else { return false }
        return finishOperation(pending.id, with: result)
    }

    private func failPendingOperation(_ failure: Error) {
        guard let pending = pendingOperation else { return }
        finishOperation(pending.id, with: .failure(failure))
    }

    private func ensureConnected() throws {
        switch connectionState {
        case .connected: return
        case let .lost(reason): throw GattDisconnectedError(reason: reason)
        default: throw GattDisconnectedError(reason: nil)
        }
    }

    private func findCharacteristic(_ serviceUuid: CBUUID, _ characteristicUuid: CBUUID) throws -> CBCharacteristic {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUuid }) else {
            throw GattAttributeNotFoundError(attribute: "Service \(serviceUuid)")
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUuid }) else {
            let attribute = "Characteristic \(characteristicUuid) in service \(serviceUuid)"
            throw GattAttributeNotFoundError(attribute: attribute)
        }
        return characteristic
    }

    /// An answer's error as the operation's failure, or [successValue].
    private func answer(
        _ operation: GattOperation,
        _ error: Error?,
        _ successValue: @autoclosure () -> Any
    ) -> Result<Any, Error> {
        guard let error = error else { return .success(successValue()) }
        return .failure(GattOperationFailedError(operation: operation, detail: error.localizedDescription))
    }

    // MARK: CoreBluetooth's answers (on the Bluetooth queue)

    func discoveredServices(error: Error?) {
        let services = peripheral.services ?? []
        completePendingOperation(.discoverServices, nil, answer(.discoverServices, error, services))
    }

    func discoveredCharacteristics(for service: CBService, error: Error?) {
        completePendingOperation(.discoverCharacteristics, service.uuid, answer(.discoverCharacteristics, error, ()))
    }

    func updatedValue(for characteristic: CBCharacteristic, error: Error?) {
        let value = [UInt8](characteristic.value ?? Data())
        let readAnswer = answer(.readCharacteristic, error, value)
        if completePendingOperation(.readCharacteristic, characteristic.uuid, readAnswer) { return }
        guard error == nil else { return }
        notificationContinuation.yield(GattNotification(characteristicUuid: characteristic.uuid, value: value))
    }

    func updatedNotificationState(for characteristic: CBCharacteristic, error: Error?) {
        guard let operation = pendingOperation?.operation,
              operation == .enableNotifications || operation == .disableNotifications
        else { return }
        completePendingOperation(operation, characteristic.uuid, answer(operation, error, ()))
    }

    func readyToSendWriteWithoutResponse() {
        guard let pending = pendingOperation, let write = pending.writeWaitingForRoom else { return }
        peripheral.writeValue(write.value, for: write.characteristic, type: .withoutResponse)
        finishOperation(pending.id, with: .success(()))
    }
}
