import Foundation
import CoreBluetooth

private let logger = TaggedLogger(tag: "Central")

@available(iOS 13.0, *)
extension Central {

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {

        let dataDict = advertisementData["kCBAdvDataServiceData"] as? [CBUUID: Any?]
        if let uuidDict = dataDict, let data = uuidDict[CBUUID(string: "00000002-0000-1000-8000-00805f9b34fb")], let data = data {
            let scanResponseData = dataDict?[CBUUID(string: "00000002-0000-1000-8000-00805f9b34fb")]  as! Data
            let advertisementData = dataDict?[CBUUID(string: "00000001-0000-1000-8000-00805f9b34fb")]  as! Data
            let publicKeyData =  advertisementData.subdata(in: advertisementData.count-5..<advertisementData.count) + scanResponseData
            walletBleCommunicatorDelegate?.setVeriferKeyOnSameIdentifier(payload: advertisementData, publicData: publicKeyData) {
                peripheral.delegate = self
                central.connect(peripheral)
                connectedPeripheral = peripheral
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to peripheral: \(String(describing: peripheral.name))")
        central.stopScan()
        peripheral.discoverServices([Peripheral.SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("Peripheral disconnected")
        if let connectedPeripheral = connectedPeripheral {
            central.cancelPeripheralConnection(connectedPeripheral)
        }
        walletBleCommunicatorDelegate?.onDisconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    }
}
