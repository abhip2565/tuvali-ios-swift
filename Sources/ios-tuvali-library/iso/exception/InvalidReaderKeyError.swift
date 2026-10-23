/// The reader's ephemeral key (EReaderKey) is not a usable P-256 public key; the session must end.
struct InvalidReaderKeyError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
