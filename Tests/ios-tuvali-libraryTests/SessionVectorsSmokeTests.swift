import SwiftCBOR
import XCTest

/// The session vectors load from the test bundle and SwiftCBOR decodes them.
final class SessionVectorsSmokeTests: XCTestCase {

    func testSharedDeviceEngagementVectorDecodesAsAMapWithVersion10() throws {
        let engagement = SessionTestVectors.bytes("deviceEngagement")

        let decoded = try CBOR.decode(engagement)

        guard case let .map(fields)? = decoded else { return XCTFail("DeviceEngagement is not a CBOR map") }
        XCTAssertEqual(fields[.unsignedInt(0)], .utf8String("1.0"))
    }
}
