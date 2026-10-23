/// The engagement cannot be shown as a QR code: it lists no retrieval method, and a reader that
/// scans the code has no other way to learn how to connect (ISO 18013-5 clause 8.2.1.1).
struct QrEngagementError: Error, CustomStringConvertible {
    var description: String { "A QR engagement must list at least one retrieval method" }
}
