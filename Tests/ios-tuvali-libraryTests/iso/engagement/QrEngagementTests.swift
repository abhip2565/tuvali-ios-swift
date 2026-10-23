import XCTest
@testable import ios_tuvali_library

/// QR code content for device engagement (ISO 18013-5 clause 8.2.2.3), and the base64url it uses.
final class QrEngagementTests: XCTestCase {
    private var vectorKey: EphemeralDeviceKey!
    private var vectorUuid: UUID!

    override func setUpWithError() throws {
        vectorKey = try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("deviceKey.privateScalar"))
        vectorUuid = try XCTUnwrap(UUID(uuidString: SessionTestVectors.string("bleClientUuid")))
    }

    func testToQrTextReproducesTheQrTextOfTheTestVectors() throws {
        let methods: [RetrievalMethod] = [.bleCentralClient(uuid: vectorUuid)]
        let engagement = DeviceEngagement.create(deviceKey: vectorKey, retrievalMethods: methods)

        let qrText = try engagement.toQrText()

        XCTAssertEqual(qrText, SessionTestVectors.string("qrText"))
    }

    func testToQrTextIsTheMdocSchemeFollowedByTheEngagementBytesInBase64UrlWithoutPadding() throws {
        let engagement = DeviceEngagement.create()

        let qrText = try engagement.toQrText()

        XCTAssertTrue(qrText.hasPrefix("mdoc:"))
        let encodedPart = String(qrText.dropFirst("mdoc:".count))
        XCTAssertFalse(encodedPart.contains("=") || encodedPart.contains("+") || encodedPart.contains("/"))
        let standardBase64 = encodedPart
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standardBase64 + String(repeating: "=", count: (4 - standardBase64.count % 4) % 4)
        XCTAssertEqual(Data(base64Encoded: padded).map { [UInt8]($0) }, engagement.bytes)
    }

    func testToQrTextThrowsQrEngagementErrorWhenNoRetrievalMethodIsOffered() {
        // a QR engagement must list at least one device retrieval method (clause 8.2.1.1)
        let engagement = DeviceEngagement.create(deviceKey: vectorKey, retrievalMethods: [])

        XCTAssertThrowsError(try engagement.toQrText(), ofType: QrEngagementError.self)
    }

    // MARK: base64url

    func testEncodeBase64UrlWithoutPaddingMatchesTheRfc4648TestVectorsWithPaddingRemoved() {
        // RFC 4648 section 10: "", "f", "fo", "foo", "foob", "fooba", "foobar"
        let inputs = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]

        let encoded = inputs.map { encodeBase64UrlWithoutPadding(Array($0.utf8)) }

        XCTAssertEqual(encoded, ["", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy"])
    }

    func testEncodeBase64UrlWithoutPaddingUsesMinusAndUnderscoreInsteadOfPlusAndSlash() {
        // 0xfb 0xff encodes to "+/8=" in standard base64
        let bytes = "fbff".hexToBytes()

        let encoded = encodeBase64UrlWithoutPadding(bytes)

        XCTAssertEqual(encoded, "-_8")
    }
}
