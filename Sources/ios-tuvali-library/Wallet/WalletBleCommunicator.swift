import Foundation
import Gzip

@objc(Wallet)
@available(iOS 13.0, *)
class WalletBleCommunicator: NSObject {

    var central: Central?
    var secretTranslator: SecretTranslator?
    var cryptoBox: WalletCryptoBox = WalletCryptoBoxBuilder().build()
    var advIdentifier: Data?
    var advName: String?
    var verifierPublicKey: Data?
    var createConnection: (() -> Void)?
    static let EXCHANGE_RECEIVER_INFO_DATA = "{\"deviceName\":\"Verifier\"}"

    override init() {
        super.init()
        central = Central()
    }


    func setAdvIdentifier(identifier: Data) {
        self.advIdentifier = identifier
    }

    func setAdvName(_ name: String?) {
        self.advName = name
    }

    func setVerifierPublicKey(publicKeyData: Data) {
        verifierPublicKey = publicKeyData
    }

    func startScanning(){
        central?.walletBleCommunicatorDelegate = self
    }

    func handleDestroyConnection(isSelfDisconnect: Bool) {
        central?.disconnect()
        if !isSelfDisconnect {
            onDeviceDisconnected()
        }
    }

    func onDeviceDisconnected(){
        EventEmitter.sharedInstance.emitEvent(DisconnectedEvent())
    }

    func isSameAdvIdentifier(advertisementPayload: Data) -> Bool {
        guard let advIdentifier = advIdentifier else {
            
            return false
        }
        let advIdentifierData = advIdentifier
        if advIdentifierData == advertisementPayload {
            return true
        }
        return false
    }

    func hexStringToData(string: String) -> Data {
        let stringArray = Array(string)
        var data: Data = Data()
        for i in stride(from: 0, to: string.count, by: 2) {
            let pair: String = String(stringArray[i]) + String(stringArray[i+1])
            if let byteNum = UInt8(pair, radix: 16) {
                let byte = Data([byteNum])
                data.append(byte)
            } else {
                fatalError()
            }
        }
        return data
    }

    func send(_ payload: String) {
        let encryptedData: Data?
        do {
            let compressedBytes = try Data(payload.utf8).gzipped()
            encryptedData = try secretTranslator?.encryptToSend(data: compressedBytes)
        } catch {
            rejectSecureChannel("Wallet failed to encrypt response")
            return
        }

        if (encryptedData != nil) {
            DispatchQueue.main.async {
                let transferHandler = TransferHandler()
                transferHandler.delegate = self
                transferHandler.destroyConnection = { [weak self] in
                    self?.handleDestroyConnection(isSelfDisconnect: true)
                }
                // DOUBT: why is encrypted data written twice ?

                self.central?.delegate = transferHandler
                transferHandler.initialize(initdData: encryptedData!)
                var currentMTUSize = self.central?.connectedPeripheral?.maximumWriteValueLength(for: .withoutResponse)
                if currentMTUSize == nil || currentMTUSize! < 0 {
                   currentMTUSize = BLEConstants.DEFAULT_CHUNK_SIZE
                }
                // follow BLE 5.3 spec where max data size in a chunk is limited to 512
                // now iOS impl is compatible to Android13 which follows BLE5.3 spec more closely
                currentMTUSize =  min(currentMTUSize!, BLEConstants.MAX_ALLOWED_DATA_LEN)
                let imsgBuilder = imessage(msgType: .INIT_RESPONSE_TRANSFER, data: encryptedData!, mtuSize: currentMTUSize)
                transferHandler.sendMessage(message: imsgBuilder)
            }
        }
    }

    private func rejectSecureChannel(_ message: String) {
        secretTranslator = nil
        handleDestroyConnection(isSelfDisconnect: true)
        EventEmitter.sharedInstance.emitErrorEvent(message: message, code: VerifierErrorEnum.corruptedChunkReceived.code)
    }

    func writeToIdentifyRequest() {
        let publicKey = self.cryptoBox.getPublicKey()
        guard let verifierPublicKey = self.verifierPublicKey else {
       
            return
        }
        secretTranslator = nil
        do {
            let translator = try cryptoBox.buildSecretsTranslator(verifierPublicKey: verifierPublicKey)
            secretTranslator = translator
            central?.writeWithResponse(serviceUuid: Peripheral.SERVICE_UUID, charUUID: NetworkCharNums.IDENTIFY_REQUEST_CHAR_UUID, data: translator.getNonce() + publicKey)
        } catch {
            rejectSecureChannel("Wallet failed to establish secure channel")
        }
    }
}
