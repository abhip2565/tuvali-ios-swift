/// CBOR received from a reader is malformed, or not the shape that was expected
/// (ISO 18013-5 session status 11, "CBOR decoding error").
struct CborDecodingError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
