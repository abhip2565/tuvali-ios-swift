import SwiftCBOR
import XCTest

/// Small readers for decoded CBOR, so structure tests read like the CDDL they check.
/// A wrong shape fails the test with a message rather than crashing it.
extension CBOR {
    func value(at key: Int, file: StaticString = #filePath, line: UInt = #line) -> CBOR {
        guard case let .map(entries) = self, let value = entries[CBOR(integerLiteral: key)] else {
            XCTFail("No map entry for key \(key) in \(self)", file: file, line: line)
            return .null
        }
        return value
    }

    /// The map's integer keys, sorted (a decoded map has no order of its own).
    var integerKeys: [Int] {
        guard case let .map(entries) = self else { return [] }
        return entries.keys.compactMap { key in
            switch key {
            case let .unsignedInt(value): return Int(value)
            case let .negativeInt(value): return -1 - Int(value)
            default: return nil
            }
        }.sorted()
    }

    var items: [CBOR] {
        guard case let .array(elements) = self else { return [] }
        return elements
    }

    var integer: Int? {
        switch self {
        case let .unsignedInt(value): return Int(value)
        case let .negativeInt(value): return -1 - Int(value)
        default: return nil
        }
    }

    var text: String? {
        guard case let .utf8String(value) = self else { return nil }
        return value
    }

    var bytes: [UInt8]? {
        guard case let .byteString(value) = self else { return nil }
        return value
    }
}
