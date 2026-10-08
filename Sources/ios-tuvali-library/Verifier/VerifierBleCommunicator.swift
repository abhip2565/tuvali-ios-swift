import Foundation
import CoreBluetooth
import Gzip

@available(iOS 13.0, *)
class VerifierBleCommunicator: NSObject {
    private let eventEmitter: EventEmitter
    private let verifierCryptoBox: VerifierCryptoBox
    private let peripheral = Peripheral()
    private lazy var transferHandler = VerifierTransferHandler(delegate: self)
    private var secretsTranslator: SecretTranslator?
    private(set) var publicKey: Data

    init(eventEmitter: EventEmitter) {
        self.eventEmitter = eventEmitter
        self.verifierCryptoBox = VerifierCryptoBoxBuilder().build()
        self.publicKey = verifierCryptoBox.getPublicKey()
        super.init()
    }

    func startAdvertisement(advIdentifier: String) {
        peripheral.start(advertisementName: advIdentifier, delegate: self)
    }

    func stop() {
        secretsTranslator = nil
        peripheral.stop()
    }

    private func rejectSession(_ message: String) {
        stop()
        onResponseReceivedFailed(message)
    }

    func notifyVerificationStatus(accepted: Bool) {
        let status = accepted ? VerificationStatusEvent.VerificationStatus.ACCEPTED.rawValue : VerificationStatusEvent.VerificationStatus.REJECTED.rawValue
        peripheral.sendData(charUUID: NetworkCharNums.VERIFICATION_STATUS_CHAR_UUID, data: Data([UInt8(status)]))
    }

    private func handleIdentifyRequest(_ data: Data) {
        secretsTranslator = nil
        guard data.count == CryptoConstants.NONCE_LENGTH + 32 else {
            rejectSession("Verifier received invalid identify request")
            return
        }

        let nonce = data.subdata(in: 0..<CryptoConstants.NONCE_LENGTH)
        let walletPublicKey = data.subdata(in: CryptoConstants.NONCE_LENGTH..<(CryptoConstants.NONCE_LENGTH + 32))
        do {
            secretsTranslator = try verifierCryptoBox.buildSecretsTranslator(nonce: nonce, walletPublicKey: walletPublicKey)
            eventEmitter.emitEvent(SecureChannelEstablishedEvent())
        } catch {
            rejectSession("Verifier failed to establish secure channel")
        }
    }
}

@available(iOS 13.0, *)
extension VerifierBleCommunicator: VerifierPeripheralDelegate {
    func onPeripheralReady() {
    }

    func onAdvertisementStarted() {
    }

    func onDeviceConnected() {
        eventEmitter.emitEvent(ConnectedEvent())
    }

    func onDeviceDisconnected() {
        eventEmitter.emitEvent(DisconnectedEvent())
    }

    func onWrite(uuid: CBUUID, data: Data) {
        switch uuid {
        case NetworkCharNums.IDENTIFY_REQUEST_CHAR_UUID:
            handleIdentifyRequest(data)
        case NetworkCharNums.RESPONSE_SIZE_CHAR_UUID:
            transferHandler.handleResponseSize(data, maxDataBytes: peripheral.maxDataBytes)
        case NetworkCharNums.SUBMIT_RESPONSE_CHAR_UUID:
            transferHandler.handleResponseChunk(data)
        case NetworkCharNums.TRANSFER_REPORT_REQUEST_CHAR_UUID:
            transferHandler.handleTransferReportRequest(data)
        default:
            break
        }
    }

    func onNotificationSent(uuid: CBUUID, success: Bool) {
    }
}

@available(iOS 13.0, *)
extension VerifierBleCommunicator: VerifierTransferHandlerDelegate {
    func sendDataOverNotification(charUUID: CBUUID, data: Data) {
        peripheral.sendData(charUUID: charUUID, data: data)
    }

    func onResponseReceived(data: Data, crcFailureCount: Int, totalChunkCount: Int) {
        guard let secretsTranslator else {
            rejectSession("Verifier received response without a secure channel")
            return
        }
        do {
            let decryptedData = try secretsTranslator.decryptUponReceive(data: data)
            let decompressedData = try decryptedData.gunzipped()
            guard let payload = String(data: decompressedData, encoding: .utf8) else {
                rejectSession("Verifier received invalid response text")
                return
            }
            eventEmitter.emitEvent(DataReceivedEvent(
                data: payload,
                crcFailureCount: crcFailureCount,
                totalChunkCount: totalChunkCount
            ))
        } catch {
            rejectSession("Verifier failed to decrypt or decompress response")
        }
    }

    func onResponseReceivedFailed(_ message: String) {
        eventEmitter.emitErrorEvent(message: message, code: VerifierErrorEnum.corruptedChunkReceived.code)
    }
}
