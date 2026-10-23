import SwiftCBOR

/// SessionTranscriptBytes (clause 9.1.5.1):
/// #6.24(bstr .cbor [DeviceEngagementBytes, EReaderKeyBytes, Handover]), where the handover is
/// null for QR engagement.
///
/// The engagement and reader key bytes are wrapped exactly as given: the engagement as put in the
/// QR code, and the reader's COSE_Key as received inside EReaderKeyBytes, never decoded and re-encoded.
func sessionTranscriptBytes(
    deviceEngagementBytes: [UInt8],
    readerCoseKey: [UInt8],
    handover: Handover = .qr
) -> [UInt8] {
    let transcript: CBOR = [
        tag24(encodedCbor: deviceEngagementBytes),
        tag24(encodedCbor: readerCoseKey),
        handover.toCbor(),
    ]
    return encodeCbor(tag24(encodedCbor: encodeCbor(transcript)))
}
