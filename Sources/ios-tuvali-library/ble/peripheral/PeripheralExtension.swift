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
        peripheral.stopAdvertising()
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        logger.info("Central unsubscribed from characteristic")
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        logger.info("Received write request for characteristic")
    }
}
