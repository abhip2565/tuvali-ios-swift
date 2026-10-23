import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

final class DeviceEngagementTests: XCTestCase {
    private var vectorKey: EphemeralDeviceKey!
    private var vectorUuid: UUID!

    override func setUpWithError() throws {
        vectorKey = try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("deviceKey.privateScalar"))
        vectorUuid = try XCTUnwrap(UUID(uuidString: SessionTestVectors.string("bleClientUuid")))
    }

    private func vectorEngagement() -> DeviceEngagement {
        DeviceEngagement.create(deviceKey: vectorKey, retrievalMethods: [.bleCentralClient(uuid: vectorUuid)])
    }

    private func bleCentralClientUuid(of engagement: DeviceEngagement) -> UUID? {
        guard case let .bleCentralClient(uuid)? = engagement.retrievalMethods.first else { return nil }
        return uuid
    }

    func testCreateReproducesTheDeviceEngagementBytesOfTheTestVectors() {
        let engagement = vectorEngagement()

        XCTAssertEqual(engagement.bytes.hex, SessionTestVectors.string("deviceEngagement"))
    }

    func testEDeviceKeyBytesReproducesTheTag24WrappedCoseKeyOfTheTestVectors() {
        let engagement = vectorEngagement()

        XCTAssertEqual(engagement.eDeviceKeyBytes.hex, SessionTestVectors.string("deviceKey.eDeviceKeyBytes"))
    }

    func testCreateEncodesTheBleClientUuidAs16BytesInRfc4122ByteOrder() throws {
        let engagement = vectorEngagement()

        let bleOptions = try decodeCbor(engagement.bytes).value(at: 2).items[0].items[2]

        // the UUID's hex digits in the order they are written, without dashes
        let expected = vectorUuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(bleOptions.value(at: 11).bytes?.hex, expected)
    }

    func testCreateGeneratesARandomVersion4UuidOfTheRfc4122Variant() throws {
        let engagement = DeviceEngagement.create()

        let uuid = try XCTUnwrap(bleCentralClientUuid(of: engagement))

        let bytes = withUnsafeBytes(of: uuid.uuid) { [UInt8]($0) }
        XCTAssertEqual(bytes[6] >> 4, 4) // version 4
        XCTAssertEqual(bytes[8] >> 6, 0b10) // variant '10x'
    }

    func testCreateGeneratesAFreshKeyAndUuidForEverySession() {
        let first = DeviceEngagement.create()

        let second = DeviceEngagement.create()

        XCTAssertNotEqual(bleCentralClientUuid(of: first), bleCentralClientUuid(of: second))
        XCTAssertNotEqual(first.deviceKey.x, second.deviceKey.x)
    }

    func testBytesLeaveOutDeviceRetrievalMethodsWhenNoRetrievalMethodIsOffered() throws {
        // NFC engagement sends no retrieval methods in the engagement (clause 8.2.1.1)
        let noMethods: [RetrievalMethod] = []

        let engagement = DeviceEngagement.create(deviceKey: vectorKey, retrievalMethods: noMethods)

        XCTAssertEqual(try decodeCbor(engagement.bytes).integerKeys, [0, 1])
    }
}
