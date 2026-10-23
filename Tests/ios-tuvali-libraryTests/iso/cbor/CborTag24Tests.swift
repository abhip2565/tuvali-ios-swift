@testable import ios_tuvali_library
import SwiftCBOR
import XCTest

/// Tag 24 (embedded CBOR) per RFC 7049 section 2.4. ISO 18013-5 clause 8.1 requires these
/// embedded bytes to be used exactly as sent or received in cryptographic operations.
final class CborTag24Tests: XCTestCase {

    func testTag24WrapsAlreadyEncodedBytesInTag24WithoutReEncodingThem() {
        // RFC 8949 Appendix A example 24(h'6449455446')
        let embedded = "6449455446".hexToBytes()

        let encoded = encodeCbor(tag24(encodedCbor: embedded))

        XCTAssertEqual(encoded.hex, "d818456449455446")
    }

    func testTag24EncodesADataItemAndWrapsTheEncodedBytesInTag24() {
        let item = CBOR.utf8String("IETF")

        let encoded = encodeCbor(tag24(item))

        XCTAssertEqual(encoded.hex, "d818456449455446")
    }

    func testTag24OfTheDeviceCoseKeyMatchesEDeviceKeyBytesFromTheTestVectors() throws {
        let coseKey = try decodeCbor(SessionTestVectors.bytes("deviceKey.coseKey"))

        let eDeviceKeyBytes = encodeCbor(tag24(coseKey))

        XCTAssertEqual(eDeviceKeyBytes.hex, SessionTestVectors.bytes("deviceKey.eDeviceKeyBytes").hex)
    }

    func testUntag24ReturnsTheEmbeddedBytesExactlyAsReceived() throws {
        let received = try decodeCbor(SessionTestVectors.bytes("deviceKey.eDeviceKeyBytes"))

        let embedded = try untag24(received)

        XCTAssertEqual(embedded.hex, SessionTestVectors.bytes("deviceKey.coseKey").hex)
    }

    func testUntag24KeepsANonShortestEmbeddedEncodingUnchanged() throws {
        // 24(h'1800') embeds the integer 0 written in a non-shortest form
        let received = try decodeCbor("d818421800".hexToBytes())

        let embedded = try untag24(received)

        XCTAssertEqual(embedded.hex, "1800")
    }

    func testDecodeTag24DecodesTheItemEmbeddedInATag24ByteString() throws {
        let received = try decodeCbor("d818421800".hexToBytes())

        let item = try decodeTag24(received)

        XCTAssertEqual(item, .unsignedInt(0))
    }

    func testUntag24ThrowsCborDecodingErrorWhenTheByteStringHasNoTag() {
        let untagged = CBOR.byteString([0x00])

        XCTAssertThrowsError(try untag24(untagged), ofType: CborDecodingError.self)
    }

    func testUntag24ThrowsCborDecodingErrorWhenTheByteStringHasATagOtherThan24() throws {
        // 25(h'1800')
        let otherTag = try decodeCbor("d819421800".hexToBytes())

        XCTAssertThrowsError(try untag24(otherTag), ofType: CborDecodingError.self)
    }

    func testUntag24ThrowsCborDecodingErrorWhenTheItemIsNotAByteString() {
        let notAByteString = CBOR.unsignedInt(24)

        XCTAssertThrowsError(try untag24(notAByteString), ofType: CborDecodingError.self)
    }
}
