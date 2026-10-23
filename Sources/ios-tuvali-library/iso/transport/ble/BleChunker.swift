// first byte of every part (clause 8.3.3.1.1.6)
private let partMoreFollows: UInt8 = 0x01
private let partLast: UInt8 = 0x00

/// Large enough for any request or response with certificates; stops a reader exhausting memory.
private let defaultMaxMessageBytes = 1024 * 1024

/// BLE parts (clause 8.3.3.1.1.6): each part is at most MTU − 3 bytes and starts with 0x01 if more
/// parts follow or 0x00 for the last one, so it carries MTU − 4 bytes of the message. iOS reports
/// MTU − 3 directly, as maximumWriteValueLength, so that is what [maximumPartBytes] takes.
final class BleChunker: IsoChunker {
    private let payloadBytes: Int
    private let maxMessageBytes: Int
    private var messageSoFar: [UInt8] = []

    init(maximumPartBytes: Int, maxMessageBytes: Int = defaultMaxMessageBytes) throws {
        payloadBytes = maximumPartBytes - 1
        self.maxMessageBytes = maxMessageBytes
        guard payloadBytes > 0 else {
            throw IsoTransportError("Parts of \(maximumPartBytes) bytes leave no room for message bytes")
        }
    }

    func split(_ message: [UInt8]) -> [[UInt8]] {
        guard !message.isEmpty else { return [[partLast]] }
        return stride(from: 0, to: message.count, by: payloadBytes).map { start in
            let end = min(start + payloadBytes, message.count)
            let header = end < message.count ? partMoreFollows : partLast
            return [header] + message[start..<end]
        }
    }

    func addPiece(_ piece: [UInt8]) throws -> [UInt8]? {
        guard let header = piece.first else { throw IsoTransportError("Empty message part") }
        guard header == partMoreFollows || header == partLast else {
            throw IsoTransportError("Message part header must be 0x01 or 0x00, was 0x\(String(header, radix: 16))")
        }
        guard messageSoFar.count + piece.count - 1 <= maxMessageBytes else {
            throw IsoTransportError("Message is larger than \(maxMessageBytes) bytes")
        }
        messageSoFar += piece.dropFirst()
        guard header == partLast else { return nil }
        defer { messageSoFar = [] }
        return messageSoFar
    }
}
