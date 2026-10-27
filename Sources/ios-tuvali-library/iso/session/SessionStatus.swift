/// SessionData status codes (Table 20); each one ends the session.
enum SessionStatus {
    static let encryptionError = 10
    static let cborDecodingError = 11
    static let sessionTermination = 20
}
