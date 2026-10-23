import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// EDeviceKey as COSE_Key: ISO 18013-5 clauses 9.1.1.4 and 9.1.5.2.
final class CoseKeyTests: XCTestCase {

    private func key(_ name: String) throws -> EphemeralDeviceKey {
        try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("\(name).privateScalar"))
    }

    func testToCoseKeyReproducesTheDeviceCoseKeyBytesOfTheTestVectors() throws {
        let deviceKey = try key("deviceKey")

        let coseKey = deviceKey.toCoseKey()

        XCTAssertEqual(encodeCbor(coseKey).hex, SessionTestVectors.string("deviceKey.coseKey"))
    }

    func testToCoseKeyReproducesTheTestVectorWhenXNeedsALeadingZeroByte() throws {
        let deviceKey = try key("shortXCoordinateKey")

        let coseKey = deviceKey.toCoseKey()

        XCTAssertEqual(encodeCbor(coseKey).hex, SessionTestVectors.string("shortXCoordinateKey.coseKey"))
    }

    func testToCoseKeyReproducesTheTestVectorWhenYNeedsALeadingZeroByte() throws {
        let deviceKey = try key("shortYCoordinateKey")

        let coseKey = deviceKey.toCoseKey()

        XCTAssertEqual(encodeCbor(coseKey).hex, SessionTestVectors.string("shortYCoordinateKey.coseKey"))
    }

    func testToCoseKeyContainsOnlyKtyCrvXAndY() {
        let deviceKey = EphemeralDeviceKey.generate()

        let coseKey = deviceKey.toCoseKey()

        // COSE labels: kty 1, crv -1, x -2, y -3 (their order is checked byte for byte above)
        XCTAssertEqual(coseKey.integerKeys, [-3, -2, -1, 1])
    }

    func testToCoseKeyDeclaresKeyTypeEc2OnCurveP256() {
        let deviceKey = EphemeralDeviceKey.generate()

        let coseKey = deviceKey.toCoseKey()

        // IANA COSE registry: kty EC2 = 2, crv P-256 = 1
        XCTAssertEqual(coseKey.value(at: 1).integer, 2)
        XCTAssertEqual(coseKey.value(at: -1).integer, 1)
    }
}
