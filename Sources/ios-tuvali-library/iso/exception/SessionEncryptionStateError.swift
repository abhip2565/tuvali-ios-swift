/// The session's encryption can no longer be used: its keys were wiped, or its message counter
/// is used up. A programming error, or a session long past its end; start a new session.
struct SessionEncryptionStateError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
