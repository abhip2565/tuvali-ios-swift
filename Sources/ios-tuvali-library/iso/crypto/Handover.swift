import SwiftCBOR

/// How device engagement happened, which decides the Handover element of the session transcript
/// (clause 9.1.5.1). Only QR exists today; NFC engagement would add an NFCHandover case carrying
/// the Handover Select (and, if negotiated, Request) message bytes.
enum Handover: Equatable {
    /// QRHandover = null.
    case qr

    func toCbor() -> CBOR {
        switch self {
        case .qr: return .null
        }
    }
}
