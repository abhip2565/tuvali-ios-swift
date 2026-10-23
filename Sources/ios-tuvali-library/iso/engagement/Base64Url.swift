import Foundation

/// RFC 4648 base64url without padding: standard base64 with "-" for "+", "_" for "/", and no "=".
func encodeBase64UrlWithoutPadding(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
