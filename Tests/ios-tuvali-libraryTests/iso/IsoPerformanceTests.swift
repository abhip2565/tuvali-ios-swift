import SwiftCBOR
import XCTest
@testable import ios_tuvali_library

/// Diagnostic baselines, with no hardware-specific pass/fail thresholds. Run in Release for profiling.
final class IsoPerformanceTests: XCTestCase {
    func testDecodeLargeRequestMap() {
        let map = CBOR.map(Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            (CBOR.utf8String("element_\($0)"), CBOR.boolean(false))
        }))
        let bytes = encodeCbor(map)
        measure {
            do { for _ in 0..<10 { _ = try decodeCbor(bytes) } }
            catch { XCTFail("\(error)") }
        }
    }

    func testParseReaderCertificate() {
        let bytes = SessionTestVectors.bytes("readerAuth.rootCertificate")
        measure {
            do { for _ in 0..<100 { _ = try ReaderCertificate(der: bytes) } }
            catch { XCTFail("\(error)") }
        }
    }

    func testReassemble64KiBMessageAtMinimumMtu() throws {
        let chunker = try BleChunker(maximumPartBytes: 20)
        let message = [UInt8](repeating: 0xa5, count: 64 * 1024)
        let pieces = chunker.split(message)
        measure {
            var result: [UInt8]?
            for piece in pieces { result = try? chunker.addPiece(piece) }
            XCTAssertEqual(result, message)
        }
    }
}
