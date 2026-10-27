import Security

/// How far a document request's reader authentication (clause 9.1.4) could be trusted.
enum ReaderTrust: Equatable {
    /// The reader did not sign the request.
    case notSigned

    /// The signature is valid and the reader's certificate chain leads to a trusted root.
    case verified(readerName: String?, certificateChain: [SecCertificate])

    /// The signature is valid, but the chain does not lead to a trusted root (or no trust list is set).
    case unverified(readerName: String?, certificateChain: [SecCertificate], reason: String)

    /// The signature or the reader's certificate cannot be accepted.
    case invalid(reason: String)
}
