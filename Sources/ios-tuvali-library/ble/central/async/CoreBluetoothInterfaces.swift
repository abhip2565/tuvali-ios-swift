@preconcurrency import CoreBluetooth
import Foundation

// The seam between the async Bluetooth layer and CoreBluetooth: AsyncBleCentral and AsyncGattClient
// talk only to these, so tests can stand in for iOS. CoreBluetoothCentral is the real side.

/// The parts of CBPeripheral the async client uses, so tests can stand in for a real peripheral.
/// CBPeripheral already has every one of these.
protocol GattPeripheral: AnyObject {
    var identifier: UUID { get }
    var services: [CBService]? { get }
    var canSendWriteWithoutResponse: Bool { get }
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService)
    func readValue(for characteristic: CBCharacteristic)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int
}

/// The parts of CBCentralManager the async central uses, so tests can stand in for it.
protocol BleCentralManager: AnyObject {
    var state: CBManagerState { get }
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?)
    func stopScan()
    func connect(_ peripheral: GattPeripheral)
    func cancelPeripheralConnection(_ peripheral: GattPeripheral)
    /// Where this peripheral's own events (discovery, values, notifications) go.
    func setEvents(_ events: GattPeripheralEvents?, for peripheral: GattPeripheral)
}

/// What CoreBluetooth reports about the central and its connections, on the Bluetooth queue.
protocol BleCentralEvents: AnyObject {
    func stateChanged(_ state: CBManagerState)
    func discovered(_ peripheral: GattPeripheral)
    func connected(_ peripheral: GattPeripheral)
    func failedToConnect(_ peripheral: GattPeripheral, error: Error?)
    func disconnected(_ peripheral: GattPeripheral, error: Error?)
}

/// What CoreBluetooth reports about one connected peripheral, on the Bluetooth queue.
protocol GattPeripheralEvents: AnyObject {
    func discoveredServices(error: Error?)
    func discoveredCharacteristics(for service: CBService, error: Error?)
    /// A read result or a notification: CoreBluetooth reports both the same way.
    func updatedValue(for characteristic: CBCharacteristic, error: Error?)
    func updatedNotificationState(for characteristic: CBCharacteristic, error: Error?)
    func readyToSendWriteWithoutResponse()
}
