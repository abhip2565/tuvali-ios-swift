import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// EReaderKey checks before ECDH: ISO 18013-5 clauses 9.1.1.4 and 9.1.5.2, GOV.UK mDLR_MS_SE_06.
final class ReaderPublicKeyTests: XCTestCase {
    private var readerCoseKey: [UInt8]!
    private var readerX: [UInt8]!
    private var readerY: [UInt8]!

    override func setUpWithError() throws {
        readerCoseKey = SessionTestVectors.bytes("readerKey.coseKey")
        let decoded = try decodeCbor(readerCoseKey)
        readerX = try XCTUnwrap(decoded.value(at: -2).bytes)
        readerY = try XCTUnwrap(decoded.value(at: -3).bytes)
    }

    private func coseKey(keyType: Int = 2, curve: Int = 1, x: [UInt8]? = nil, y: CBOR? = nil) -> [UInt8] {
        encodeCbor(.map([
            1: CBOR(integerLiteral: keyType),
            -1: CBOR(integerLiteral: curve),
            -2: .byteString(x ?? readerX),
            -3: y ?? .byteString(readerY),
        ]))
    }

    func testFromCoseKeyAcceptsTheReaderKeyOfTheTestVectors() throws {
        let key = try ReaderPublicKey.fromCoseKey(readerCoseKey)

        XCTAssertEqual(key.x, readerX)
        XCTAssertEqual(key.y, readerY)
    }

    func testFromCoseKeyIgnoresOptionalParametersItDoesNotUse() throws {
        // label 2 is the optional COSE "kid" parameter
        let withKeyId = encodeCbor(.map([
            1: 2, -1: 1, -2: .byteString(readerX), -3: .byteString(readerY), 2: .byteString([7]),
        ]))

        let key = try ReaderPublicKey.fromCoseKey(withKeyId)

        XCTAssertEqual(key.x, readerX)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenThePointIsNotOnTheCurve() {
        // the vector's x with its y changed in the last byte
        var offCurveY = readerY!
        offCurveY[31] &+= 1

        let offCurve = coseKey(y: .byteString(offCurveY))

        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(offCurve), ofType: InvalidReaderKeyError.self)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenBothCoordinatesAreZero() {
        let zero = [UInt8](repeating: 0, count: 32)

        let zeroPoint = coseKey(x: zero, y: .byteString(zero))

        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(zeroPoint), ofType: InvalidReaderKeyError.self)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenTheCurveIsNotP256() {
        // IANA COSE registry: crv 2 is P-384
        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(coseKey(curve: 2)), ofType: InvalidReaderKeyError.self)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenTheKeyTypeIsNotEc2() {
        // IANA COSE registry: kty 1 is OKP
        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(coseKey(keyType: 1)), ofType: InvalidReaderKeyError.self)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenTheKeyIsInCompressedForm() {
        // compressed EC2 keys carry a sign bit (a boolean) in place of the y coordinate
        let compressed = coseKey(y: .boolean(true))

        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(compressed), ofType: InvalidReaderKeyError.self)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenACoordinateIsNot32Bytes() {
        let shortX = Array(readerX[1...])

        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(coseKey(x: shortX)), ofType: InvalidReaderKeyError.self)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenTheKeyTypeIsMissing() {
        let withoutKeyType = encodeCbor(.map([-1: 1, -2: .byteString(readerX), -3: .byteString(readerY)]))

        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(withoutKeyType), ofType: InvalidReaderKeyError.self)
    }

    func testFromCoseKeyThrowsInvalidReaderKeyErrorWhenTheKeyIsNotAMap() {
        let notAMap = encodeCbor([1, 2])

        XCTAssertThrowsError(try ReaderPublicKey.fromCoseKey(notAMap), ofType: InvalidReaderKeyError.self)
    }
}
