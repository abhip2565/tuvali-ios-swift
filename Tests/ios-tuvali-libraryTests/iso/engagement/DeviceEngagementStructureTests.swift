import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// The structure checks of the GOV.UK ISO 18013-6 mdoc device engagement cases (mDL_MS_DE_*),
/// applied to what DeviceEngagement.create produces, plus the BleOptions rules of
/// ISO 18013-5 clause 8.3.3.1.1.2 for an mdoc that only supports central client mode.
final class DeviceEngagementStructureTests: XCTestCase {
    private var engagement: DeviceEngagement!
    private var decoded: CBOR!

    override func setUpWithError() throws {
        engagement = DeviceEngagement.create()
        decoded = try decodeCbor(engagement.bytes)
    }

    func testEngagementBytesAreCanonicalCborWithSortedMapKeysDE01() {
        // encodeCbor writes canonical CBOR, so re-encoding what was decoded gives it back
        let canonical = encodeCbor(decoded)

        XCTAssertEqual(engagement.bytes.hex, canonical.hex)
    }

    func testEngagementHoldsOnlyVersionSecurityAndDeviceRetrievalMethodsDE02DE03() {
        XCTAssertEqual(decoded.integerKeys, [0, 1, 2])
    }

    func testEngagementVersionIs10DE04() {
        XCTAssertEqual(decoded.value(at: 0).text, "1.0")
    }

    func testSecurityIsCipherSuite1FollowedByTag24EDeviceKeyBytesDE05DE06DE07() {
        let security = decoded.value(at: 1).items

        XCTAssertEqual(security.count, 2)
        XCTAssertEqual(security.first?.integer, 1)
        guard case let .tagged(tag, .byteString)? = security.last else { return XCTFail("Not a tagged byte string") }
        XCTAssertEqual(tag.rawValue, 24)
    }

    func testEDeviceKeyInsideTheEngagementIsCanonicalCborDE08() throws {
        let eDeviceKey = try untag24(decoded.value(at: 1).items[1])

        let canonical = encodeCbor(try decodeCbor(eDeviceKey))

        XCTAssertEqual(eDeviceKey.hex, canonical.hex)
    }

    func testDeviceRetrievalMethodsHoldExactlyOneMethodBleVersion1WithOptionsDE11DE12() {
        let methods = decoded.value(at: 2).items

        XCTAssertEqual(methods.count, 1)
        let bleMethod = methods[0].items
        XCTAssertEqual(bleMethod.count, 3)
        // Table 7: type 2 is BLE, version 1
        XCTAssertEqual(bleMethod[0].integer, 2)
        XCTAssertEqual(bleMethod[1].integer, 1)
    }

    func testBleOptionsOfferCentralClientModeOnlyWithA16ByteClientUuidAndNoServerFields() {
        let bleOptions = decoded.value(at: 2).items[0].items[2]

        // 0: peripheral server mode, 1: central client mode, 11: client UUID; 10 and 20 are server-only
        XCTAssertEqual(bleOptions.integerKeys, [0, 1, 11])
        XCTAssertEqual(bleOptions.value(at: 0), .boolean(false))
        XCTAssertEqual(bleOptions.value(at: 1), .boolean(true))
        XCTAssertEqual(bleOptions.value(at: 11).bytes?.count, 16)
    }
}
