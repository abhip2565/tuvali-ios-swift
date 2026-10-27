// A small reader for the DER encoding of X.509 certificates (ITU-T X.690): just enough to walk a
// certificate's fields. Only definite lengths and single-byte tags, which DER and X.509 use.

// ASN.1 universal tags, and the context-specific tags used inside a certificate
let derTagBoolean: UInt8 = 0x01
let derTagInteger: UInt8 = 0x02
let derTagBitString: UInt8 = 0x03
let derTagOctetString: UInt8 = 0x04
let derTagObjectIdentifier: UInt8 = 0x06
let derTagUtf8String: UInt8 = 0x0c
let derTagPrintableString: UInt8 = 0x13
let derTagIa5String: UInt8 = 0x16
let derTagUtcTime: UInt8 = 0x17
let derTagGeneralizedTime: UInt8 = 0x18
let derTagSequence: UInt8 = 0x30
let derTagSet: UInt8 = 0x31

private let highTagNumber: UInt8 = 0x1f
private let longFormLength: UInt8 = 0x80
private let largestLengthBytes = 4

/// One DER element: its tag and its content bytes.
struct DerElement {
    let tag: UInt8
    let content: [UInt8]

    /// The elements inside a constructed element (a SEQUENCE, a SET, or an explicit tag).
    func children() throws -> [DerElement] {
        var reader = DerReader(content)
        var elements: [DerElement] = []
        while !reader.isAtEnd { elements.append(try reader.read()) }
        return elements
    }

    func requireTag(_ expected: UInt8, _ what: String) throws -> DerElement {
        guard tag == expected else { throw CertificateParsingError("\(what) has an unexpected DER tag") }
        return self
    }

    /// The dotted form of an OBJECT IDENTIFIER, e.g. "2.5.29.37".
    func objectIdentifier() throws -> String {
        guard tag == derTagObjectIdentifier, content.last.map({ $0 & 0x80 == 0 }) == true else {
            throw CertificateParsingError("Expected a complete object identifier")
        }
        // base-128 subidentifiers; the high bit says another byte follows
        var subidentifiers: [UInt64] = []
        var value: UInt64 = 0
        for byte in content {
            guard value != 0 || byte != 0x80 else { throw CertificateParsingError("Non-minimal object identifier arc") }
            guard value >> 57 == 0 else { throw CertificateParsingError("Object identifier arc is too large") }
            value = (value << 7) | UInt64(byte & 0x7f)
            if byte & 0x80 == 0 {
                subidentifiers.append(value)
                value = 0
            }
        }
        // the first subidentifier holds the first two arcs as 40 × first + second (first arc 0, 1 or 2)
        let combined = subidentifiers[0]
        let firstArcs: [UInt64] = combined < 80 ? [combined / 40, combined % 40] : [2, combined - 80]
        return (firstArcs + subidentifiers.dropFirst()).map(String.init).joined(separator: ".")
    }
}

/// Reads DER elements one after the other from [bytes].
struct DerReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { position == bytes.count }

    mutating func read() throws -> DerElement {
        let tag = try nextByte()
        guard tag & highTagNumber != highTagNumber else {
            throw CertificateParsingError("Multi-byte DER tags are not used in certificates")
        }
        let length = try readLength()
        guard length <= bytes.count - position else { throw CertificateParsingError("DER element longer than the input") }
        let content = Array(bytes[position..<(position + length)])
        position += length
        return DerElement(tag: tag, content: content)
    }

    private mutating func nextByte() throws -> UInt8 {
        guard position < bytes.count else { throw CertificateParsingError("Truncated DER input") }
        defer { position += 1 }
        return bytes[position]
    }

    private mutating func readLength() throws -> Int {
        let first = try nextByte()
        guard first & longFormLength != 0 else { return Int(first) }
        let lengthBytes = Int(first & ~longFormLength)
        // 0x80 alone is an indefinite length, which DER does not allow
        guard (1...largestLengthBytes).contains(lengthBytes) else {
            throw CertificateParsingError("Unsupported DER length")
        }
        var length = 0
        for index in 0..<lengthBytes {
            let byte = try nextByte()
            guard index != 0 || byte != 0 else { throw CertificateParsingError("Non-minimal DER length") }
            length = (length << 8) | Int(byte)
        }
        guard length >= 128 else { throw CertificateParsingError("Non-minimal DER length") }
        return length
    }
}
