/// A reader message could not be decrypted and authenticated; the session must end (status 10).
struct SessionDecryptionError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
