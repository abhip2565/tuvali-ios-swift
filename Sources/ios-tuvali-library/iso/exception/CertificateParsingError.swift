/// A certificate's DER encoding could not be read, or lacks a field X.509 requires.
struct CertificateParsingError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
