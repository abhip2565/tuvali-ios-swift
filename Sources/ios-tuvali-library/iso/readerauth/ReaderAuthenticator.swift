import CryptoKit
import Foundation
import Security
import SwiftCBOR

// COSE header labels (IANA COSE registry): alg in the protected header, x5chain in the unprotected one
private let coseHeaderAlg: UInt64 = 1
private let coseHeaderX5chain: UInt64 = 33
private let coseSign1Tag: UInt64 = 18
private let coseSign1Elements = 4

// Annex B Table B.6
private let ekuMdlReaderAuth = "1.0.18013.5.1.6"

/// A COSE ECDSA algorithm: its hash, and for a fully-specified one also the only curve it allows.
private struct EcdsaAlgorithm {
    enum Hash { case sha256, sha384, sha512 }

    let hash: Hash
    var curve: ReaderKeyCurve?
}

// ES256, ES384 and ES512 (clause 9.1.4), and their fully-specified forms ESP256, ESP384 and ESP512
// (RFC 9864, IANA COSE registry), which readers such as Multipaz send and which allow only one curve
private let supportedAlgorithms: [Int: EcdsaAlgorithm] = [
    -7: EcdsaAlgorithm(hash: .sha256),
    -35: EcdsaAlgorithm(hash: .sha384),
    -36: EcdsaAlgorithm(hash: .sha512),
    -9: EcdsaAlgorithm(hash: .sha256, curve: .p256),
    -51: EcdsaAlgorithm(hash: .sha384, curve: .p384),
    -52: EcdsaAlgorithm(hash: .sha512, curve: .p521),
]

/// Checks a DocRequest's readerAuth (clause 9.1.4): an untagged COSE_Sign1 with a detached payload,
/// signed over ReaderAuthenticationBytes = #6.24(["ReaderAuthentication", SessionTranscript,
/// ItemsRequestBytes]) with ES256, ES384 or ES512 (or their fully-specified forms ESP256, ESP384 and
/// ESP512, which also pin the curve), carrying the reader certificate chain in x5chain.
///
/// The reader certificate must be valid at [now] and, when it has key usage or extended key usage,
/// allow digital signatures for mdoc reader authentication (Annex B Table B.6). Its key must be on
/// P-256, P-384 or P-521, the curves CryptoKit verifies. The chain is then validated against
/// [trustAnchors] by the Security framework (no revocation checks, no network). Problems never
/// throw: they are reported as ReaderTrust.invalid, so the holder can still be told who is asking.
final class ReaderAuthenticator {
    private let trustAnchors: [SecCertificate]
    private let now: () -> Date

    init(trustAnchors: [SecCertificate] = [], now: @escaping () -> Date = { Date() }) {
        self.trustAnchors = trustAnchors
        self.now = now
    }

    func check(_ readerAuth: CBOR?, sessionTranscriptBytes: [UInt8], itemsRequestBytes: [UInt8]) -> ReaderTrust {
        guard let readerAuth = readerAuth else { return .notSigned }
        do {
            return try checkSigned(readerAuth, sessionTranscriptBytes, itemsRequestBytes)
        } catch let rejected as ReaderAuthRejected {
            return .invalid(reason: rejected.reason)
        } catch {
            return .invalid(reason: "readerAuth could not be read: \(error)")
        }
    }

    private func checkSigned(
        _ readerAuth: CBOR,
        _ sessionTranscriptBytes: [UInt8],
        _ itemsRequestBytes: [UInt8]
    ) throws -> ReaderTrust {
        let sign1 = try untagged(readerAuth).asArray("readerAuth")
        guard sign1.count == coseSign1Elements else { throw ReaderAuthRejected("readerAuth is not a COSE_Sign1") }
        let protectedBytes = try sign1[0].asBytes("protected header")
        let unprotected = try sign1[1].asMap("unprotected header")
        guard sign1[2] == .null else { throw ReaderAuthRejected("readerAuth payload must be detached (null)") }
        let signature = try sign1[3].asBytes("signature")

        let protected = try protectedBytes.isEmpty ? [:] : decodeCbor(protectedBytes).asMap("protected header")
        try validateHeaders(protected, unprotected)
        guard let algorithm = algorithmOf(protected).flatMap({ supportedAlgorithms[$0] }) else {
            throw ReaderAuthRejected("Unsupported signature algorithm")
        }
        let chain = try certificateChain(unprotected)
        guard let readerCertificate = chain.first else { throw ReaderAuthRejected("x5chain is empty") }
        let (curve, point) = try checkReaderCertificateAndExtractKeyType(readerCertificate)
        if let required = algorithm.curve, required != curve {
            throw ReaderAuthRejected("Reader key is not on \(required.name), which the signature algorithm requires")
        }

        let signedBytes = sigStructure(
            protectedBytes,
            readerAuthenticationBytes(try untag24(decodeCbor(sessionTranscriptBytes)), itemsRequestBytes)
        )
        guard verify(algorithm.hash, curve, point, signedBytes, signature) else {
            throw ReaderAuthRejected("Reader signature does not verify")
        }

        let readerName = readerCertificate.commonName
        let certificates = chain.map(\.secCertificate)
        guard let untrustedReason = chainProblem(certificates) else {
            return .verified(readerName: readerName, certificateChain: certificates)
        }
        return .unverified(readerName: readerName, certificateChain: certificates, reason: untrustedReason)
    }

    /// Clause 9.1.4 asks for an untagged COSE_Sign1; the COSE_Sign1 tag 18 is accepted as well.
    private func untagged(_ item: CBOR) -> CBOR {
        guard case let .tagged(tag, content) = item, tag.rawValue == coseSign1Tag else { return item }
        return content
    }

    private func validateHeaders(_ protected: [CBOR: CBOR], _ unprotected: [CBOR: CBOR]) throws {
        for label in Array(protected.keys) + Array(unprotected.keys) {
            switch label {
            case .unsignedInt, .negativeInt, .utf8String: break
            default: throw ReaderAuthRejected("Invalid COSE header label")
            }
        }
        guard Set(protected.keys).isDisjoint(with: unprotected.keys) else {
            throw ReaderAuthRejected("COSE header label appears in both buckets")
        }
        let crit: CBOR = .unsignedInt(2)
        guard unprotected[crit] == nil else { throw ReaderAuthRejected("crit must be protected") }
        if let critical = protected[crit] {
            let labels = try critical.asArray("crit")
            guard !labels.isEmpty else {
                throw ReaderAuthRejected("Invalid crit header")
            }
            // Only alg is interpreted in the protected bucket by this reader-auth profile.
            guard labels.allSatisfy({ $0 == .unsignedInt(coseHeaderAlg) && protected[$0] != nil }) else {
                throw ReaderAuthRejected("Unsupported critical COSE header")
            }
            guard Set(labels).count == labels.count else { throw ReaderAuthRejected("Invalid crit header") }
        }
    }

    private func algorithmOf(_ protected: [CBOR: CBOR]) -> Int? {
        switch protected[.unsignedInt(coseHeaderAlg)] {
        case let .unsignedInt(value)?: return Int(exactly: value)
        case let .negativeInt(value)?: return Int(exactly: value).map { -1 - $0 }
        default: return nil
        }
    }

    /// x5chain is one certificate or an array of them, the reader's own certificate first.
    private func certificateChain(_ unprotected: [CBOR: CBOR]) throws -> [ReaderCertificate] {
        guard let x5chain = unprotected[.unsignedInt(coseHeaderX5chain)] else {
            throw ReaderAuthRejected("readerAuth has no x5chain")
        }
        let encodedCertificates: [[UInt8]]
        if case let .byteString(single) = x5chain {
            encodedCertificates = [single]
        } else {
            encodedCertificates = try x5chain.asArray("x5chain").map { try $0.asBytes("certificate") }
        }
        guard (1...8).contains(encodedCertificates.count), encodedCertificates.allSatisfy({ !$0.isEmpty && $0.count <= 64 * 1024 }) else {
            throw ReaderAuthRejected("x5chain exceeds certificate count or size limits")
        }
        return try encodedCertificates.map { der in try ReaderCertificate(der: der) }
    }

    /// The reader key's curve and point, once the certificate itself is acceptable.
    private func checkReaderCertificateAndExtractKeyType(_ certificate: ReaderCertificate) throws -> (ReaderKeyCurve, [UInt8]) {
        let time = now()
        if time > certificate.notAfter { throw ReaderAuthRejected("Reader certificate has expired") }
        if time < certificate.notBefore { throw ReaderAuthRejected("Reader certificate is not yet valid") }
        if certificate.allowsDigitalSignature == false {
            throw ReaderAuthRejected("Reader certificate does not allow digital signatures")
        }
        if let purposes = certificate.extendedKeyUsages, !purposes.contains(ekuMdlReaderAuth) {
            throw ReaderAuthRejected("Reader certificate is not for mdoc reader authentication")
        }
        switch certificate.publicKey {
        case let .ec(curve, point):
            return (curve, point)
        case let .ecOnOtherCurve(curveOid):
            throw ReaderAuthRejected("Reader key is on a curve that cannot be verified here (\(curveOid))")
        case .other:
            throw ReaderAuthRejected("Reader certificate does not hold an EC key")
        }
    }

    /// ReaderAuthenticationBytes, built from the transcript and ItemsRequest bytes exactly as they are.
    private func readerAuthenticationBytes(_ sessionTranscript: [UInt8], _ itemsRequestBytes: [UInt8]) -> [UInt8] {
        let arrayOfThree: UInt8 = 0x83
        let readerAuthentication = [arrayOfThree]
            + encodeCbor(.utf8String("ReaderAuthentication"))
            + sessionTranscript
            + encodeCbor(tag24(encodedCbor: itemsRequestBytes))
        return encodeCbor(tag24(encodedCbor: readerAuthentication))
    }

    /// COSE Sig_structure for COSE_Sign1 with empty external_aad and the detached payload (RFC 8152).
    private func sigStructure(_ protectedBytes: [UInt8], _ detachedPayload: [UInt8]) -> [UInt8] {
        encodeCbor(["Signature1", .byteString(protectedBytes), .byteString([]), .byteString(detachedPayload)])
    }

    /// COSE carries ECDSA signatures as r ‖ s, which CryptoKit's raw representation takes as is.
    /// The hash comes from the algorithm and the curve from the key, so ES256 on a P-384 key works.
    private func verify(
        _ hash: EcdsaAlgorithm.Hash,
        _ curve: ReaderKeyCurve,
        _ point: [UInt8],
        _ signedBytes: [UInt8],
        _ signature: [UInt8]
    ) -> Bool {
        switch hash {
        case .sha256: return verify(SHA256.hash(data: signedBytes), curve, point, signature)
        case .sha384: return verify(SHA384.hash(data: signedBytes), curve, point, signature)
        case .sha512: return verify(SHA512.hash(data: signedBytes), curve, point, signature)
        }
    }

    private func verify<D: Digest>(_ digest: D, _ curve: ReaderKeyCurve, _ point: [UInt8], _ signature: [UInt8]) -> Bool {
        // a point off the curve or a signature of the wrong size fails to parse, so it does not verify
        switch curve {
        case .p256:
            guard let key = try? P256.Signing.PublicKey(x963Representation: point),
                  let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
            return key.isValidSignature(parsed, for: digest)
        case .p384:
            guard let key = try? P384.Signing.PublicKey(x963Representation: point),
                  let parsed = try? P384.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
            return key.isValidSignature(parsed, for: digest)
        case .p521:
            guard let key = try? P521.Signing.PublicKey(x963Representation: point),
                  let parsed = try? P521.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
            return key.isValidSignature(parsed, for: digest)
        }
    }

    /// Nil when the chain leads to a trusted root; otherwise why it does not.
    private func chainProblem(_ chain: [SecCertificate]) -> String? {
        guard !trustAnchors.isEmpty else { return "No trusted reader roots are configured" }
        var createdTrust: SecTrust?
        let created = SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &createdTrust)
        guard created == errSecSuccess, let trust = createdTrust else {
            return "Reader certificate chain could not be checked (status \(created))"
        }
        // only the configured roots count, at the session's time, with nothing fetched from the network
        SecTrustSetAnchorCertificates(trust, trustAnchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, now() as CFDate)
        var failure: CFError?
        guard SecTrustEvaluateWithError(trust, &failure) else {
            let detail = failure.map { CFErrorCopyDescription($0) as String } ?? "unknown reason"
            return "Reader certificate chain does not lead to a trusted root: \(detail)"
        }
        return nil
    }
}

private struct ReaderAuthRejected: Error {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}
