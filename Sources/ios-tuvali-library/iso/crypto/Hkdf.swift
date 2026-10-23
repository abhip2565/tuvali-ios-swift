import CryptoKit
import Foundation

private let sha256OutputBytes = 32

/// The longest output RFC 5869 allows: 255 blocks of the hash's output size.
let hkdfSha256MaximumLength = 255 * sha256OutputBytes

/// HKDF-SHA256 (RFC 5869) on HMAC-SHA256, which CryptoKit has from iOS 13 (its HKDF needs iOS 14).
/// A nil [salt] means "no salt", which HKDF treats as 32 zero bytes. [length] may be at most
/// hkdfSha256MaximumLength (8160 bytes); asking for more is a programming error.
func hkdfSha256(_ inputKeyMaterial: [UInt8], salt: [UInt8]?, info: [UInt8], length: Int) -> [UInt8] {
    precondition(length <= hkdfSha256MaximumLength, "HKDF-SHA256 output is limited to \(hkdfSha256MaximumLength) bytes")
    // extract
    let saltKey = SymmetricKey(data: salt ?? [UInt8](repeating: 0, count: sha256OutputBytes))
    let extracted = HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: saltKey)
    let pseudorandomKey = SymmetricKey(data: Data(extracted))
    // expand: T(i) = HMAC(PRK, T(i - 1) ‖ info ‖ i) for i = 1 ... N, where N is at most 255
    let blockCount = (length + sha256OutputBytes - 1) / sha256OutputBytes
    var output: [UInt8] = []
    var previousBlock: [UInt8] = []
    for blockIndex in stride(from: 1, through: blockCount, by: 1) {
        // blockIndex is at most 255, so it fits the one byte RFC 5869 gives it
        let blockInput = previousBlock + info + [UInt8(blockIndex)]
        let block = HMAC<SHA256>.authenticationCode(for: blockInput, using: pseudorandomKey)
        previousBlock = [UInt8](block)
        output += previousBlock
    }
    return Array(output.prefix(length))
}
