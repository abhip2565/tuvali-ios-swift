import Foundation
import SwiftCBOR

// DeviceRetrievalMethod for BLE (Table 7) and its BleOptions keys (clause 8.2.2.3)
private let retrievalTypeBle = 2
private let retrievalVersionBle = 1
private let bleOptionPeripheralServerMode = 0
private let bleOptionCentralClientMode = 1
private let bleOptionCentralClientUuid = 11

/// One way the mdoc offers to transfer data, listed in the engagement's DeviceRetrievalMethods
/// (clause 8.2.1.1). Only BLE central client mode exists today; BLE peripheral server mode,
/// Wi-Fi Aware or NFC would each be a further case with its own options.
enum RetrievalMethod: Equatable {
    /// BLE with the mdoc as central client only: the reader advertises [uuid] and the mdoc connects.
    case bleCentralClient(uuid: UUID)

    /// The DeviceRetrievalMethod array: [type, version, options].
    func toCbor() -> CBOR {
        switch self {
        case let .bleCentralClient(uuid):
            // the server-mode UUID (10) and device address (20) are left out, as clause 8.3.3.1.1.2
            // requires when server mode is not supported
            let options: CBOR = .map([
                CBOR(integerLiteral: bleOptionPeripheralServerMode): .boolean(false),
                CBOR(integerLiteral: bleOptionCentralClientMode): .boolean(true),
                CBOR(integerLiteral: bleOptionCentralClientUuid): .byteString(uuid.rfc4122Bytes),
            ])
            return [CBOR(integerLiteral: retrievalTypeBle), CBOR(integerLiteral: retrievalVersionBle), options]
        }
    }
}

extension UUID {
    /// 16 bytes in RFC 4122 byte order (most significant first), as clause 8.3.3.1.1.2 requires.
    var rfc4122Bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { [UInt8]($0) }
    }
}
