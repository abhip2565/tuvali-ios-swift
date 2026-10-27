import SwiftCBOR

// Typed readers for decoded CBOR received from a reader. Each names what it expected, and a
// wrong type or a missing key is a CborDecodingError (status 11, "CBOR decoding").

extension CBOR {
    func asMap(_ what: String) throws -> [CBOR: CBOR] {
        guard case let .map(entries) = self else { throw CborDecodingError("\(what) must be a map") }
        return entries
    }

    func asArray(_ what: String) throws -> [CBOR] {
        guard case let .array(elements) = self else { throw CborDecodingError("\(what) must be an array") }
        return elements
    }

    func asText(_ what: String) throws -> String {
        guard case let .utf8String(text) = self else { throw CborDecodingError("\(what) must be a text string") }
        return text
    }

    func asBytes(_ what: String) throws -> [UInt8] {
        guard case let .byteString(bytes) = self else { throw CborDecodingError("\(what) must be a byte string") }
        return bytes
    }

    func asUnsignedInt(_ what: String) throws -> UInt64 {
        guard case let .unsignedInt(value) = self else {
            throw CborDecodingError("\(what) must be an unsigned integer")
        }
        return value
    }

    func asBoolean(_ what: String) throws -> Bool {
        guard case let .boolean(value) = self else { throw CborDecodingError("\(what) must be a boolean") }
        return value
    }
}

extension Dictionary where Key == CBOR, Value == CBOR {
    /// The value under text [key], or nil when the key is absent.
    func optional(_ key: String) -> CBOR? {
        self[.utf8String(key)]
    }

    /// The value under text [key]; a missing key is a CborDecodingError.
    func required(_ key: String, _ what: String) throws -> CBOR {
        guard let value = optional(key) else { throw CborDecodingError("\(what) has no \"\(key)\"") }
        return value
    }
}
