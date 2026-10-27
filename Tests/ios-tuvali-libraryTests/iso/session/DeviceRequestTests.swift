import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// DeviceRequest, DocRequest and ItemsRequest: ISO 18013-5 clause 8.3.2.1.2.1.
final class DeviceRequestTests: XCTestCase {

    private let twoDocRequest = SessionTestVectors.bytes("session.twoDocRequest")

    private func itemsRequest(nameSpaces: CBOR = ["org.iso.18013.5.1": ["family_name": true]]) -> [UInt8] {
        encodeCbor(["docType": "org.iso.18013.5.1.mDL", "nameSpaces": nameSpaces])
    }

    private func deviceRequest(version: String = "1.0", items: [UInt8]? = nil, docRequest: CBOR? = nil) -> [UInt8] {
        let request = docRequest ?? ["itemsRequest": tag24(encodedCbor: items ?? itemsRequest())]
        return encodeCbor(["version": .utf8String(version), "docRequests": [request]])
    }

    /// Decodes with a check that only tells signed from unsigned requests.
    private func decodeRequest(_ plaintext: [UInt8]) throws -> DeviceRequest {
        try DeviceRequest.decode(plaintext) { readerAuth, _ in
            readerAuth == nil ? .notSigned : .invalid(reason: "not checked here")
        }
    }

    func testDecodeReadsEveryDocRequestOfTheTestVectorRequest() throws {
        let request = try decodeRequest(twoDocRequest)

        XCTAssertEqual(request.version, "1.0")
        XCTAssertEqual(request.docRequests.map(\.docType), ["org.iso.18013.5.1.mDL", "org.example.test.1"])
    }

    func testDecodeReadsEachRequestedElementWithItsIntentToRetainFlag() throws {
        let request = try decodeRequest(twoDocRequest)

        let mdlElements = request.docRequests[0].nameSpaces["org.iso.18013.5.1"]

        XCTAssertEqual(mdlElements, ["family_name": true, "portrait": false, "age_over_18": false])
    }

    func testDecodeKeepsEachItemsRequestsBytesExactlyAsReceived() throws {
        let request = try decodeRequest(twoDocRequest)

        XCTAssertEqual(request.docRequests[0].itemsRequestBytes.hex, SessionTestVectors.string("session.mdlItemsRequestBytes"))
        XCTAssertEqual(
            request.docRequests[1].itemsRequestBytes.hex,
            SessionTestVectors.string("session.secondDocItemsRequestBytes")
        )
    }

    func testDecodeIgnoresRequestInfoAndLeavesReaderAuthEmptyWhenTheReaderDidNotSign() throws {
        // the second docRequest carries requestInfo {"purpose": "test"} and no readerAuth
        let request = try decodeRequest(twoDocRequest)

        XCTAssertEqual(Set(request.docRequests[1].nameSpaces.keys), ["org.example.test.ns"])
        XCTAssertEqual(request.docRequests[1].readerTrust, .notSigned)
    }

    func testDecodeHandsEachReaderAuthAndItsItemsRequestBytesToTheCheckAndKeepsTheResult() throws {
        // a placeholder COSE_Sign1 array; checking it is reader authentication's job
        let signedDocRequest: CBOR = ["itemsRequest": tag24(encodedCbor: itemsRequest()), "readerAuth": [1, 2]]
        var checked: [(signed: Bool, itemsRequestBytes: [UInt8])] = []

        let request = try DeviceRequest.decode(deviceRequest(docRequest: signedDocRequest)) { readerAuth, itemsRequestBytes in
            checked.append((readerAuth != nil, itemsRequestBytes))
            return .invalid(reason: "placeholder")
        }

        XCTAssertEqual(checked.map(\.signed), [true])
        XCTAssertEqual(checked.map(\.itemsRequestBytes), [itemsRequest()])
        XCTAssertEqual(request.docRequests[0].readerTrust, .invalid(reason: "placeholder"))
    }

    func testDecodeIgnoresRequestInfoWithArbitraryNestedMapKeysAndPreservesSignedBytes() throws {
        let extensions: CBOR = .map([
            .boolean(true): .array([.map([.array([.map([1: 2, 3: 4])]): .null])]),
            .byteString([0]): .map([.null: 1]),
        ])
        let items = encodeCbor([
            "docType": "org.iso.18013.5.1.mDL",
            "nameSpaces": ["ns": ["family_name": false]],
            "requestInfo": ["vendor.example": extensions],
        ])
        let request = try decodeRequest(deviceRequest(items: items))
        XCTAssertEqual(request.docRequests[0].itemsRequestBytes, items)
        XCTAssertEqual(request.docRequests[0].nameSpaces, ["ns": ["family_name": false]])
    }

    func testDecodeRejectsMalformedVersions() {
        for version in ["", "1", "1.", ".0", "1.foo", "1.0.extra", "+1.0", "1.-1", "1. 0", "١.٠"] {
            XCTAssertThrowsError(try decodeRequest(deviceRequest(version: version)), ofType: CborDecodingError.self)
        }
    }

    func testDecodeAcceptsUnknownNumericMinorVersionWithoutIntegerSizeLimit() throws {
        let version = "1.123456789012345678901234567890"
        XCTAssertEqual(try decodeRequest(deviceRequest(version: version)).version, version)
    }

    func testDecodeAcceptsALaterMinorVersion() throws {
        // clause 8.1: a known major version with an unknown minor version is not an error
        let request = try decodeRequest(deviceRequest(version: "1.1"))

        XCTAssertEqual(request.version, "1.1")
    }

    func testDecodeIgnoresTheVersion11FieldsDocumentSetsAndReaderAuthAll() throws {
        // a 1.1 reader may add documentSets and readerAuthAll; both are not read yet, on purpose
        let withVersion11Fields = encodeCbor([
            "version": "1.1",
            "docRequests": [["itemsRequest": tag24(encodedCbor: itemsRequest())]],
            "documentSets": [[0]],
            "readerAuthAll": [1, 2],
        ])

        let request = try decodeRequest(withVersion11Fields)

        XCTAssertEqual(request.docRequests.map(\.readerTrust), [.notSigned])
    }

    func testDecodeThrowsCborDecodingErrorForAHigherMajorVersionThanTheEngagement() {
        // the engagement is version 1.0, and the request's major version must not be higher
        XCTAssertThrowsError(try decodeRequest(deviceRequest(version: "2.0")), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenDocRequestsIsEmpty() {
        let noDocuments = encodeCbor(["version": "1.0", "docRequests": []])

        XCTAssertThrowsError(try decodeRequest(noDocuments), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenItemsRequestIsNotTag24() {
        let untagged = deviceRequest(docRequest: ["itemsRequest": .byteString(itemsRequest())])

        XCTAssertThrowsError(try decodeRequest(untagged), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenNameSpacesIsEmpty() {
        let noNameSpaces = itemsRequest(nameSpaces: [:])

        XCTAssertThrowsError(try decodeRequest(deviceRequest(items: noNameSpaces)), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenANamespaceRequestsNoElements() {
        let emptyElements = itemsRequest(nameSpaces: ["org.iso.18013.5.1": [:]])

        XCTAssertThrowsError(try decodeRequest(deviceRequest(items: emptyElements)), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenIntentToRetainIsNotABoolean() {
        let notBoolean = itemsRequest(nameSpaces: ["org.iso.18013.5.1": ["family_name": 1]])

        XCTAssertThrowsError(try decodeRequest(deviceRequest(items: notBoolean)), ofType: CborDecodingError.self)
    }

    func testDecodeThrowsCborDecodingErrorWhenDocTypeIsMissing() {
        let noDocType = encodeCbor(["nameSpaces": ["ns": ["e": true]]])

        XCTAssertThrowsError(try decodeRequest(deviceRequest(items: noDocType)), ofType: CborDecodingError.self)
    }

    func testDecodeIgnoresTopLevelKeysItDoesNotKnow() throws {
        let withExtra = encodeCbor([
            "version": "1.0",
            "docRequests": [["itemsRequest": tag24(encodedCbor: itemsRequest())]],
            "x": 1,
        ])

        let request = try decodeRequest(withExtra)

        XCTAssertEqual(request.docRequests.count, 1)
    }

    func testDecodeThrowsCborDecodingErrorWhenTheRequestIsNotAMap() {
        XCTAssertThrowsError(try decodeRequest("80".hexToBytes()), ofType: CborDecodingError.self)
    }
}
