@preconcurrency import CoreBluetooth
import Foundation

/// The Bluetooth LE central: scans by service, connects, and watches Bluetooth's state.
/// CoreBluetooth needs one CBCentralManager to both find a peripheral and connect to it, so both
/// live here; each connection is then served by its own AsyncGattClient.
///
/// One connection attempt at a time, and one scan at a time (a new scan ends the previous one).
/// All state lives on the Bluetooth queue, so the class is safe to share between tasks.
final class AsyncBleCentral: BleCentralEvents, @unchecked Sendable {
    private let manager: BleCentralManager
    private let queue: DispatchQueue
    private let timeouts: GattTimeouts
    private var clients: [UUID: AsyncGattClient] = [:]
    private var pendingConnection: PendingConnection?
    private var activeScan: ActiveScan?

    private struct PendingConnection {
        let id: UUID
        let client: AsyncGattClient
        let continuation: CheckedContinuation<AsyncGattClient, Error>
    }

    /// Carries a peripheral into the Bluetooth-queue closure, the only place it is used.
    private struct QueuedPeripheral: @unchecked Sendable {
        let peripheral: GattPeripheral
    }

    private struct ActiveScan {
        let id: UUID
        let serviceUuid: CBUUID
        let continuation: AsyncThrowingStream<GattPeripheral, Error>.Continuation
        var isScanning = false
    }

    /// A central on the real CoreBluetooth, with its own Bluetooth queue.
    convenience init(timeouts: GattTimeouts = GattTimeouts()) {
        let queue = DispatchQueue(label: "io.mosip.tuvali.ble")
        let coreBluetooth = CoreBluetoothCentral(queue: queue)
        self.init(manager: coreBluetooth, queue: queue, timeouts: timeouts)
        coreBluetooth.events = self
    }

    init(manager: BleCentralManager, queue: DispatchQueue, timeouts: GattTimeouts) {
        self.manager = manager
        self.queue = queue
        self.timeouts = timeouts
    }

    // MARK: scanning

    /// Peripherals advertising [serviceUuid], as iOS finds them. Waits for Bluetooth to power on.
    /// Throws GattDisconnectedError if Bluetooth is or goes off, and BleScanFailedError if this
    /// device or app cannot use Bluetooth. Scanning stops on stopScan(), or when the listening task
    /// is cancelled. Leaving the loop alone does not stop it, as the stream may still be held.
    func scan(for serviceUuid: CBUUID) -> AsyncThrowingStream<GattPeripheral, Error> {
        let scanId = UUID()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { self?.endScan(scanId) }
            }
            queue.async {
                self.activeScan?.continuation.finish()
                self.activeScan = ActiveScan(id: scanId, serviceUuid: serviceUuid, continuation: continuation)
                self.updateScan(for: self.manager.state)
            }
        }
    }

    /// Ends the current scan, if any; its stream finishes normally.
    func stopScan() {
        queue.async {
            guard let scan = self.activeScan else { return }
            self.endScan(scan.id)
            scan.continuation.finish()
        }
    }

    private func updateScan(for state: CBManagerState) {
        guard let scan = activeScan else { return }
        switch state {
        case .poweredOn:
            guard !scan.isScanning else { return }
            activeScan?.isScanning = true
            manager.scanForPeripherals(withServices: [scan.serviceUuid])
        case .resetting:
            // iOS stops scanning while Bluetooth resets; scan again once it is back on
            activeScan?.isScanning = false
        case .poweredOff:
            finishScan(throwing: GattDisconnectedError(reason: .bluetoothTurnedOff))
        case .unauthorized:
            finishScan(throwing: BleScanFailedError(detail: "the app is not allowed to use Bluetooth"))
        case .unsupported:
            finishScan(throwing: BleScanFailedError(detail: "this device has no Bluetooth LE"))
        default:
            // unknown: wait for the next state change
            break
        }
    }

    private func finishScan(throwing failure: Error) {
        guard let scan = activeScan else { return }
        activeScan = nil
        if scan.isScanning { manager.stopScan() }
        scan.continuation.finish(throwing: failure)
    }

    private func endScan(_ scanId: UUID) {
        guard let scan = activeScan, scan.id == scanId else { return }
        activeScan = nil
        if scan.isScanning { manager.stopScan() }
    }

    // MARK: connecting

    /// Connects to [peripheral] and returns its client once iOS reports the link is up.
    func connect(_ peripheral: GattPeripheral) async throws -> AsyncGattClient {
        let connectionId = UUID()
        let timeout = timeouts.connect
        let cancellation = CancellationFlag()
        let queued = QueuedPeripheral(peripheral: peripheral)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AsyncGattClient, Error>) in
                queue.async {
                    let peripheral = queued.peripheral
                    guard !cancellation.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                    guard self.pendingConnection == nil else {
                        let detail = "another connection is in progress"
                        let busy = GattOperationFailedError(operation: .connect, detail: detail)
                        return continuation.resume(throwing: busy)
                    }
                    switch self.manager.state {
                    case .poweredOn:
                        break
                    case .poweredOff:
                        return continuation.resume(throwing: GattDisconnectedError(reason: .bluetoothTurnedOff))
                    default:
                        return continuation.resume(
                            throwing: GattOperationFailedError(operation: .connect, detail: "Bluetooth is not ready")
                        )
                    }
                    let client = AsyncGattClient(
                        peripheral: peripheral,
                        queue: self.queue,
                        timeouts: self.timeouts,
                        onClose: { [weak self] client in self?.clientClosed(client) }
                    )
                    self.pendingConnection = PendingConnection(
                        id: connectionId,
                        client: client,
                        continuation: continuation
                    )
                    self.manager.setEvents(client, for: peripheral)
                    self.manager.connect(peripheral)
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.failConnection(
                            connectionId,
                            GattOperationTimeoutError(operation: .connect, timeout: timeout),
                            cancelAttempt: true
                        )
                    }
                }
            }
        } onCancel: {
            queue.async {
                cancellation.isCancelled = true
                self.failConnection(connectionId, CancellationError(), cancelAttempt: true)
            }
        }
    }

    private func failConnection(_ connectionId: UUID, _ failure: Error, cancelAttempt: Bool) {
        guard let pending = pendingConnection, pending.id == connectionId else { return }
        pendingConnection = nil
        manager.setEvents(nil, for: pending.client.peripheral)
        if cancelAttempt { manager.cancelPeripheralConnection(pending.client.peripheral) }
        pending.continuation.resume(throwing: failure)
    }

    private func pendingConnection(to peripheral: GattPeripheral) -> PendingConnection? {
        guard let pending = pendingConnection,
              pending.client.peripheral.identifier == peripheral.identifier
        else { return nil }
        return pending
    }

    private func clientClosed(_ client: AsyncGattClient) {
        guard clients.removeValue(forKey: client.peripheral.identifier) != nil else { return }
        manager.setEvents(nil, for: client.peripheral)
        manager.cancelPeripheralConnection(client.peripheral)
    }

    // MARK: CoreBluetooth's events (on the Bluetooth queue)

    func stateChanged(_ state: CBManagerState) {
        // off, resetting, or no longer allowed: every open or opening link is gone
        if [.poweredOff, .resetting, .unauthorized].contains(state) {
            if let pending = pendingConnection {
                failConnection(pending.id, GattDisconnectedError(reason: .bluetoothTurnedOff), cancelAttempt: false)
            }
            let lostClients = clients.values
            clients.removeAll()
            lostClients.forEach { client in
                manager.setEvents(nil, for: client.peripheral)
                client.linkLost(.bluetoothTurnedOff)
            }
        }
        updateScan(for: state)
    }

    func discovered(_ peripheral: GattPeripheral) {
        activeScan?.continuation.yield(peripheral)
    }

    func connected(_ peripheral: GattPeripheral) {
        guard let pending = pendingConnection(to: peripheral) else { return }
        pendingConnection = nil
        pending.client.markConnected()
        clients[peripheral.identifier] = pending.client
        pending.continuation.resume(returning: pending.client)
    }

    func failedToConnect(_ peripheral: GattPeripheral, error: Error?) {
        guard let pending = pendingConnection(to: peripheral) else { return }
        let detail = error?.localizedDescription ?? "iOS could not connect"
        failConnection(pending.id, GattOperationFailedError(operation: .connect, detail: detail), cancelAttempt: false)
    }

    func disconnected(_ peripheral: GattPeripheral, error: Error?) {
        if let pending = pendingConnection(to: peripheral) {
            let failure = GattOperationFailedError(operation: .connect, detail: "disconnected before the link was up")
            failConnection(pending.id, failure, cancelAttempt: false)
            return
        }
        guard let client = clients.removeValue(forKey: peripheral.identifier) else { return }
        manager.setEvents(nil, for: peripheral)
        client.linkLost(.remoteDisconnected)
    }
}
