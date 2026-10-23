import XCTest
@testable import ios_tuvali_library

/// The BLE Ident characteristic value: ISO 18013-5 clause 8.3.3.1.1.3.
final class BleIdentTests: XCTestCase {

    func testBleIdentReproducesTheIdentOfTheTestVectors() {
        let eDeviceKeyBytes = SessionTestVectors.bytes("deviceKey.eDeviceKeyBytes")

        let ident = bleIdent(eDeviceKeyBytes)

        XCTAssertEqual(ident.hex, SessionTestVectors.string("ident"))
    }

    func testBleIdentOfADeviceEngagementMatchesTheIdentOfTheTestVectors() throws {
        let deviceKey = try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("deviceKey.privateScalar"))
        let uuid = try XCTUnwrap(UUID(uuidString: SessionTestVectors.string("bleClientUuid")))
        let methods: [RetrievalMethod] = [.bleCentralClient(uuid: uuid)]
        let engagement = DeviceEngagement.create(deviceKey: deviceKey, retrievalMethods: methods)

        let ident = bleIdent(engagement.eDeviceKeyBytes)

        XCTAssertEqual(ident.count, 16)
        XCTAssertEqual(ident.hex, SessionTestVectors.string("ident"))
    }
}
