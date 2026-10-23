private let identBytes = 16
private let infoBleIdent = Array("BLEIdent".utf8)

/// The value the reader's Ident characteristic must hold (clause 8.3.3.1.1.3):
/// HKDF-SHA256 over EDeviceKeyBytes with no salt, info "BLEIdent", 16 bytes.
func bleIdent(_ eDeviceKeyBytes: [UInt8]) -> [UInt8] {
    hkdfSha256(eDeviceKeyBytes, salt: nil, info: infoBleIdent, length: identBytes)
}
