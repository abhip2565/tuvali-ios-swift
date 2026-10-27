import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// The session messages, SessionEstablishment and SessionData: ISO 18013-5 clause 9.1.1.4.
final class SessionMessageTests: XCTestCase {

    private func decodedData(_ message: [UInt8]) throws -> SessionData? {
        guard case let .data(data) = try SessionMessage.decode(message) else { return nil }
        return data
    }

    func testDecodeReadsASessionEstablishmentWithTheReaderKeyBytesAsSentAndTheEncryptedRequest() throws {
        let bytes = SessionTestVectors.bytes("session.sessionEstablishment")
        let vectorReaderKey = try untag24(decodeCbor(SessionTestVectors.bytes("readerKey.eReaderKeyBytes")))

        let message = try SessionMessage.decode(bytes)

        guard case let .establishment(establishment) = message else { return XCTFail("Not a SessionEstablishment") }
        XCTAssertEqual(establishment.readerCoseKey, vectorReaderKey)
        XCTAssertEqual(establishment.data.count, SessionTestVectors.bytes("session.twoDocRequest").count + 16)
    }

    func testDecodeReadsAMessageWithoutEReaderKeyAsSessionData() throws {
        // only SessionEstablishment carries eReaderKey
        let withoutKey = encodeCbor(["data": .byteString([1])])

        let data = try decodedData(withoutKey)

        XCTAssertEqual(data?.data, [1])
    }

    func testDecodeThrowsCborDecodingErrorWhenEReaderKeyIsNotTag24() {
        // the key as a plain byte string, without the tag 24 wrapper
        let untagged = encodeCbor(["eReaderKey": .byteString([1]), "data": .byteString([1])])

        XCTAssertThrowsError(try SessionMessage.decode(untagged), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenASessionEstablishmentHasNoData() {
        let withoutData = encodeCbor(["eReaderKey": tag24(encodedCbor: [0xa0])])

        XCTAssertThrowsError(try SessionMessage.decode(withoutData), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenTheMessageIsNotAMap() {
        let notAMap = "80".hexToBytes()

        XCTAssertThrowsError(try SessionMessage.decode(notAMap), ofType: CborDecodingError.self)
    }

    func testSessionDataEncodeWritesOnlyTheDataWhenThereIsNoStatus() {
        let data = "a1b2".hexToBytes()

        let encoded = SessionData(data: data).encode()

        XCTAssertEqual(encoded.hex, "a1646461746142a1b2")
    }

    func testSessionDataEncodeWritesOnlyTheStatusForASessionTermination() {
        let encoded = SessionData(status: SessionStatus.sessionTermination).encode()

        XCTAssertEqual(encoded.hex, SessionTestVectors.string("session.statusTermination"))
    }

    func testDecodeThrowsCborDecodingErrorWhenStatus10Or11ComesWithData() {
        // Table 20: with status 10 or 11 the data element shall not be present
        let encryptionError = encodeCbor(["data": .byteString([1]), "status": 10])
        let cborError = encodeCbor(["data": .byteString([1]), "status": 11])

        XCTAssertThrowsError(try SessionMessage.decode(encryptionError), ofType: CborDecodingError.self)
        XCTAssertThrowsError(try SessionMessage.decode(cborError), ofType: CborDecodingError.self)
    }

    func testDecodeReadsStatus20WithDataAsSessionData() throws {
        // Table 20 allows data alongside status 20: the last answer and the end together
        let lastAnswer = encodeCbor(["data": .byteString([1]), "status": 20])

        let data = try decodedData(lastAnswer)

        XCTAssertEqual(data, SessionData(data: [1], status: 20))
    }

    func testDecodeReadsAReadersStatusMessageAsSessionData() throws {
        let readerEnds = SessionTestVectors.bytes("session.statusTermination")

        let data = try decodedData(readerEnds)

        XCTAssertEqual(data?.status, 20)
        XCTAssertNil(data?.data)
    }

    func testDecodeIgnoresKeysItDoesNotKnow() throws {
        // a later version might add keys; this one carries an extra "x"
        let withExtra = encodeCbor(["data": .byteString([7]), "x": 1])

        let data = try decodedData(withExtra)

        XCTAssertEqual(data?.data, [7])
    }

    func testDecodeThrowsCborDecodingErrorWhenDataIsNotAByteString() {
        let wrongType = encodeCbor(["data": "text"])

        XCTAssertThrowsError(try SessionMessage.decode(wrongType), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenStatusIsNotAnUnsignedInteger() {
        let wrongType = encodeCbor(["status": "20"])

        XCTAssertThrowsError(try SessionMessage.decode(wrongType), ofType: CborDecodingError.self)
    }
}
