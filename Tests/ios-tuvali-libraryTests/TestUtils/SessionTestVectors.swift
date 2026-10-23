import Foundation

/// ISO 18013-5 session vectors in Resources/iso/session-vectors.json. They are derived from fixed
/// keys with cbor2 and the Python cryptography package, independent of Tuvali, so the code can be
/// checked byte for byte.
enum SessionTestVectors {
    static let session: [String: Any] = {
        guard let url = Bundle.module.url(forResource: "session-vectors", withExtension: "json", subdirectory: "iso"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            fatalError("iso/session-vectors.json not found in the test bundle")
        }
        return json
    }()

    /// The hex string at [path] (keys separated by dots), as bytes.
    static func bytes(_ path: String) -> [UInt8] {
        string(path).hexToBytes()
    }

    /// The string at [path] (keys separated by dots).
    static func string(_ path: String) -> String {
        var value: Any = session
        for key in path.split(separator: ".") {
            guard let object = value as? [String: Any], let next = object[String(key)] else {
                fatalError("No session vector at \(path)")
            }
            value = next
        }
        guard let text = value as? String else { fatalError("Session vector \(path) is not a string") }
        return text
    }
}
