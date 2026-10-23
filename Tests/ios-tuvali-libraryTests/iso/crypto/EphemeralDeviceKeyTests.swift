import CryptoKit
import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// The mdoc's ephemeral P-256 key for one session (EDeviceKey).
final class EphemeralDeviceKeyTests: XCTestCase {

    private func vectorCoseKey(_ name: String) throws -> CBOR {
        try decodeCbor(SessionTestVectors.bytes("\(name).coseKey"))
    }

    func testFromPrivateScalarDerivesThePublicXAndYOfTheTestVectorKey() throws {
        let scalar = SessionTestVectors.bytes("deviceKey.privateScalar")

        let key = try EphemeralDeviceKey.fromPrivateScalar(scalar)

        let coseKey = try vectorCoseKey("deviceKey")
        XCTAssertEqual(key.x, coseKey.value(at: -2).bytes)
        XCTAssertEqual(key.y, coseKey.value(at: -3).bytes)
    }

    func testYStays32BytesWhenTheCoordinateStartsWithAZeroByte() throws {
        // a fixed key whose y coordinate is below 2^248, so its first byte is 0x00
        let scalar = SessionTestVectors.bytes("shortYCoordinateKey.privateScalar")

        let key = try EphemeralDeviceKey.fromPrivateScalar(scalar)

        XCTAssertEqual(key.y.count, 32)
        XCTAssertEqual(key.y, try vectorCoseKey("shortYCoordinateKey").value(at: -3).bytes)
    }

    func testXStays32BytesWhenTheCoordinateStartsWithAZeroByte() throws {
        // a fixed key whose x coordinate is below 2^248, so its first byte is 0x00
        let scalar = SessionTestVectors.bytes("shortXCoordinateKey.privateScalar")

        let key = try EphemeralDeviceKey.fromPrivateScalar(scalar)

        XCTAssertEqual(key.x.count, 32)
        XCTAssertEqual(key.x, try vectorCoseKey("shortXCoordinateKey").value(at: -2).bytes)
    }

    func testGenerateCreatesAPublicKeyOnTheP256Curve() throws {
        let key = EphemeralDeviceKey.generate()

        // CryptoKit only accepts the uncompressed point 04 ‖ x ‖ y if it lies on P-256
        let point = [0x04] + key.x + key.y
        XCTAssertNoThrow(try P256.KeyAgreement.PublicKey(x963Representation: point))
    }

    func testGenerateCreatesADifferentKeyEveryTime() {
        let first = EphemeralDeviceKey.generate()

        let second = EphemeralDeviceKey.generate()

        XCTAssertNotEqual(first.x, second.x)
    }

    func testFromPrivateScalarThrowsWhenTheScalarIsZero() {
        let zero = [UInt8](repeating: 0, count: 32)

        XCTAssertThrowsError(try EphemeralDeviceKey.fromPrivateScalar(zero))
    }

    func testFromPrivateScalarThrowsWhenTheScalarIsNotBelowTheCurveOrder() {
        // the P-256 group order n itself
        let curveOrder = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551".hexToBytes()

        XCTAssertThrowsError(try EphemeralDeviceKey.fromPrivateScalar(curveOrder))
    }

    func testRequirePrivateKeyThrowsDeviceKeyWipedErrorAfterWipe() {
        let key = EphemeralDeviceKey.generate()

        key.wipe()

        XCTAssertThrowsError(try key.requirePrivateKey(), ofType: DeviceKeyWipedError.self)
    }

    func testWipeCanBeCalledAgainWithoutFailing() {
        let key = EphemeralDeviceKey.generate()
        key.wipe()

        key.wipe()

        XCTAssertThrowsError(try key.requirePrivateKey(), ofType: DeviceKeyWipedError.self)
    }
}
