@testable import ios_tuvali_library
import SwiftCBOR
import XCTest

/// Encoding rules from ISO 18013-5 clause 8.1: shortest integers, shortest lengths, definite
/// lengths, no duplicate keys. Map keys are sorted bytewise. Expected bytes come from RFC 8949
/// Appendix A and from the independent session test vectors.
final class CborEncodingTests: XCTestCase {

    func testEncodeCborWritesUnsignedIntegersUpTo23InsideTheInitialByte() {
        let values: CBOR = [0, 23]

        let encoded = encodeCbor(values)

        XCTAssertEqual(encoded.hex, "820017")
    }

    func testEncodeCborWritesUnsignedIntegersFrom24To255WithAOneByteArgument() {
        let values: CBOR = [24, 255]

        let encoded = encodeCbor(values)

        XCTAssertEqual(encoded.hex, "82181818ff")
    }

    func testEncodeCborWritesUnsignedIntegersFrom256To65535WithATwoByteArgument() {
        let values: CBOR = [256, 1000]

        let encoded = encodeCbor(values)

        XCTAssertEqual(encoded.hex, "821901001903e8")
    }

    func testEncodeCborWritesUnsignedIntegersThatFitIn32BitsWithAFourByteArgument() {
        let value: CBOR = [1_000_000]

        let encoded = encodeCbor(value)

        XCTAssertEqual(encoded.hex, "811a000f4240")
    }

    func testEncodeCborWritesUnsignedIntegersAbove32BitsWithAnEightByteArgument() {
        let value: CBOR = [.unsignedInt(1_000_000_000_000)]

        let encoded = encodeCbor(value)

        XCTAssertEqual(encoded.hex, "811b000000e8d4a51000")
    }

    func testEncodeCborWritesNegativeIntegersInTheShortestForm() {
        let values: CBOR = [-1, -24, -25, -1000]

        let encoded = encodeCbor(values)

        // -1 -> 20, -24 -> 37, -25 -> 38 18, -1000 -> 39 03 e7
        XCTAssertEqual(encoded.hex, "84203738183903e7")
    }

    func testEncodeCborWritesAByteStringLengthUpTo23InsideTheInitialByte() {
        let bytes = CBOR.byteString([UInt8](repeating: 0, count: 23))

        let encoded = encodeCbor(bytes)

        XCTAssertEqual(String(encoded.hex.prefix(2)), "57")
        XCTAssertEqual(encoded.count, 1 + 23)
    }

    func testEncodeCborWritesAByteStringLengthOf24WithAOneByteLength() {
        let bytes = CBOR.byteString([UInt8](repeating: 0, count: 24))

        let encoded = encodeCbor(bytes)

        XCTAssertEqual(String(encoded.hex.prefix(4)), "5818")
        XCTAssertEqual(encoded.count, 2 + 24)
    }

    func testEncodeCborWritesAByteStringLengthOf256WithATwoByteLength() {
        let bytes = CBOR.byteString([UInt8](repeating: 0, count: 256))

        let encoded = encodeCbor(bytes)

        XCTAssertEqual(String(encoded.hex.prefix(6)), "590100")
        XCTAssertEqual(encoded.count, 3 + 256)
    }

    func testEncodeCborWritesAnEmptyByteStringAsASingleByte() {
        let bytes = CBOR.byteString([])

        let encoded = encodeCbor(bytes)

        XCTAssertEqual(encoded.hex, "40")
    }

    func testEncodeCborWritesTextStringsAsUtf8BytesWithTheirByteLength() {
        let ascii = CBOR.utf8String("IETF")
        let nonAscii = CBOR.utf8String("ü")

        let encodedAscii = encodeCbor(ascii)
        let encodedNonAscii = encodeCbor(nonAscii)

        XCTAssertEqual(encodedAscii.hex, "6449455446")
        XCTAssertEqual(encodedNonAscii.hex, "62c3bc")
    }

    func testEncodeCborWritesAnArrayCountOf24WithAOneByteCount() {
        let array = CBOR.array([CBOR](repeating: 0, count: 24))

        let encoded = encodeCbor(array)

        XCTAssertEqual(String(encoded.hex.prefix(4)), "9818")
    }

    func testEncodeCborWritesNestedArraysWithDefiniteLengths() {
        let nested: CBOR = [1, [2, 3], [4, 5]]

        let encoded = encodeCbor(nested)

        XCTAssertEqual(encoded.hex, "8301820203820405")
    }

    func testEncodeCborWritesFalseTrueAndNullAsSimpleValues() {
        let values: CBOR = [false, true, .null]

        let encoded = encodeCbor(values)

        XCTAssertEqual(encoded.hex, "83f4f5f6")
    }

    func testEncodeCborWritesAMapWithTextKeysAndAnArrayValue() {
        let map: CBOR = ["a": 1, "b": [2, 3]]

        let encoded = encodeCbor(map)

        XCTAssertEqual(encoded.hex, "a26161016162820203")
    }

    func testEncodeCborSortsMapKeysBytewise() {
        // built as 3 then 1; a Swift dictionary has no order, so keys go out sorted
        let map: CBOR = [3: 0, 1: 0]

        let encoded = encodeCbor(map)

        XCTAssertEqual(encoded.hex, "a201000300")
    }

    func testEncodeCborReproducesTheDeviceCoseKeyBytesFromTheIndependentTestVectors() throws {
        let vectorCoseKey = SessionTestVectors.bytes("deviceKey.coseKey")
        guard case let .map(decodedVector)? = try CBOR.decode(vectorCoseKey),
              let x = decodedVector[-2], let y = decodedVector[-3]
        else { return XCTFail("The COSE key vector has no x or y") }
        let coseKey: CBOR = [1: 2, -1: 1, -2: x, -3: y]

        let encoded = encodeCbor(coseKey)

        XCTAssertEqual(encoded.hex, vectorCoseKey.hex)
    }
}
