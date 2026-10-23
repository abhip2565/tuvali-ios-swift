import CoreBluetooth
import XCTest
@testable import ios_tuvali_library

/// Stands in for CoreBluetooth: records what the client asks for, and delivers CoreBluetooth's
/// events on the Bluetooth queue, as the real CBCentralManager would.
final class MockCoreBluetooth {
    let queue = DispatchQueue(label: "test.ble")
    let manager = MockBleCentralManager()
    // real time, not virtual: long enough that a slow CI machine does not time out a test that
    // should pass; the tests about timeouts simply wait for it
    let timeouts = GattTimeouts(connect: 1, operation: 1)
    private(set) lazy var central = AsyncBleCentral(manager: manager, queue: queue, timeouts: timeouts)

    /// Runs [block] on the Bluetooth queue and waits for it, so the test reads a settled state.
    func onQueue<T>(_ block: () -> T) -> T {
        queue.sync(execute: block)
    }

    /// Delivers a CoreBluetooth event on the Bluetooth queue and waits until it has been handled.
    func deliver(_ event: @escaping () -> Void) {
        queue.sync(execute: event)
    }

    /// A client already connected to [peripheral].
    func connectedClient(to peripheral: MockGattPeripheral) async throws -> AsyncGattClient {
        manager.state = .poweredOn
        let connection = Task { try await central.connect(peripheral) }
        try await eventually { self.onQueue { self.manager.connectRequests.count == 1 } }
        deliver { self.central.connected(peripheral) }
        return try await connection.value
    }
}

final class MockBleCentralManager: BleCentralManager {
    var state: CBManagerState = .poweredOn
    private(set) var scans: [[CBUUID]?] = []
    private(set) var stopScanCount = 0
    private(set) var connectRequests: [UUID] = []
    private(set) var cancelledConnections: [UUID] = []
    /// Peripherals whose events were routed somewhere, and those whose routing was removed again.
    private(set) var peripheralsWithEvents: Set<UUID> = []

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) { scans.append(serviceUUIDs) }
    func stopScan() { stopScanCount += 1 }
    func connect(_ peripheral: GattPeripheral) { connectRequests.append(peripheral.identifier) }
    func cancelPeripheralConnection(_ peripheral: GattPeripheral) { cancelledConnections.append(peripheral.identifier) }
    func setEvents(_ events: GattPeripheralEvents?, for peripheral: GattPeripheral) {
        if events == nil {
            peripheralsWithEvents.remove(peripheral.identifier)
        } else {
            peripheralsWithEvents.insert(peripheral.identifier)
        }
    }
}

/// A peripheral with one service; tests read what the client asked of it, and deliver
/// CoreBluetooth's answers through the client's GattPeripheralEvents.
final class MockGattPeripheral: GattPeripheral, @unchecked Sendable {
    static let serviceUuid = CBUUID(string: "0000a000-0000-1000-8000-00805f9b34fb")
    static let notifyUuid = CBUUID(string: "0000a001-0000-1000-8000-00805f9b34fb")
    static let indicateUuid = CBUUID(string: "0000a002-0000-1000-8000-00805f9b34fb")
    static let writeUuid = CBUUID(string: "0000a003-0000-1000-8000-00805f9b34fb")
    static let readUuid = CBUUID(string: "0000a004-0000-1000-8000-00805f9b34fb")

    let identifier = UUID()
    let service: CBMutableService
    let notifyCharacteristic = MockGattPeripheral.characteristic(notifyUuid, [.notify])
    let indicateCharacteristic = MockGattPeripheral.characteristic(indicateUuid, [.indicate])
    let writeCharacteristic = MockGattPeripheral.characteristic(writeUuid, [.writeWithoutResponse])
    let readCharacteristic = MockGattPeripheral.characteristic(readUuid, [.read])

    /// What discovery has found so far: nil until a test delivers the services.
    var services: [CBService]?
    var canSendWriteWithoutResponse = true
    var maximumWriteLength = 182

    private(set) var discoverServicesRequests: [[CBUUID]?] = []
    private(set) var discoverCharacteristicsRequests: [CBUUID] = []
    private(set) var readRequests: [CBUUID] = []
    private(set) var writes: [(characteristic: CBUUID, value: [UInt8], type: CBCharacteristicWriteType)] = []
    private(set) var notifyRequests: [(characteristic: CBUUID, enabled: Bool)] = []

    init() {
        service = CBMutableService(type: MockGattPeripheral.serviceUuid, primary: true)
        service.characteristics = allCharacteristics
    }

    func discoverServices(_ serviceUUIDs: [CBUUID]?) { discoverServicesRequests.append(serviceUUIDs) }
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
        discoverCharacteristicsRequests.append(service.uuid)
    }
    func readValue(for characteristic: CBCharacteristic) { readRequests.append(characteristic.uuid) }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append((characteristic.uuid, [UInt8](data), type))
    }
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        notifyRequests.append((characteristic.uuid, enabled))
    }
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { maximumWriteLength }

    var allCharacteristics: [CBMutableCharacteristic] {
        [notifyCharacteristic, indicateCharacteristic, writeCharacteristic, readCharacteristic]
    }

    func characteristic(_ uuid: CBUUID) -> CBMutableCharacteristic {
        guard let characteristic = allCharacteristics.first(where: { $0.uuid == uuid }) else {
            preconditionFailure("No characteristic \(uuid)")
        }
        return characteristic
    }

    /// The peripheral as it looks after discovery: its service and characteristics are known.
    func markDiscovered() {
        services = [service]
    }

    private static func characteristic(
        _ uuid: CBUUID,
        _ properties: CBCharacteristicProperties
    ) -> CBMutableCharacteristic {
        CBMutableCharacteristic(type: uuid, properties: properties, value: nil, permissions: [.readable, .writeable])
    }
}

extension AsyncGattClient {
    /// Operations on a characteristic of the mock peripheral's one service.
    func read(_ characteristicUuid: CBUUID) async throws -> [UInt8] {
        try await read(serviceUuid: MockGattPeripheral.serviceUuid, characteristicUuid: characteristicUuid)
    }

    func writeWithoutResponse(_ characteristicUuid: CBUUID, _ value: [UInt8]) async throws {
        let service = MockGattPeripheral.serviceUuid
        try await writeWithoutResponse(serviceUuid: service, characteristicUuid: characteristicUuid, value: value)
    }

    func enableNotifications(_ characteristicUuid: CBUUID) async throws {
        let service = MockGattPeripheral.serviceUuid
        try await enableNotifications(serviceUuid: service, characteristicUuid: characteristicUuid)
    }

    func disableNotifications(_ characteristicUuid: CBUUID) async throws {
        let service = MockGattPeripheral.serviceUuid
        try await disableNotifications(serviceUuid: service, characteristicUuid: characteristicUuid)
    }
}

/// Waits until [condition] holds, checking every few milliseconds, for at most [timeout] seconds.
func eventually(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Condition not met within \(timeout) s", file: file, line: line)
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Awaits [task] and returns the error it threw, or fails the test if it did not throw.
func errorThrown<T>(by task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async -> Error? {
    do {
        _ = try await task.value
        XCTFail("Expected an error", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
