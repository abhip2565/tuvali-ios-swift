import Foundation
import CoreBluetooth

@available(iOS 13.0, *)
protocol VerifierPeripheralDelegate: AnyObject {
    func onPeripheralReady()
    func onAdvertisementStarted()
    func onDeviceConnected()
    func onDeviceDisconnected()
    func onWrite(uuid: CBUUID, data: Data)
    func onNotificationSent(uuid: CBUUID, success: Bool)
}

@available(iOS 13.0, *)
class Peripheral: NSObject {
    var peripheralManager: CBPeripheralManager!
    weak var verifierDelegate: VerifierPeripheralDelegate?
    private var characteristics: [String: CBMutableCharacteristic] = [:]
    var pendingAdvertisementName: String?
    private var serviceAdded = false
    var maxDataBytes = BLEConstants.MAX_ALLOWED_DATA_LEN

    static let SERVICE_UUID = CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb")
    static let SCAN_RESPONSE_SERVICE_UUID = CBUUID(string: "00000002-0000-1000-8000-00805f9b34fb")

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil, options: [CBPeripheralManagerOptionShowPowerAlertKey: true])
    }

    func start(advertisementName: String, delegate: VerifierPeripheralDelegate) {
        self.verifierDelegate = delegate
        self.pendingAdvertisementName = advertisementName
        if peripheralManager.state == .poweredOn {
            setupPeripheralsAndStartAdvertising()
        }
    }

    func stop() {
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        serviceAdded = false
        characteristics.removeAll()
        verifierDelegate?.onDeviceDisconnected()
    }

    func setupPeripheralsAndStartAdvertising() {
        guard !serviceAdded else {
            startAdvertisingIfPossible()
            return
        }

        let bleService = CBMutableService(type: Self.SERVICE_UUID, primary: true)
        let mutableCharacteristics = Util.createCBMutableCharacteristics()
        mutableCharacteristics.forEach { characteristic in
            characteristics[characteristic.uuid.uuidString] = characteristic
        }
        bleService.characteristics = mutableCharacteristics
        peripheralManager.add(bleService)
        serviceAdded = true
    }

    func sendData(charUUID: CBUUID, data: Data) {
        guard let characteristic = characteristics[charUUID.uuidString] else {
            return
        }
        let success = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
        verifierDelegate?.onNotificationSent(uuid: charUUID, success: success)
    }

    private func startAdvertisingIfPossible() {
        guard let pendingAdvertisementName else {
            return
        }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.SERVICE_UUID],
            CBAdvertisementDataLocalNameKey: pendingAdvertisementName
        ])
    }
}
