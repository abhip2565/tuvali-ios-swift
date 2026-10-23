import XCTest
@testable import ios_tuvali_library

/// BLE parts of MTU − 3 bytes, each starting 0x01 (more) or 0x00 (last): ISO 18013-5 clause 8.3.3.1.1.6.
/// iOS reports MTU − 3 directly (maximumWriteValueLength), so the chunker takes that number.
final class BleChunkerTests: XCTestCase {
    // the smallest ATT MTU (23): parts of 20 bytes, so 19 bytes of message per part
    private let smallestPartBytes = 20

    private func chunker(_ maximumPartBytes: Int? = nil, maxMessageBytes: Int? = nil) throws -> BleChunker {
        if let maxMessageBytes = maxMessageBytes {
            let partBytes = maximumPartBytes ?? smallestPartBytes
            return try BleChunker(maximumPartBytes: partBytes, maxMessageBytes: maxMessageBytes)
        }
        return try BleChunker(maximumPartBytes: maximumPartBytes ?? smallestPartBytes)
    }

    func testSplitSendsAShortMessageAsOneLastPart() throws {
        let message = "a1b2".hexToBytes()

        let parts = try chunker().split(message)

        XCTAssertEqual(parts.map(\.hex), ["00a1b2"])
    }

    func testSplitFitsAMessageOfExactlyOnePartPayloadIntoOnePart() throws {
        let message = [UInt8](repeating: 7, count: 19)

        let parts = try chunker().split(message)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts.first?.count, 20)
    }

    func testSplitStartsASecondPartWhenTheMessageIsOneByteOver() throws {
        let message = (0..<20).map { UInt8($0) }

        let parts = try chunker().split(message)

        XCTAssertEqual(parts.map(\.count), [20, 2])
        XCTAssertEqual(parts.map { $0[0] }, [0x01, 0x00])
    }

    func testSplitNeverMakesAPartLongerThanMtuMinus3Bytes() throws {
        // the largest MTU iOS uses: parts of 512 bytes, the largest attribute value
        let message = (0..<2000).map { UInt8(truncatingIfNeeded: $0) }

        let parts = try chunker(512).split(message)

        XCTAssertEqual(parts.map(\.count).max(), 512)
    }

    func testSplitSendsAnEmptyMessageAsASingleLastPartWithNoPayload() throws {
        let parts = try chunker().split([])

        XCTAssertEqual(parts.map(\.hex), ["00"])
    }

    func testBleChunkerThrowsIsoTransportErrorWhenThePartSizeLeavesNoRoomForMessageBytes() {
        // a 1-byte part only holds the header
        XCTAssertThrowsError(try BleChunker(maximumPartBytes: 1), ofType: IsoTransportError.self)
    }

    func testAddPieceReturnsNothingUntilTheLastPartThenTheWholeMessage() throws {
        let chunker = try chunker()

        let afterFirst = try chunker.addPiece("01a1b2".hexToBytes())
        let afterLast = try chunker.addPiece("00c3".hexToBytes())

        XCTAssertNil(afterFirst)
        XCTAssertEqual(afterLast?.hex, "a1b2c3")
    }

    func testAddPieceStartsAFreshMessageAfterCompletingOne() throws {
        let chunker = try chunker()
        _ = try chunker.addPiece("00a1".hexToBytes())

        let second = try chunker.addPiece("00b2".hexToBytes())

        XCTAssertEqual(second?.hex, "b2")
    }

    func testAddPieceRebuildsAnyMessageThatSplitProduced() throws {
        let partSizes = [20, 21, 182, 512]
        let messageSizes = [0, 1, 18, 19, 20, 38, 39, 511, 512, 513, 5000]

        for partSize in partSizes {
            for size in messageSizes {
                let message = (0..<size).map { UInt8(truncatingIfNeeded: $0 * 31 + size) }
                let chunker = try chunker(partSize)

                let rebuilt = try chunker.split(message).map { try chunker.addPiece($0) }.last ?? nil

                XCTAssertEqual(rebuilt, message, "part size \(partSize), message size \(size)")
            }
        }
    }

    func testAddPieceThrowsIsoTransportErrorForAnEmptyPart() throws {
        let chunker = try chunker()

        XCTAssertThrowsError(try chunker.addPiece([]), ofType: IsoTransportError.self)
    }

    func testAddPieceThrowsIsoTransportErrorWhenTheHeaderIsNeither0x01Nor0x00() throws {
        let chunker = try chunker()

        XCTAssertThrowsError(try chunker.addPiece("02a1".hexToBytes()), ofType: IsoTransportError.self)
    }

    func testAddPieceThrowsIsoTransportErrorWhenAMessageGrowsPastTheSizeLimit() throws {
        // a 4-byte limit, so the second part pushes the message to 6 bytes
        let chunker = try chunker(maxMessageBytes: 4)
        _ = try chunker.addPiece("01a1a2a3".hexToBytes())

        XCTAssertThrowsError(try chunker.addPiece("01b1b2b3".hexToBytes()), ofType: IsoTransportError.self)
    }
}
