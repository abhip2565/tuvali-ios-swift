@preconcurrency import CoreBluetooth
import Foundation

extension CBPeripheral: GattPeripheral {}

/// The real CBCentralManager, with its delegate calls forwarded to [events] and to each
/// peripheral's own events. Everything runs on [queue].
final class CoreBluetoothCentral: NSObject, BleCentralManager, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var events: BleCentralEvents?
    private var manager: CBCentralManager?
    private var peripheralEvents: [UUID: GattPeripheralEvents] = [:]

    init(queue: DispatchQueue) {
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    var state: CBManagerState { manager?.state ?? .unknown }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) {
        let options = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        manager?.scanForPeripherals(withServices: serviceUUIDs, options: options)
    }

    func stopScan() {
        manager?.stopScan()
    }

    func connect(_ peripheral: GattPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        peripheral.delegate = self
        manager?.connect(peripheral)
    }

    func cancelPeripheralConnection(_ peripheral: GattPeripheral) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        manager?.cancelPeripheralConnection(peripheral)
    }

    func setEvents(_ events: GattPeripheralEvents?, for peripheral: GattPeripheral) {
        peripheralEvents[peripheral.identifier] = events
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        events?.stateChanged(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        events?.discovered(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        events?.connected(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        events?.failedToConnect(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        events?.disconnected(peripheral, error: error)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheralEvents[peripheral.identifier]?.discoveredServices(error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        peripheralEvents[peripheral.identifier]?.discoveredCharacteristics(for: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        peripheralEvents[peripheral.identifier]?.updatedValue(for: characteristic, error: error)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        peripheralEvents[peripheral.identifier]?.updatedNotificationState(for: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        peripheralEvents[peripheral.identifier]?.readyToSendWriteWithoutResponse()
    }
}
