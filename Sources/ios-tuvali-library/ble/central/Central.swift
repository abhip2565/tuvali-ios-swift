import Foundation
import CoreBluetooth

private let logger = TaggedLogger(tag: "Central")



@available(iOS 13.0, *)
class Central: NSObject, CBCentralManagerDelegate {

    var retryStrategy : BackOffStrategy = BackOffStrategy(MAX_RETRY_LIMIT: 10)
    var transferReportRequestRetryStrategy = BackOffStrategy(MAX_RETRY_LIMIT: 5)
    var centralManager: CBCentralManager!
    var connectedPeripheral: CBPeripheral?
    var cbCharacteristics: [String: CBCharacteristic] = [:]
    var delegate: PeripheralCommunicatorProtocol?
    var walletBleCommunicatorDelegate: WalletBleCommunicatorProtocol?
    var createConnection: (() -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logger.info("Central Manager state is powered ON")
            scanForPeripherals()
        case .poweredOff:
            logger.info("Central Manager state is powered OFF")
            EventEmitter.sharedInstance.emitEvent(DisconnectedEvent())
        default:
            logger.debug("Central Manager state is in state - \(central.state.rawValue)")
        }
    }

    deinit {
        logger.info("Central is DeInitializing")
    }

    func scanForPeripherals() {
        centralManager.scanForPeripherals(withServices: [Peripheral.SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        logger.info("Scanning happening ")
    }

    /**
     * write(..) writes data on a charUUID without response
     */
    func writeWithResponse(serviceUuid: CBUUID, charUUID: CBUUID, data: Data) {
        if let connectedPeripheral = connectedPeripheral {
            guard let characteristic = self.cbCharacteristics[charUUID.uuidString] else {
                logger.info("Did not find the characteristic to write")
                return
            }
            let messageData = Data(bytes: Array(data), count: data.count)
            connectedPeripheral.writeValue(messageData, for: characteristic, type: .withResponse)
        } else {
            logger.info("connectedPeripheral is nil while writing with resp to char: \(charUUID.uuidString)")
        }
    }

    /**
     * writeWithoutResp(...) writes data on a charUUID without response
     */
    func writeWithoutResp(serviceUuid: CBUUID, charUUID: CBUUID, data: Data) {
        if let connectedPeripheral = connectedPeripheral {
            guard let characteristic = self.cbCharacteristics[charUUID.uuidString] else {
                logger.info("Did not find the characteristic to write")
                return
            }
            let messageData = Data(bytes: Array(data), count: data.count)
            connectedPeripheral.writeValue(messageData, for: characteristic, type: .withoutResponse)
        }
    }

    func disconnect() {
        if let connectedPeripheral = self.connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
    }
}
