import XCTest
@testable import ios_tuvali_library

/// ECKA-DH between EDeviceKey.Priv and EReaderKey.Pub: ISO 18013-5 clause 9.1.1.5.
final class KeyAgreementTests: XCTestCase {
    private var deviceKey: EphemeralDeviceKey!

    override func setUpWithError() throws {
        deviceKey = try EphemeralDeviceKey.fromPrivateScalar(SessionTestVectors.bytes("deviceKey.privateScalar"))
    }

    func testSharedSecretReproducesTheZabOfTheTestVectors() throws {
        let readerKey = try ReaderPublicKey.fromCoseKey(SessionTestVectors.bytes("readerKey.coseKey"))

        let secret = try sharedSecret(deviceKey, readerKey)

        XCTAssertEqual(secret.hex, SessionTestVectors.string("sharedSecret"))
    }

    func testSharedSecretStays32BytesWhenItStartsWithAZeroByte() throws {
        // a fixed reader key whose shared secret with the device key starts with 0x00
        let readerKey = try ReaderPublicKey.fromCoseKey(SessionTestVectors.bytes("shortSharedSecret.readerCoseKey"))

        let secret = try sharedSecret(deviceKey, readerKey)

        XCTAssertEqual(secret.count, 32)
        XCTAssertEqual(secret.hex, SessionTestVectors.string("shortSharedSecret.sharedSecret"))
    }

    func testSharedSecretThrowsDeviceKeyWipedErrorWhenTheDeviceKeyWasWiped() throws {
        let readerKey = try ReaderPublicKey.fromCoseKey(SessionTestVectors.bytes("readerKey.coseKey"))
        let wipedKey = EphemeralDeviceKey.generate()
        wipedKey.wipe()

        XCTAssertThrowsError(try sharedSecret(wipedKey, readerKey), ofType: DeviceKeyWipedError.self)
    }
}
