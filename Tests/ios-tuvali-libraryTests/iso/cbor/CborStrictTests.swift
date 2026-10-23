@testable import ios_tuvali_library
import XCTest

/// Strict encoding checks for what Tuvali sends: ISO 18013-5 clause 8.1 rules 1 to 3.
final class CborStrictTests: XCTestCase {

    func testRequireStrictCborAcceptsShortestIntegersLengthsAndDefiniteContainers() throws {
        // {"a": [1, 24, 256], "b": h'00'} with every argument in its shortest form
        let strict = "a261618301181819010061624100".hexToBytes()

        try requireStrictCbor(strict)
    }

    func testRequireStrictCborThrowsCborDecodingErrorForAnIntegerInALongerFormThanNeeded() {
        // 1 written with a one-byte argument (18 01) instead of inline (01)
        let notShortest = "1801".hexToBytes()

        XCTAssertThrowsError(try requireStrictCbor(notShortest), ofType: CborDecodingError.self)
    }

    func testRequireStrictCborThrowsCborDecodingErrorForALengthInALongerFormThanNeeded() {
        // a 1-byte byte string with its length written as 58 01 instead of inline 41
        let notShortest = "580100".hexToBytes()

        XCTAssertThrowsError(try requireStrictCbor(notShortest), ofType: CborDecodingError.self)
    }

    func testRequireStrictCborThrowsCborDecodingErrorForAnIndefiniteLengthArray() {
        // [_ 1, 2]
        let indefinite = "9f0102ff".hexToBytes()

        XCTAssertThrowsError(try requireStrictCbor(indefinite), ofType: CborDecodingError.self)
    }

    func testRequireStrictCborThrowsCborDecodingErrorForANonShortestArgumentNestedInsideAMap() {
        // {"a": 1} with the value 1 written as 18 01
        let nested = "a161611801".hexToBytes()

        XCTAssertThrowsError(try requireStrictCbor(nested), ofType: CborDecodingError.self)
    }
}
