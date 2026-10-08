import Foundation
import CoreBluetooth

private let logger = TaggedLogger(tag: "Peripheral")

@available(iOS 13.0, *)
extension Peripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            logger.info("Peripheral is in ON state")
            self.setupPeripheralsAndStartAdvertising()
        case .poweredOff:
            logger.info("Peripheral is in OFF state")
        default:
            logger.info("Peripheral is in INVALID state")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        logger.info("Central subscribed to characteristic")
        maxDataBytes = min(central.maximumUpdateValueLength, BLEConstants.MAX_ALLOWED_DATA_LEN)
        verifierDelegate?.onDeviceConnected()
        peripheral.stopAdvertising()
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        logger.info("Central unsubscribed from characteristic")
        verifierDelegate?.onDeviceDisconnected()
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        logger.info("Received write request for characteristic")
        guard let firstRequest = requests.first else { return }
        guard let verifierDelegate else {
            peripheral.respond(to: firstRequest, withResult: .unlikelyError)
            return
        }
        let writes = requests.map {
            VerifierWriteBatch.Write(uuid: $0.characteristic.uuid,
                                     properties: $0.characteristic.properties,
                                     offset: $0.offset, value: $0.value)
        }
        VerifierWriteBatch.process(writes, onWrite: verifierDelegate.onWrite) { result in
            peripheral.respond(to: firstRequest, withResult: result)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            logger.error("Failed to add verifier GATT service")
            serviceAdded = false
            return
        }
        serviceAdded = true
        verifierDelegate?.onPeripheralReady()
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Peripheral.SERVICE_UUID],
            CBAdvertisementDataLocalNameKey: pendingAdvertisementName ?? "verifier"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard error == nil else {
            logger.error("Failed to start verifier advertisement")
            return
        }
        verifierDelegate?.onAdvertisementStarted()
    }
}
