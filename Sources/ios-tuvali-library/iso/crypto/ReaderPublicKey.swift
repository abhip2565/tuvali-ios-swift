import CryptoKit
import SwiftCBOR

/// The reader's ephemeral public key (EReaderKey), checked before it is used for ECDH.
///
/// Only an uncompressed EC2 key on P-256 whose point lies on the curve is accepted (clauses
/// 9.1.1.4, 9.1.5.2); anything else could leak information about our private key in ECDH.
/// Optional COSE parameters other than crv, x and y are ignored, as clause 9.1.5.2 asks.
struct ReaderPublicKey {
    let publicKey: P256.KeyAgreement.PublicKey
    let x: [UInt8]
    let y: [UInt8]

    /// Parses and checks the COSE_Key bytes carried inside EReaderKeyBytes.
    static func fromCoseKey(_ encodedCoseKey: [UInt8]) throws -> ReaderPublicKey {
        guard case let .map(coseKey) = try decodeCbor(encodedCoseKey) else {
            throw InvalidReaderKeyError("EReaderKey is not a COSE_Key map")
        }
        try requireLabel(coseKey, coseLabelKeyType, coseKeyTypeEc2, "key type must be EC2")
        try requireLabel(coseKey, coseLabelCurve, coseCurveP256, "curve must be P-256")
        let x = try coordinate(coseKey, coseLabelX, "x")
        let y = try coordinate(coseKey, coseLabelY, "y (the key must be uncompressed)")
        // CryptoKit accepts the uncompressed point 04 ‖ x ‖ y only if it lies on P-256
        guard let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: [0x04] + x + y) else {
            throw InvalidReaderKeyError("EReaderKey is not a point on P-256")
        }
        return ReaderPublicKey(publicKey: publicKey, x: x, y: y)
    }

    private static func requireLabel(_ coseKey: [CBOR: CBOR], _ label: Int, _ expected: Int, _ problem: String) throws {
        guard coseKey[CBOR(integerLiteral: label)] == CBOR(integerLiteral: expected) else {
            throw InvalidReaderKeyError("EReaderKey \(problem)")
        }
    }

    private static func coordinate(_ coseKey: [CBOR: CBOR], _ label: Int, _ name: String) throws -> [UInt8] {
        guard case let .byteString(bytes)? = coseKey[CBOR(integerLiteral: label)], bytes.count == p256FieldBytes else {
            throw InvalidReaderKeyError("EReaderKey \(name) must be a \(p256FieldBytes)-byte string")
        }
        return bytes
    }
}
