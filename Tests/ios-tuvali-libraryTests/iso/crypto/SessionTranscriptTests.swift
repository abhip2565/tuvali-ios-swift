import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// SessionTranscript for QR engagement: ISO 18013-5 clause 9.1.5.1.
final class SessionTranscriptTests: XCTestCase {
    private let deviceEngagementBytes = SessionTestVectors.bytes("deviceEngagement")
    private var readerCoseKey: [UInt8]!

    override func setUpWithError() throws {
        readerCoseKey = try untag24(decodeCbor(SessionTestVectors.bytes("readerKey.eReaderKeyBytes")))
    }

    private func transcriptBytes(_ readerCoseKey: [UInt8]) -> [UInt8] {
        sessionTranscriptBytes(deviceEngagementBytes: deviceEngagementBytes, readerCoseKey: readerCoseKey)
    }

    func testSessionTranscriptBytesReproducesTheTranscriptOfTheTestVectors() {
        let transcript = transcriptBytes(readerCoseKey)

        XCTAssertEqual(transcript.hex, SessionTestVectors.string("sessionTranscriptBytes"))
    }

    func testSessionTranscriptBytesKeepsTheReaderKeyBytesExactlyAsReceivedWhenTheyAreNotCanonical() throws {
        // kty written as 18 02 (two bytes) instead of the shortest form 02
        let oddEReaderKeyBytes = SessionTestVectors.bytes("nonCanonicalReaderKey.eReaderKeyBytes")
        let oddReaderCoseKey = try untag24(decodeCbor(oddEReaderKeyBytes))

        let transcript = transcriptBytes(oddReaderCoseKey)

        XCTAssertEqual(transcript.hex, SessionTestVectors.string("nonCanonicalReaderKey.sessionTranscriptBytes"))
    }

    func testSessionTranscriptBytesHoldsTheEngagementTheReaderKeyAndANullQrHandoverEachAsSent() throws {
        let transcript = transcriptBytes(readerCoseKey)

        let items = try decodeCbor(untag24(decodeCbor(transcript))).items
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(try untag24(items[0]), deviceEngagementBytes)
        XCTAssertEqual(try untag24(items[1]), readerCoseKey)
        XCTAssertEqual(items[2], .null)
    }
}
