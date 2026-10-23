import CryptoKit
import Foundation

/// ECKA-DH between our private key and the reader's public key (clause 9.1.1.5): ZAB, the
/// x coordinate of the shared point, always 32 bytes (CryptoKit keeps the leading zeros).
func sharedSecret(_ deviceKey: EphemeralDeviceKey, _ readerKey: ReaderPublicKey) throws -> [UInt8] {
    let secret = try deviceKey.requirePrivateKey().sharedSecretFromKeyAgreement(with: readerKey.publicKey)
    return secret.withUnsafeBytes { [UInt8]($0) }
}
