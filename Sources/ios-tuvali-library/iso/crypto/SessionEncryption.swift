import CryptoKit
import Foundation

private let gcmTagBytes = 16
private let largestMessageCounter: UInt64 = 0xFFFF_FFFF

// IV = 8-byte identifier ‖ 4-byte big-endian message counter (clause 9.1.1.5)
private let readerIdentifier = [UInt8](repeating: 0, count: 8)
private let mdocIdentifier: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1]

/// Encrypts our responses and decrypts the reader's requests with AES-256-GCM (clause 9.1.1.5).
///
/// Each direction has its own key and message counter; the first message uses counter 1 and a
/// counter value is never reused. Data is ciphertext ‖ 16-byte tag, with empty AAD. A reader
/// message that fails to decrypt leaves the counter unchanged; the session then ends anyway.
///
/// One session owns an instance. A lock guards it, so a wipe from another task is seen at once.
final class SessionEncryption: @unchecked Sendable {
    private let lock = NSLock()
    private let keys: SessionKeys
    private var lastCounterFromReader: UInt64
    private var lastCounterToReader: UInt64
    private var wiped = false

    // starting counters other than 0 are only for tests that reach the counter limit
    init(keys: SessionKeys, lastCounterFromReader: UInt64 = 0, lastCounterToReader: UInt64 = 0) {
        self.keys = keys
        self.lastCounterFromReader = lastCounterFromReader
        self.lastCounterToReader = lastCounterToReader
    }

    /// Sets up the session after the reader's first message: ECDH with the reader key, then the
    /// session keys derived with the SessionTranscriptBytes of this session as salt.
    static func establish(
        deviceKey: EphemeralDeviceKey,
        readerCoseKey: [UInt8],
        sessionTranscriptBytes: [UInt8]
    ) throws -> SessionEncryption {
        let readerKey = try ReaderPublicKey.fromCoseKey(readerCoseKey)
        var secret = try sharedSecret(deviceKey, readerKey)
        defer { zeroBytes(&secret) }
        let keys = deriveSessionKeys(sharedSecret: secret, sessionTranscriptBytes: sessionTranscriptBytes)
        return SessionEncryption(keys: keys)
    }

    func encryptForReader(_ plaintext: [UInt8]) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let counter = try nextCounter(after: lastCounterToReader)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keys.skDevice),
            nonce: try nonce(mdocIdentifier, counter)
        )
        lastCounterToReader = counter
        return [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
    }

    func decryptFromReader(_ data: [UInt8]) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let counter = try nextCounter(after: lastCounterFromReader)
        guard data.count >= gcmTagBytes else {
            throw SessionDecryptionError("Reader message \(counter) is shorter than the GCM tag")
        }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try nonce(readerIdentifier, counter),
                ciphertext: data.dropLast(gcmTagBytes),
                tag: data.suffix(gcmTagBytes)
            )
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keys.skReader))
        } catch {
            throw SessionDecryptionError("Reader message \(counter) failed authentication")
        }
        lastCounterFromReader = counter
        return [UInt8](plaintext)
    }

    /// Overwrites both session keys; any later use fails.
    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        wiped = true
        keys.wipe()
    }

    private func nextCounter(after lastCounter: UInt64) throws -> UInt64 {
        guard !wiped else { throw SessionEncryptionStateError("Session keys were wiped") }
        guard lastCounter < largestMessageCounter else {
            throw SessionEncryptionStateError("Message counter is used up; start a new session")
        }
        return lastCounter + 1
    }

    private func nonce(_ identifier: [UInt8], _ counter: UInt64) throws -> AES.GCM.Nonce {
        let counterBytes = (0..<4).reversed().map { index in UInt8(truncatingIfNeeded: counter >> (8 * UInt64(index))) }
        return try AES.GCM.Nonce(data: identifier + counterBytes)
    }
}
