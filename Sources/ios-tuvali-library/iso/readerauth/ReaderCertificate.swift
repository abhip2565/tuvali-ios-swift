import Foundation
import Security

// Object identifiers (RFC 5280, RFC 5480)
private let oidCommonName = "2.5.4.3"
private let oidKeyUsage = "2.5.29.15"
private let oidExtendedKeyUsage = "2.5.29.37"
private let oidEcPublicKey = "1.2.840.10045.2.1"

// context-specific tags inside TBSCertificate: [0] version, [3] extensions
private let tagVersion: UInt8 = 0xa0
private let tagExtensions: UInt8 = 0xa3

// KeyUsage is a BIT STRING whose first content byte holds bits 0 to 7; digitalSignature is bit 0
private let digitalSignatureBit: UInt8 = 0x80

/// An elliptic curve a reader key can be on, by its named-curve object identifier (RFC 5480).
enum ReaderKeyCurve: String {
    case p256 = "1.2.840.10045.3.1.7"
    case p384 = "1.3.132.0.34"
    case p521 = "1.3.132.0.35"

    var name: String {
        switch self {
        case .p256: return "P-256"
        case .p384: return "P-384"
        case .p521: return "P-521"
        }
    }
}

/// The public key a certificate holds.
enum CertificatePublicKey: Equatable {
    /// An EC key on a NIST curve this device can verify with, as the uncompressed point 04 ‖ x ‖ y.
    case ec(curve: ReaderKeyCurve, point: [UInt8])
    /// An EC key on another curve, e.g. brainpoolP256r1, by the curve's object identifier.
    case ecOnOtherCurve(curveOid: String)
    /// Not an EC key at all, e.g. RSA, by its algorithm's object identifier.
    case other(algorithmOid: String)
}

/// The fields of a reader certificate that reader authentication checks itself (validity, key
/// usage, extended key usage, public key, common name), read from its DER encoding. The chain is
/// checked by the Security framework on [secCertificate].
struct ReaderCertificate {
    let secCertificate: SecCertificate
    let notBefore: Date
    let notAfter: Date
    let commonName: String?
    /// Whether KeyUsage allows digital signatures, or nil when the certificate has no KeyUsage.
    let allowsDigitalSignature: Bool?
    /// The ExtendedKeyUsage purposes, or nil when the certificate has no ExtendedKeyUsage.
    let extendedKeyUsages: [String]?
    let publicKey: CertificatePublicKey

    init(der: [UInt8]) throws {
        guard let secCertificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw CertificateParsingError("Not a DER X.509 certificate")
        }
        self.secCertificate = secCertificate

        let certificate = try DerReader.single(der).requireTag(derTagSequence, "Certificate")
        guard let tbs = try certificate.children().first else {
            throw CertificateParsingError("Certificate has no TBSCertificate")
        }
        var fields = try tbs.requireTag(derTagSequence, "TBSCertificate").children()[...]
        if fields.first?.tag == tagVersion { fields = fields.dropFirst() }
        // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, then optional fields
        guard fields.count >= 6 else { throw CertificateParsingError("TBSCertificate is missing fields") }
        let validity = fields[fields.startIndex + 3]
        let subject = fields[fields.startIndex + 4]
        let publicKeyInfo = fields[fields.startIndex + 5]

        let times = try validity.requireTag(derTagSequence, "Validity").children()
        guard times.count == 2 else { throw CertificateParsingError("Validity must hold two times") }
        notBefore = try Self.time(times[0])
        notAfter = try Self.time(times[1])
        commonName = try Self.commonName(subject)
        publicKey = try Self.publicKey(publicKeyInfo)

        let extensionFields = fields.dropFirst(6).filter { $0.tag == tagExtensions }
        guard extensionFields.count <= 1 else { throw CertificateParsingError("Repeated extensions field") }
        let extensions = try extensionFields.first.map(Self.extensions) ?? [:]
        allowsDigitalSignature = try extensions[oidKeyUsage].map(Self.allowsDigitalSignature)
        extendedKeyUsages = try extensions[oidExtendedKeyUsage].map(Self.extendedKeyUsages)
    }

    /// Each extension's extnValue contents, by its object identifier.
    private static func extensions(_ element: DerElement) throws -> [String: [UInt8]] {
        let wrapper = try element.children()
        guard wrapper.count == 1, let list = wrapper.first else { throw CertificateParsingError("Invalid extensions wrapper") }
        var values: [String: [UInt8]] = [:]
        for item in try list.requireTag(derTagSequence, "Extensions").children() {
            let parts = try item.requireTag(derTagSequence, "Extension").children()
            // extnID, an optional critical flag, then extnValue
            guard let id = parts.first, let value = parts.last, (2...3).contains(parts.count) else {
                throw CertificateParsingError("Extension is missing fields")
            }
            if parts.count == 3 {
                let critical = try parts[1].requireTag(derTagBoolean, "critical").content
                guard critical == [0xff] else { throw CertificateParsingError("Invalid DER critical flag") }
            }
            let oid = try id.objectIdentifier()
            guard values[oid] == nil else { throw CertificateParsingError("Duplicate certificate extension") }
            values[oid] = try value.requireTag(derTagOctetString, "extnValue").content
        }
        return values
    }

    private static func allowsDigitalSignature(_ value: [UInt8]) throws -> Bool {
        let bits = try DerReader.single(value).requireTag(derTagBitString, "KeyUsage").content
        // the first byte counts the unused bits at the end; the bits themselves follow
        guard bits.count >= 2, bits[0] < 8,
              (bits.last ?? 0) & UInt8((1 << Int(bits[0])) - 1) == 0 else {
            throw CertificateParsingError("Invalid KeyUsage bit string")
        }
        return bits[1] & digitalSignatureBit != 0
    }

    private static func extendedKeyUsages(_ value: [UInt8]) throws -> [String] {
        let purposes = try DerReader.single(value).requireTag(derTagSequence, "ExtendedKeyUsage").children()
        return try purposes.map { purpose in try purpose.objectIdentifier() }
    }

    private static func publicKey(_ element: DerElement) throws -> CertificatePublicKey {
        let parts = try element.requireTag(derTagSequence, "SubjectPublicKeyInfo").children()
        guard parts.count == 2, let algorithm = try parts[0].requireTag(derTagSequence, "algorithm").children().first else {
            throw CertificateParsingError("SubjectPublicKeyInfo is missing fields")
        }
        let algorithmOid = try algorithm.objectIdentifier()
        guard algorithmOid == oidEcPublicKey else { return .other(algorithmOid: algorithmOid) }
        guard let parameters = try parts[0].children().dropFirst().first, parameters.tag == derTagObjectIdentifier else {
            throw CertificateParsingError("EC key has no named curve")
        }
        let curveOid = try parameters.objectIdentifier()
        guard let curve = ReaderKeyCurve(rawValue: curveOid) else { return .ecOnOtherCurve(curveOid: curveOid) }
        // the BIT STRING's first byte counts unused bits, 0 for a point
        let bits = try parts[1].requireTag(derTagBitString, "subjectPublicKey").content
        guard bits.first == 0 else { throw CertificateParsingError("subjectPublicKey has unused bits") }
        return .ec(curve: curve, point: Array(bits.dropFirst()))
    }

    /// The first common name in [name], a SEQUENCE of SETs of type-and-value pairs.
    private static func commonName(_ name: DerElement) throws -> String? {
        for set in try name.requireTag(derTagSequence, "Name").children() {
            for attribute in try set.requireTag(derTagSet, "RelativeDistinguishedName").children() {
                let parts = try attribute.requireTag(derTagSequence, "AttributeTypeAndValue").children()
                guard parts.count == 2 else { throw CertificateParsingError("Name attribute is missing fields") }
                if try parts[0].objectIdentifier() == oidCommonName { return text(parts[1]) }
            }
        }
        return nil
    }

    private static func text(_ element: DerElement) -> String? {
        switch element.tag {
        case derTagUtf8String, derTagPrintableString, derTagIa5String:
            return String(decoding: element.content, as: UTF8.self)
        default:
            return nil
        }
    }

    /// UTCTime YYMMDDHHMMSSZ or GeneralizedTime YYYYMMDDHHMMSSZ, the forms RFC 5280 4.1.2.5 allows.
    private static func time(_ element: DerElement) throws -> Date {
        let text = String(decoding: element.content, as: UTF8.self)
        let yearDigits: Int
        switch (element.tag, text.count) {
        case (derTagUtcTime, 13): yearDigits = 2
        case (derTagGeneralizedTime, 15): yearDigits = 4
        default: throw CertificateParsingError("Certificate time is not UTCTime or GeneralizedTime")
        }
        guard text.last == "Z", text.dropLast().allSatisfy({ ("0"..."9").contains($0) }) else {
            throw CertificateParsingError("Certificate time is not in UTC")
        }
        // the digits are all ASCII, so offsets into the UTF-8 bytes are offsets into the text
        let digits = Array(text.utf8).map { Int($0) - Int(UInt8(ascii: "0")) }
        func number(_ start: Int, _ count: Int) -> Int {
            digits[start..<(start + count)].reduce(0) { $0 * 10 + $1 }
        }
        var year = number(0, yearDigits)
        // RFC 5280: a UTCTime year YY of 50 or more is 19YY, below 50 is 20YY
        if yearDigits == 2 { year += year >= 50 ? 1900 : 2000 }
        let month = number(yearDigits, 2), day = number(yearDigits + 2, 2)
        let hour = number(yearDigits + 4, 2), minute = number(yearDigits + 6, 2), second = number(yearDigits + 8, 2)
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else {
            throw CertificateParsingError("Invalid certificate time \(text)")
        }
        guard let utc = TimeZone(secondsFromGMT: 0) else { preconditionFailure("No UTC time zone") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else {
            throw CertificateParsingError("Invalid certificate time \(text)")
        }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else {
            throw CertificateParsingError("Invalid certificate calendar date")
        }
        return date
    }
}

extension DerReader {
    /// The one element that [bytes] hold, with nothing after it.
    static func single(_ bytes: [UInt8]) throws -> DerElement {
        var reader = DerReader(bytes)
        let element = try reader.read()
        guard reader.isAtEnd else { throw CertificateParsingError("Trailing bytes after a DER element") }
        return element
    }
}
