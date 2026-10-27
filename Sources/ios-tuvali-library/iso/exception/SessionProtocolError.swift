/// The reader sent a session message out of order, e.g. a second SessionEstablishment; the session must end.
struct SessionProtocolError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
