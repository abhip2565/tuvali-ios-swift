/// The reader broke the ISO 18013-5 transport rules: a missing service characteristic, a message
/// part with an unknown header, or a message too large. The session must end.
struct IsoTransportError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
