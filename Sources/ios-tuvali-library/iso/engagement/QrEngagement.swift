private let qrScheme = "mdoc:"

extension DeviceEngagement {
    /// The text of the QR code for this engagement (clause 8.2.2.3): "mdoc:" followed by the
    /// engagement bytes in base64url without padding. Throws QrEngagementError when no retrieval
    /// method is listed (clause 8.2.1.1), since the reader has no other way to learn how to connect.
    func toQrText() throws -> String {
        guard !retrievalMethods.isEmpty else { throw QrEngagementError() }
        return qrScheme + encodeBase64UrlWithoutPadding(bytes)
    }
}
