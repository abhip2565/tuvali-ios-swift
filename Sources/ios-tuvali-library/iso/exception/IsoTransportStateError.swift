/// The transport was used out of order: sending or receiving before it is open, opening it twice,
/// or sending after the reader ended the session. A programming error in the session above.
struct IsoTransportStateError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
