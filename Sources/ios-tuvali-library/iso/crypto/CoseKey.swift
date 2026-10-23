import SwiftCBOR

// COSE_Key labels and values (RFC 8152, IANA COSE registry)
let coseLabelKeyType = 1
let coseLabelCurve = -1
let coseLabelX = -2
let coseLabelY = -3
let coseKeyTypeEc2 = 2
let coseCurveP256 = 1

extension EphemeralDeviceKey {
    /// The public key as a COSE_Key: EC2 on P-256 with uncompressed x and y, and no optional
    /// parameters besides crv, x and y (ISO 18013-5 clause 9.1.5.2).
    func toCoseKey() -> CBOR {
        .map([
            CBOR(integerLiteral: coseLabelKeyType): CBOR(integerLiteral: coseKeyTypeEc2),
            CBOR(integerLiteral: coseLabelCurve): CBOR(integerLiteral: coseCurveP256),
            CBOR(integerLiteral: coseLabelX): .byteString(x),
            CBOR(integerLiteral: coseLabelY): .byteString(y),
        ])
    }
}
