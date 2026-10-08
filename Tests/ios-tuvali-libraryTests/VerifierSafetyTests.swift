import XCTest
import CryptoKit
import CoreBluetooth
@testable import ios_tuvali_library

final class VerifierSafetyTests: XCTestCase {
    func testQRQueryValuesRoundTripWithoutAddingParameters() throws {
        let key = Data(repeating: 0xAB, count: 32)
        for name in ["Gate&A=1", "Gate?#=%+", "入口 & desk", ""] {
            let components = try XCTUnwrap(URLComponents(string: Verifier.connectionURI(name: name, publicKey: key)))
            XCTAssertEqual(components.queryItems?.count, 2)
            XCTAssertEqual(components.queryItems?.first?.value, name)
            XCTAssertEqual(components.queryItems?.last?.value, key.toHex())
        }
    }

    func testInvalidPeerKeysThrowInsteadOfCrashing() {
        let verifier = VerifierCryptoBoxImpl()
        for key in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 32)] {
            XCTAssertThrowsError(try verifier.buildSecretsTranslator(nonce: Data(repeating: 0, count: 12), walletPublicKey: key))
            XCTAssertThrowsError(try WalletCryptoBoxImpl().buildSecretsTranslator(verifierPublicKey: key))
        }
    }

    func testWalletResponseDecryptsAndTamperingThrows() throws {
        let wallet = WalletCryptoBoxImpl()
        let verifier = VerifierCryptoBoxImpl()
        let sender = try wallet.buildSecretsTranslator(verifierPublicKey: verifier.getPublicKey())
        let receiver = try verifier.buildSecretsTranslator(nonce: sender.getNonce(), walletPublicKey: wallet.getPublicKey())
        let message = Data("credential response".utf8)
        var encrypted = try sender.encryptToSend(data: message)
        XCTAssertEqual(try receiver.decryptUponReceive(data: encrypted), message)
        encrypted[encrypted.count - 1] ^= 1
        XCTAssertThrowsError(try receiver.decryptUponReceive(data: encrypted))
        for length in [0, 1, 15, 16] {
            XCTAssertThrowsError(try receiver.decryptUponReceive(data: Data(repeating: 0, count: length)))
        }
    }

    func testBatchProcessesEveryWriteAndRespondsOnce() {
        let writes = [write(), write(uuid: NetworkCharNums.SUBMIT_RESPONSE_CHAR_UUID)]
        var applied: [CBUUID] = []
        var results: [CBATTError.Code] = []
        VerifierWriteBatch.process(writes, onWrite: { applied.append($0); XCTAssertEqual($1, Data([1])) }, respond: { results.append($0) })
        XCTAssertEqual(applied, writes.map(\.uuid))
        XCTAssertEqual(results, [.success])
    }

    func testInvalidLaterWriteRejectsWholeBatch() {
        let invalidWrites: [(VerifierWriteBatch.Write, CBATTError.Code)] = [
            (write(offset: 1), .invalidOffset),
            (write(value: nil), .invalidAttributeValueLength),
            (write(properties: [.notify]), .writeNotPermitted),
            (write(uuid: NetworkCharNums.VERIFICATION_STATUS_CHAR_UUID), .writeNotPermitted)
        ]
        for (invalid, expected) in invalidWrites {
            var applied = 0
            var results: [CBATTError.Code] = []
            VerifierWriteBatch.process([write(), invalid], onWrite: { _, _ in applied += 1 }, respond: { results.append($0) })
            XCTAssertEqual(applied, 0)
            XCTAssertEqual(results, [expected])
        }
    }

    func testEmptyBatchDoesNotRespond() {
        VerifierWriteBatch.process([], onWrite: { _, _ in XCTFail("Unexpected write") }, respond: { _ in XCTFail("Unexpected response") })
    }

    private func write(uuid: CBUUID = NetworkCharNums.IDENTIFY_REQUEST_CHAR_UUID,
                       properties: CBCharacteristicProperties = [.write], offset: Int = 0,
                       value: Data? = Data([1])) -> VerifierWriteBatch.Write {
        VerifierWriteBatch.Write(uuid: uuid, properties: properties, offset: offset, value: value)
    }
}
