import SwiftCBOR

private let keyReaderKey = "eReaderKey"
private let keyData = "data"
private let keyStatus = "status"

/// The two message kinds of an ISO 18013-5 session (clause 9.1.1.4).
enum SessionMessage {
    case establishment(SessionEstablishment)
    case data(SessionData)

    /// Decodes a message from the reader. Only SessionEstablishment carries "eReaderKey", so that
    /// key decides the kind; unknown keys are ignored. Malformed input is a CborDecodingError.
    static func decode(_ message: [UInt8]) throws -> SessionMessage {
        let map = try decodeCbor(message).asMap("Session message")
        guard let readerKey = map.optional(keyReaderKey) else {
            let data = try map.optional(keyData)?.asBytes(keyData)
            let status = try map.optional(keyStatus).map(statusCode)
            if let status = status, data != nil, SessionData.statusesWithoutData.contains(status) {
                throw CborDecodingError("SessionData with status \(status) must not carry data")
            }
            return .data(SessionData(data: data, status: status))
        }
        return .establishment(
            SessionEstablishment(
                readerCoseKey: try untag24(readerKey),
                data: try map.required(keyData, "SessionEstablishment").asBytes(keyData)
            )
        )
    }

    private static func statusCode(_ item: CBOR) throws -> Int {
        guard let status = Int(exactly: try item.asUnsignedInt(keyStatus)) else {
            throw CborDecodingError("status is out of range")
        }
        return status
    }
}

/// SessionEstablishment: the reader's first message, with its ephemeral key and the encrypted
/// request. [readerCoseKey] are the COSE_Key bytes from inside EReaderKeyBytes, exactly as received.
struct SessionEstablishment: Equatable {
    let readerCoseKey: [UInt8]
    let data: [UInt8]
}

/// SessionData: every later message, in both directions: encrypted [data], a [status], or both.
/// With status 10 or 11 there is no data (Table 20).
struct SessionData: Equatable {
    static let statusesWithoutData: Set<Int> = [SessionStatus.encryptionError, SessionStatus.cborDecodingError]

    let data: [UInt8]?
    let status: Int?

    init(data: [UInt8]? = nil, status: Int? = nil) {
        precondition(
            !(data != nil && status.map(SessionData.statusesWithoutData.contains) == true),
            "SessionData with status 10 or 11 must not carry data"
        )
        self.data = data
        self.status = status
    }

    func encode() -> [UInt8] {
        var entries: [CBOR: CBOR] = [:]
        if let data = data { entries[.utf8String(keyData)] = .byteString(data) }
        if let status = status { entries[.utf8String(keyStatus)] = CBOR(integerLiteral: status) }
        return encodeCbor(.map(entries))
    }
}
