/// Splits outgoing messages and reassembles incoming pieces. One instance per connection;
/// addPiece retains the current partial message.
protocol IsoChunker: AnyObject {
    func split(_ message: [UInt8]) -> [[UInt8]]

    /// Adds one received piece; returns the whole message once it is complete, otherwise nil.
    func addPiece(_ piece: [UInt8]) throws -> [UInt8]?
}
