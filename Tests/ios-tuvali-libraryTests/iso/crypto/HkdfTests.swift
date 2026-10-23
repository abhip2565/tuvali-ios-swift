import XCTest
@testable import ios_tuvali_library

/// Tuvali's own HKDF-SHA256 (RFC 5869); CryptoKit's general HKDF needs iOS 14.
final class HkdfTests: XCTestCase {

    func testHkdfSha256MatchesRfc5869TestCase1() {
        // RFC 5869 appendix A.1
        let inputKeyMaterial = [UInt8](repeating: 0x0b, count: 22)
        let salt = "000102030405060708090a0b0c".hexToBytes()
        let info = "f0f1f2f3f4f5f6f7f8f9".hexToBytes()

        let output = hkdfSha256(inputKeyMaterial, salt: salt, info: info, length: 42)

        let expected = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        XCTAssertEqual(output.hex, expected)
    }

    func testHkdfSha256ProducesTheLongestOutputRfc5869AllowsWithoutOverflowingTheBlockCounter() {
        // 255 blocks of 32 bytes, the RFC 5869 limit: the block counter ends at 255, the largest byte
        let longest = 255 * 32

        let output = hkdfSha256([0x01], salt: nil, info: [], length: longest)

        XCTAssertEqual(output.count, longest)
    }
}
