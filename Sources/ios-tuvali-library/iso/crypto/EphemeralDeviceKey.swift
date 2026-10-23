import CryptoKit
import Foundation

/// Size of a P-256 coordinate, private scalar or ECDH secret in bytes.
let p256FieldBytes = 32

/// The mdoc's ephemeral P-256 key pair for one session (EDeviceKey, ISO 18013-5 clause 9.1.1.4).
///
/// wipe() drops the private key at the end of the session. CryptoKit keys cannot be overwritten
/// in memory, so wiping means "no longer reachable or usable", not "zeroed".
/// The private key is guarded by a lock, so a wipe on one task is seen at once by another.
final class EphemeralDeviceKey: @unchecked Sendable {
    private let lock = NSLock()
    private var privateKey: P256.KeyAgreement.PrivateKey?

    let publicKey: P256.KeyAgreement.PublicKey

    /// Affine x coordinate, always 32 bytes big-endian (left-padded with zeros).
    let x: [UInt8]

    /// Affine y coordinate, always 32 bytes big-endian (left-padded with zeros).
    let y: [UInt8]

    private init(_ privateKey: P256.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        publicKey = privateKey.publicKey
        // the raw representation is x ‖ y, each a fixed 32 bytes
        let coordinates = [UInt8](publicKey.rawRepresentation)
        x = Array(coordinates[0..<p256FieldBytes])
        y = Array(coordinates[p256FieldBytes...])
    }

    static func generate() -> EphemeralDeviceKey {
        EphemeralDeviceKey(P256.KeyAgreement.PrivateKey())
    }

    /// Rebuilds a key from its 32-byte big-endian private scalar; used with fixed test vectors.
    /// Throws if the scalar is not in [1, n - 1].
    static func fromPrivateScalar(_ scalar: [UInt8]) throws -> EphemeralDeviceKey {
        EphemeralDeviceKey(try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar))
    }

    func requirePrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        guard let privateKey = privateKey else { throw DeviceKeyWipedError() }
        return privateKey
    }

    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        privateKey = nil
    }
}
