/// What the reader sent: a whole message, or a signal that it ended the session.
enum ReaderEvent: Equatable {
    case message([UInt8])
    case ended
}

/// Carries whole ISO 18013-5 session messages (SessionEstablishment, SessionData) between the
/// mdoc and the reader. Each data retrieval method (BLE today; NFC, L2CAP or Wi-Fi Aware later)
/// is one implementation; the session layer above only ever sees whole messages.
protocol MdocTransport: AnyObject {
    /// Finds and connects to the reader, ready to exchange messages.
    func open() async throws

    /// Sends one whole message to the reader.
    func send(_ message: [UInt8]) async throws

    /// Waits for the reader's next whole message, or for it to end the session.
    func receive() async throws -> ReaderEvent

    /// Ends the connection; safe to call more than once and after a lost link.
    func close() async
}
