import XCTest
@testable import ios_tuvali_library

/// SKReader and SKDevice from HKDF-SHA256: ISO 18013-5 clause 9.1.1.5.
final class SessionKeysTests: XCTestCase {
    private let secret = SessionTestVectors.bytes("sharedSecret")

    func testDeriveSessionKeysReproducesSkReaderAndSkDeviceOfTheTestVectors() {
        let transcript = SessionTestVectors.bytes("sessionTranscriptBytes")

        let keys = deriveSessionKeys(sharedSecret: secret, sessionTranscriptBytes: transcript)

        XCTAssertEqual(keys.skReader.hex, SessionTestVectors.string("skReader"))
        XCTAssertEqual(keys.skDevice.hex, SessionTestVectors.string("skDevice"))
    }

    func testDeriveSessionKeysGivesDifferentKeysWhenTheTranscriptHasANonCanonicalReaderKey() {
        // same key material, but the transcript embeds the reader key bytes exactly as received
        let oddTranscript = SessionTestVectors.bytes("nonCanonicalReaderKey.sessionTranscriptBytes")

        let keys = deriveSessionKeys(sharedSecret: secret, sessionTranscriptBytes: oddTranscript)

        XCTAssertEqual(keys.skReader.hex, SessionTestVectors.string("nonCanonicalReaderKey.skReader"))
        XCTAssertEqual(keys.skDevice.hex, SessionTestVectors.string("nonCanonicalReaderKey.skDevice"))
    }

    func testWipeOverwritesBothKeysWithZeros() {
        let transcript = SessionTestVectors.bytes("sessionTranscriptBytes")
        let keys = deriveSessionKeys(sharedSecret: secret, sessionTranscriptBytes: transcript)

        keys.wipe()

        XCTAssertEqual(keys.skReader, [UInt8](repeating: 0, count: 32))
        XCTAssertEqual(keys.skDevice, [UInt8](repeating: 0, count: 32))
    }
}
