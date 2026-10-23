import CryptoKit
import XCTest
@testable import ios_tuvali_library

/// AES-256-GCM with identifier ‖ counter IVs: ISO 18013-5 clause 9.1.1.5.
final class SessionEncryptionTests: XCTestCase {

    private func vectorKeys() -> SessionKeys {
        SessionKeys(skReader: SessionTestVectors.bytes("skReader"), skDevice: SessionTestVectors.bytes("skDevice"))
    }

    private func ciphertext(_ name: String) -> [UInt8] { SessionTestVectors.bytes("\(name).ciphertext") }
    private func plaintext(_ name: String) -> [UInt8] { SessionTestVectors.bytes("\(name).plaintext") }

    private func changingByte(_ index: Int, of bytes: [UInt8]) -> [UInt8] {
        var changed = bytes
        changed[index] &+= 1
        return changed
    }

    func testDecryptFromReaderDecryptsTheFirstReaderMessageWithCounter1() throws {
        let encryption = SessionEncryption(keys: vectorKeys())

        let decrypted = try encryption.decryptFromReader(ciphertext("readerToMdoc"))

        XCTAssertEqual(decrypted, plaintext("readerToMdoc"))
    }

    func testDecryptFromReaderDecryptsTheNextReaderMessageWithCounter2() throws {
        let encryption = SessionEncryption(keys: vectorKeys())
        _ = try encryption.decryptFromReader(ciphertext("readerToMdoc"))

        let decrypted = try encryption.decryptFromReader(ciphertext("readerToMdocSecond"))

        XCTAssertEqual(decrypted, plaintext("readerToMdocSecond"))
    }

    func testEncryptForReaderReproducesTheFirstMdocMessageWithCounter1() throws {
        let encryption = SessionEncryption(keys: vectorKeys())

        let encrypted = try encryption.encryptForReader(plaintext("mdocToReader"))

        XCTAssertEqual(encrypted, ciphertext("mdocToReader"))
    }

    func testEncryptForReaderUsesCounter2ForTheNextMdocMessage() throws {
        let encryption = SessionEncryption(keys: vectorKeys())
        _ = try encryption.encryptForReader(plaintext("mdocToReader"))

        let encrypted = try encryption.encryptForReader(plaintext("mdocToReaderSecond"))

        XCTAssertEqual(encrypted, ciphertext("mdocToReaderSecond"))
    }

    func testDecryptFromReaderThrowsSessionDecryptionErrorWhenTheCiphertextWasChanged() {
        let encryption = SessionEncryption(keys: vectorKeys())
        let tampered = changingByte(0, of: ciphertext("readerToMdoc"))

        XCTAssertThrowsError(try encryption.decryptFromReader(tampered), ofType: SessionDecryptionError.self)
    }

    func testDecryptFromReaderThrowsSessionDecryptionErrorWhenTheAuthenticationTagWasChanged() {
        let encryption = SessionEncryption(keys: vectorKeys())
        // the last 16 bytes are the GCM tag
        let original = ciphertext("readerToMdoc")
        let tampered = changingByte(original.count - 1, of: original)

        XCTAssertThrowsError(try encryption.decryptFromReader(tampered), ofType: SessionDecryptionError.self)
    }

    func testDecryptFromReaderThrowsSessionDecryptionErrorForAMessageEncryptedWithTheDeviceKey() {
        let encryption = SessionEncryption(keys: vectorKeys())
        // a message in the mdoc-to-reader direction, encrypted with SKDevice and the mdoc identifier
        let wrongDirection = ciphertext("mdocToReader")

        XCTAssertThrowsError(try encryption.decryptFromReader(wrongDirection), ofType: SessionDecryptionError.self)
    }

    func testDecryptFromReaderThrowsSessionDecryptionErrorWhenTheReaderSkipsACounter() {
        let encryption = SessionEncryption(keys: vectorKeys())
        // the counter 2 message arriving first, while counter 1 is expected
        let outOfOrder = ciphertext("readerToMdocSecond")

        XCTAssertThrowsError(try encryption.decryptFromReader(outOfOrder), ofType: SessionDecryptionError.self)
    }

    func testDecryptFromReaderThrowsSessionDecryptionErrorWhenTheDataIsShorterThanTheTag() {
        let encryption = SessionEncryption(keys: vectorKeys())
        // GCM data is ciphertext followed by a 16-byte tag, so 5 bytes cannot be valid
        let tooShort = [UInt8](repeating: 0, count: 5)

        XCTAssertThrowsError(try encryption.decryptFromReader(tooShort), ofType: SessionDecryptionError.self)
    }

    func testDecryptFromReaderDoesNotMoveTheCounterOnWhenDecryptionFails() throws {
        let encryption = SessionEncryption(keys: vectorKeys())
        _ = try? encryption.decryptFromReader(changingByte(0, of: ciphertext("readerToMdoc")))

        let decrypted = try encryption.decryptFromReader(ciphertext("readerToMdoc"))

        XCTAssertEqual(decrypted, plaintext("readerToMdoc"))
    }

    func testEncryptForReaderWritesTheLargestCounterAsFourUnsignedBigEndianBytes() throws {
        // the next message uses counter 0xFFFFFFFF, the last one allowed
        let encryption = SessionEncryption(keys: vectorKeys(), lastCounterToReader: 0xFFFF_FFFE)
        let message: [UInt8] = [0xa0]

        let encrypted = try encryption.encryptForReader(message)

        // decrypt independently with CryptoKit, using the mdoc identifier and counter ff ff ff ff
        let nonce = try AES.GCM.Nonce(data: "0000000000000001ffffffff".hexToBytes())
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        let key = SymmetricKey(data: SessionTestVectors.bytes("skDevice"))
        XCTAssertEqual([UInt8](try AES.GCM.open(box, using: key)), message)
    }

    func testEncryptForReaderThrowsSessionEncryptionStateErrorWhenTheMessageCounterIsUsedUp() {
        // the last message already used the largest 4-byte counter
        let encryption = SessionEncryption(keys: vectorKeys(), lastCounterToReader: 0xFFFF_FFFF)

        XCTAssertThrowsError(try encryption.encryptForReader([1]), ofType: SessionEncryptionStateError.self)
    }

    func testDecryptFromReaderThrowsSessionEncryptionStateErrorWhenTheMessageCounterIsUsedUp() {
        // the last reader message already used the largest 4-byte counter
        let encryption = SessionEncryption(keys: vectorKeys(), lastCounterFromReader: 0xFFFF_FFFF)

        XCTAssertThrowsError(try encryption.decryptFromReader([1]), ofType: SessionEncryptionStateError.self)
    }

    func testEncryptForReaderAndDecryptFromReaderThrowSessionEncryptionStateErrorAfterWipe() {
        let encryption = SessionEncryption(keys: vectorKeys())

        encryption.wipe()

        XCTAssertThrowsError(try encryption.encryptForReader([1]), ofType: SessionEncryptionStateError.self)
        let readerMessage = ciphertext("readerToMdoc")
        XCTAssertThrowsError(try encryption.decryptFromReader(readerMessage), ofType: SessionEncryptionStateError.self)
    }

    func testEstablishDerivesTheSessionFromTheDeviceKeyTheReaderKeyAndTheEngagement() throws {
        let deviceKey = try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("deviceKey.privateScalar"))
        let readerCoseKey = try untag24(decodeCbor(SessionTestVectors.bytes("readerKey.eReaderKeyBytes")))
        let deviceEngagementBytes = SessionTestVectors.bytes("deviceEngagement")
        let transcript = sessionTranscriptBytes(
            deviceEngagementBytes: deviceEngagementBytes,
            readerCoseKey: readerCoseKey
        )

        let encryption = try SessionEncryption.establish(
            deviceKey: deviceKey,
            readerCoseKey: readerCoseKey,
            sessionTranscriptBytes: transcript
        )

        XCTAssertEqual(try encryption.decryptFromReader(ciphertext("readerToMdoc")), plaintext("readerToMdoc"))
    }
}
