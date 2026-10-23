import CryptoKit
import Foundation

private let sessionKeyBytes = 32
private let infoReaderKey = Array("SKReader".utf8)
private let infoDeviceKey = Array("SKDevice".utf8)

/// SKReader encrypts the reader's requests, SKDevice our responses (clause 9.1.1.5).
final class SessionKeys {
    private(set) var skReader: [UInt8]
    private(set) var skDevice: [UInt8]

    init(skReader: [UInt8], skDevice: [UInt8]) {
        self.skReader = skReader
        self.skDevice = skDevice
    }

    /// Overwrites both keys with zeros. Copies already handed to CryptoKit for a message are its own.
    func wipe() {
        zeroBytes(&skReader)
        zeroBytes(&skDevice)
    }
}

/// Overwrites [bytes] with zeros in place.
func zeroBytes(_ bytes: inout [UInt8]) {
    for index in bytes.indices { bytes[index] = 0 }
}

/// HKDF-SHA256 over ZAB with salt SHA-256(SessionTranscriptBytes), 32 bytes each (clause 9.1.1.5).
func deriveSessionKeys(sharedSecret: [UInt8], sessionTranscriptBytes: [UInt8]) -> SessionKeys {
    let salt = [UInt8](SHA256.hash(data: sessionTranscriptBytes))
    return SessionKeys(
        skReader: hkdfSha256(sharedSecret, salt: salt, info: infoReaderKey, length: sessionKeyBytes),
        skDevice: hkdfSha256(sharedSecret, salt: salt, info: infoDeviceKey, length: sessionKeyBytes)
    )
}
