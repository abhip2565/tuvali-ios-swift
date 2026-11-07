import CryptoKit
import Foundation
import OpenID4VP
import SwiftCBOR
import ios_tuvali_library

/// The wallet's part of an in-person presentation, for the demo: keep only the requested elements
/// of the test mDL (each item's bytes untouched, so its digest still matches the MSO), then let
/// OpenID4VP build and sign the DeviceResponse over the session transcript from Tuvali.
enum DemoWallet {
    struct Answer {
        let deviceResponse: Data
        let sharedElements: [String]
    }

    static func answer(_ request: MdocRequest) async throws -> Answer {
        var shared: [String] = []
        var credentials: [Data] = []
        if let asked = request.documents.first(where: { $0.docType == TestMdl.docType }) {
            let (credential, elements) = try filteredCredential(keeping: asked.nameSpaces)
            credentials.append(credential)
            shared = elements
        }
        let deviceKey = try P256.Signing.PrivateKey(rawRepresentation: bytes(TestMdl.devicePrivateKeyHex))
        let response = try await MdocProximity.buildDeviceResponse(
            sessionTranscriptBytes: request.sessionTranscript,
            credentials: credentials
        ) { input in
            try deviceKey.signature(for: input.dataToSign).rawRepresentation
        }
        return Answer(deviceResponse: response, sharedElements: shared)
    }

    /// The test mDL's IssuerSigned with only the requested elements; namespaces left empty are dropped.
    private static func filteredCredential(keeping requested: [String: [String: Bool]]) throws -> (Data, [String]) {
        guard case let .map(issuerSigned)? = try CBOR.decode(bytes(TestMdl.credentialHex)),
              case let .map(nameSpaces)? = issuerSigned["nameSpaces"] else {
            throw DemoWalletError("Test mDL is not an IssuerSigned map")
        }
        var kept: [CBOR: CBOR] = [:]
        var shared: [String] = []
        for (nameSpaceKey, items) in nameSpaces {
            guard case let .utf8String(nameSpace) = nameSpaceKey, let wanted = requested[nameSpace],
                  case let .array(list) = items else { continue }
            let keep = list.filter { item in elementIdentifier(of: item).map { wanted[$0] != nil } ?? false }
            if !keep.isEmpty {
                kept[nameSpaceKey] = .array(keep)
                shared += keep.compactMap(elementIdentifier(of:))
            }
        }
        var filtered = issuerSigned
        filtered["nameSpaces"] = kept.isEmpty ? nil : .map(kept)
        return (Data(CBOR.map(filtered).encode()), shared.sorted())
    }

    private static func elementIdentifier(of item: CBOR) -> String? {
        guard case let .tagged(_, .byteString(itemBytes)) = item,
              case let .map(decoded)? = try? CBOR.decode(itemBytes),
              case let .utf8String(identifier)? = decoded["elementIdentifier"] else { return nil }
        return identifier
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        }
    }
}

struct DemoWalletError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
