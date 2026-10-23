@testable import ios_tuvali_library
import SwiftCBOR
import XCTest

/// Decoding data received from a reader. Valid but non-canonical input is accepted; malformed or
/// hostile input fails with CborDecodingError (later mapped to session status 11).
final class CborDecodingTests: XCTestCase {

    // MARK: valid input

    func testDecodeCborReadsIntegersWrittenInANonShortestForm() throws {
        let zeroWithOneByteArgument = "1800".hexToBytes()
        let zeroWithFourByteArgument = "1a00000000".hexToBytes()

        let first = try decodeCbor(zeroWithOneByteArgument)
        let second = try decodeCbor(zeroWithFourByteArgument)

        XCTAssertEqual(first, .unsignedInt(0))
        XCTAssertEqual(second, .unsignedInt(0))
    }

    func testDecodeCborReadsAByteStringWhoseLengthIsWrittenInANonShortestForm() throws {
        let oneByteWithOneByteLength = "580101".hexToBytes()

        let decoded = try decodeCbor(oneByteWithOneByteLength)

        XCTAssertEqual(decoded, .byteString([0x01]))
    }

    func testDecodeCborReadsTrueAndNullAsSimpleValues() throws {
        let trueValue = "f5".hexToBytes()
        let nullValue = "f6".hexToBytes()

        let decodedTrue = try decodeCbor(trueValue)
        let decodedNull = try decodeCbor(nullValue)

        XCTAssertEqual(decodedTrue, .boolean(true))
        XCTAssertEqual(decodedNull, .null)
    }

    func testDecodeCborReturnsAnIndefiniteLengthArrayThatReEncodesWithADefiniteLength() throws {
        // [_ 1, 2]
        let indefiniteArray = "9f0102ff".hexToBytes()

        let reEncoded = encodeCbor(try decodeCbor(indefiniteArray))

        XCTAssertEqual(reEncoded.hex, "820102")
    }

    func testDecodeCborReturnsAnIndefiniteLengthByteStringThatReEncodesWithADefiniteLength() throws {
        // (_ h'0102', h'030405')
        let indefiniteBytes = "5f42010243030405ff".hexToBytes()

        let reEncoded = encodeCbor(try decodeCbor(indefiniteBytes))

        XCTAssertEqual(reEncoded.hex, "450102030405")
    }

    func testDecodeCborReturnsAnIndefiniteLengthTextStringThatReEncodesWithADefiniteLength() throws {
        // (_ "strea", "ming")
        let indefiniteText = "7f657374726561646d696e67ff".hexToBytes()

        let reEncoded = encodeCbor(try decodeCbor(indefiniteText))

        XCTAssertEqual(reEncoded.hex, "6973747265616d696e67")
    }

    func testDecodeCborReturnsAnIndefiniteLengthMapWithANestedIndefiniteArrayThatReEncodesDefinite() throws {
        // {_ "a": 1, "b": [_ 2, 3]}
        let indefiniteMap = "bf61610161629f0203ffff".hexToBytes()

        let reEncoded = encodeCbor(try decodeCbor(indefiniteMap))

        XCTAssertEqual(reEncoded.hex, "a26161016162820203")
    }

    func testDecodeCborFollowedByEncodeCborReproducesTheDeviceEngagementTestVectorExactly() throws {
        let deviceEngagement = SessionTestVectors.bytes("deviceEngagement")

        let reEncoded = encodeCbor(try decodeCbor(deviceEngagement))

        XCTAssertEqual(reEncoded.hex, deviceEngagement.hex)
    }

    func testDecodeCborAcceptsNestingOneLevelBelowTheMaximumDepth() throws {
        let nestedArrays = [UInt8](repeating: 0x81, count: maxCborNestingDepth - 1) + [0x00]

        let decoded = try decodeCbor(nestedArrays)

        guard case .array = decoded else { return XCTFail("Expected an array, got \(decoded)") }
    }

    // MARK: malformed or hostile input

    func testDecodeCborThrowsCborDecodingErrorWhenTheInputIsEmpty() {
        let empty: [UInt8] = []

        XCTAssertThrowsError(try decodeCbor(empty), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAnIntegerArgumentIsCutShort() {
        // a two-byte argument with only one byte present
        let truncatedInteger = "1903".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(truncatedInteger), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAnArrayHasFewerItemsThanItsCount() {
        // an array of 2 with only 1 item
        let truncatedArray = "8201".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(truncatedArray), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAByteStringIsShorterThanItsDeclaredLength() {
        // declares 4 bytes, carries 2
        let truncatedBytes = "440102".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(truncatedBytes), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAMapKeyHasNoValue() {
        // a map of 1 with a key and no value
        let truncatedMap = "a101".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(truncatedMap), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenATagHasNoContent() {
        // tag 24 with nothing after it
        let emptyTag = "d818".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(emptyTag), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenBytesFollowTheItem() {
        // the integer 0 followed by an extra byte
        let trailingBytes = "0001".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(trailingBytes), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWithoutAllocatingWhenADeclaredLengthExceedsTheInput() {
        // declares a 4 GiB byte string, carries 1 byte
        let hugeDeclaredLength = "5affffffff00".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(hugeDeclaredLength), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAMapRepeatsAKey() {
        // {1: 1, 1: 2}
        let duplicateKey = "a201010102".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(duplicateKey), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenANestedMapRepeatsAKey() {
        // {1: {1: 1, 1: 2}}
        let nestedDuplicateKey = "a101a201010102".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(nestedDuplicateKey), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAnIndefiniteLengthMapRepeatsAKey() {
        // {_ 1: 1, 1: 2}
        let duplicateKey = "bf01010102ff".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(duplicateKey), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAnIndefiniteLengthMapHasAKeyWithoutAValue() {
        // {_ 1: 1, 2}
        let oddItemCount = "bf010102ff".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(oddItemCount), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenAnIndefiniteByteStringContainsANonStringChunk() {
        // (_ 1)
        let badChunk = "5f01ff".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(badChunk), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorWhenABreakAppearsOutsideAnIndefiniteItem() {
        let strayBreak = "ff".hexToBytes()

        XCTAssertThrowsError(try decodeCbor(strayBreak), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorInsteadOfOverflowingTheStackWhenNestingExceedsTheLimit() {
        // 100,000 nested arrays
        let deeplyNested = [UInt8](repeating: 0x81, count: 100_000) + [0x00]

        XCTAssertThrowsError(try decodeCbor(deeplyNested), ofType: CborDecodingError.self)
    }

    func testDecodeCborThrowsCborDecodingErrorForAByteStringLongerThanSwiftCborAccepts() {
        // SwiftCBOR refuses strings and counts above 200,000; a reader request is far smaller
        let tooLong = "5a00030d41".hexToBytes() + [UInt8](repeating: 0, count: 200_001)

        XCTAssertThrowsError(try decodeCbor(tooLong), ofType: CborDecodingError.self)
    }
}
