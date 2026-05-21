import Foundation
import CoreBluetooth

private let logger = TaggedLogger(tag: "Wallet")

protocol TransferHandlerDelegate: AnyObject {
    func write(serviceUuid: CBUUID, charUUID: CBUUID, data: Data, withResponse: Bool)
}
@available(iOS 13.0, *)
extension WalletBleCommunicator: WalletBleCommunicatorProtocol {

    func onDisconnect() {
        self.onDeviceDisconnected()
    }

    func onIdentifyWriteSuccess() {
        EventEmitter.sharedInstance.emitEvent(SecureChannelEstablishedEvent())
    }

    func onDisconnectStatusChange(data: Data?) {
        logger.debug("Handling notification for disconnect handle")
        if let data {
            let connStatusID = Int(data[0])
            if connStatusID == 1 {
                logger.debug("con statusid: \(connStatusID)")
                handleDestroyConnection(isSelfDisconnect: false)
            }
        }
    }

    func setVeriferKeyOnSameIdentifier(payload: Data, publicData: Data, completion: (() -> Void)) {
        if isSameAdvIdentifier(advertisementPayload: payload) {
            setVerifierPublicKey(publicKeyData: publicData)
            completion()
        }
    }

    func shouldConnectToDiscoveredPeripheral(advertisementData: [String: Any]) -> Bool {
        // iOS peripherals cannot advertise service data. For iOS verifier discovery,
        // the QR URI carries the verifier public key and local name is only a hint.
        guard verifierPublicKey != nil else {
            return false
        }
        guard let advName, let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String else {
            return true
        }
        return localName == advName
    }

    func createConnectionHandler() {
        createConnection?()
    }
}
@available(iOS 13.0, *)
extension WalletBleCommunicator: TransferHandlerDelegate {
    func write(serviceUuid: CBUUID, charUUID: CBUUID, data: Data, withResponse: Bool) {
        if withResponse {
            central?.writeWithResponse(serviceUuid: serviceUuid, charUUID: charUUID, data: data)
        } else {
            central?.writeWithoutResp(serviceUuid: serviceUuid, charUUID: charUUID, data: data)
        }
    }
}

