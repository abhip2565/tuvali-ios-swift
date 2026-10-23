import Foundation
import SwiftCBOR

private let engagementVersion = "1.0"
private let cipherSuite1 = 1

// DeviceEngagement map keys (clause 8.2.1.1)
private let keyVersion = 0
private let keySecurity = 1
private let keyDeviceRetrievalMethods = 2

/// The device engagement structure that starts an ISO 18013-5 session (clause 8.2.1.1), whatever
/// carries it to the reader: a QR code today (see toQrText), NFC handover later.
///
/// It lists the [retrievalMethods] the wallet offers; today that is BLE with the mdoc as central
/// client only, where the reader advertises the method's UUID and the wallet connects to it. With
/// no methods, DeviceRetrievalMethods is left out, as NFC engagement requires. [bytes] are kept
/// exactly as encoded, because the session transcript (clause 9.1.5.1) must use the same bytes the
/// reader received.
final class DeviceEngagement {
    let deviceKey: EphemeralDeviceKey
    let retrievalMethods: [RetrievalMethod]

    /// The DeviceEngagement CBOR exactly as sent to the reader.
    let bytes: [UInt8]

    /// EDeviceKeyBytes: #6.24(bstr .cbor EDeviceKey), as used for the BLE Ident (clause 8.3.3.1.1.3).
    let eDeviceKeyBytes: [UInt8]

    private init(deviceKey: EphemeralDeviceKey, retrievalMethods: [RetrievalMethod]) {
        self.deviceKey = deviceKey
        self.retrievalMethods = retrievalMethods
        // encoded once and wrapped as-is, so the engagement and eDeviceKeyBytes hold the very same key bytes
        let encodedCoseKey = encodeCbor(deviceKey.toCoseKey())
        eDeviceKeyBytes = encodeCbor(tag24(encodedCbor: encodedCoseKey))
        var entries: [CBOR: CBOR] = [
            CBOR(integerLiteral: keyVersion): .utf8String(engagementVersion),
            CBOR(integerLiteral: keySecurity): [CBOR(integerLiteral: cipherSuite1), tag24(encodedCbor: encodedCoseKey)],
        ]
        if !retrievalMethods.isEmpty {
            entries[CBOR(integerLiteral: keyDeviceRetrievalMethods)] = .array(retrievalMethods.map { $0.toCbor() })
        }
        bytes = encodeCbor(.map(entries))
    }

    /// A new engagement with a fresh ephemeral key, offering BLE central client mode with a fresh
    /// random (version 4) UUID.
    static func create() -> DeviceEngagement {
        DeviceEngagement(deviceKey: .generate(), retrievalMethods: [.bleCentralClient(uuid: UUID())])
    }

    /// An engagement for a given key and retrieval methods; used with fixed test vectors.
    static func create(deviceKey: EphemeralDeviceKey, retrievalMethods: [RetrievalMethod]) -> DeviceEngagement {
        DeviceEngagement(deviceKey: deviceKey, retrievalMethods: retrievalMethods)
    }
}
