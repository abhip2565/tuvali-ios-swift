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
        var value: Any = session
        for key in path.split(separator: ".") {
            guard let object = value as? [String: Any], let next = object[String(key)] else {
                fatalError("No session vector at \(path)")
            }
            value = next
        }
        guard let hex = value as? String else { fatalError("Session vector \(path) is not a hex string") }
        return hex.hexToBytes()
    }
}

extension String {
    func hexToBytes() -> [UInt8] {
        precondition(count.isMultiple(of: 2), "Hex string has an odd length")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count / 2)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            guard let byte = UInt8(self[index..<next], radix: 16) else { fatalError("Not hex: \(self[index..<next])") }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
