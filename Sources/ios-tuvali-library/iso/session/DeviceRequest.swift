import SwiftCBOR

// The engagement is version 1.0, and a request's major version must not be higher (clause 8.3.2.1.2.1)
private let supportedMajorVersion = 1

/// Checks one DocRequest's readerAuth (nil when unsigned) against its ItemsRequest bytes.
typealias ReaderAuthCheck = (_ readerAuth: CBOR?, _ itemsRequestBytes: [UInt8]) -> ReaderTrust

/// The reader's decrypted request (clause 8.3.2.1.2.1): one or more requested documents.
struct DeviceRequest: Equatable {
    let version: String
    let docRequests: [DocRequest]

    /// Parses a request and checks each document's reader authentication with [checkReaderAuth].
    /// Anything malformed is a CborDecodingError, answered with status 11.
    static func decode(_ plaintext: [UInt8], checkReaderAuth: ReaderAuthCheck) throws -> DeviceRequest {
        let map = try decodeCbor(plaintext).asMap("DeviceRequest")
        let version = try map.required("version", "DeviceRequest").asText("version")
        try checkMajorVersion(version)
        let docRequests = try map.required("docRequests", "DeviceRequest").asArray("docRequests")
        guard !docRequests.isEmpty else { throw CborDecodingError("DeviceRequest has no docRequests") }
        return DeviceRequest(
            version: version,
            docRequests: try docRequests.map { item in try DocRequest.decode(item, checkReaderAuth: checkReaderAuth) }
        )
    }

    // a known major version with an unknown minor version is not an error (clause 8.1)
    private static func checkMajorVersion(_ version: String) throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { throw CborDecodingError("Malformed DeviceRequest version \(version)") }
        let major = Int(parts[0])
        guard major == supportedMajorVersion else {
            throw CborDecodingError("Unsupported DeviceRequest version \(version)")
        }
    }
}

/// One requested document. [nameSpaces] maps each namespace to its requested data elements and
/// their IntentToRetain flag. [itemsRequestBytes] are the ItemsRequest exactly as received, since
/// reader authentication signs those bytes; [readerTrust] is the result of checking that signature.
/// requestInfo and unknown keys are ignored (clause 8.3.2.1.2.1).
struct DocRequest: Equatable {
    let docType: String
    let nameSpaces: [String: [String: Bool]]
    let itemsRequestBytes: [UInt8]
    let readerTrust: ReaderTrust

    static func decode(_ item: CBOR, checkReaderAuth: ReaderAuthCheck) throws -> DocRequest {
        let docRequest = try item.asMap("DocRequest")
        let itemsRequestBytes = try untag24(docRequest.required("itemsRequest", "DocRequest"))
        let itemsRequest = try decodeCbor(itemsRequestBytes).asMap("ItemsRequest")
        return DocRequest(
            docType: try itemsRequest.required("docType", "ItemsRequest").asText("docType"),
            nameSpaces: try decodeNameSpaces(itemsRequest.required("nameSpaces", "ItemsRequest")),
            itemsRequestBytes: itemsRequestBytes,
            readerTrust: checkReaderAuth(docRequest.optional("readerAuth"), itemsRequestBytes)
        )
    }

    private static func decodeNameSpaces(_ item: CBOR) throws -> [String: [String: Bool]] {
        let nameSpaces = try item.asMap("nameSpaces")
        guard !nameSpaces.isEmpty else { throw CborDecodingError("nameSpaces is empty") }
        var decoded: [String: [String: Bool]] = [:]
        for (nameSpace, elementsItem) in nameSpaces {
            let elements = try elementsItem.asMap("DataElements")
            guard !elements.isEmpty else { throw CborDecodingError("No data elements requested in a namespace") }
            var intents: [String: Bool] = [:]
            for (element, intentToRetain) in elements {
                intents[try element.asText("DataElementIdentifier")] = try intentToRetain.asBoolean("IntentToRetain")
            }
            decoded[try nameSpace.asText("NameSpace")] = intents
        }
        return decoded
    }
}
