import XCTest
import CoreBluetooth
@testable import ios_tuvali_library

class MockVerifierTransferHandlerDelegate: VerifierTransferHandlerDelegate {
    var sentData: [(charUUID: CBUUID, data: Data)] = []
    var receivedData: Data?
    var receivedCrcFailureCount: Int?
    var receivedTotalChunkCount: Int?
    var failedMessage: String?

    func sendDataOverNotification(charUUID: CBUUID, data: Data) {
        sentData.append((charUUID, data))
    }

    func onResponseReceived(data: Data, crcFailureCount: Int, totalChunkCount: Int) {
        receivedData = data
        receivedCrcFailureCount = crcFailureCount
        receivedTotalChunkCount = totalChunkCount
    }

    func onResponseReceivedFailed(_ message: String) {
        failedMessage = message
    }
}

final class ios_tuvali_libraryTests: XCTestCase {
    func testExample() throws {
        XCTAssertEqual(ios_tuvali_library().text, "Hello, World!")
    }

    func testAssemblerInitializationWithLowMaxDataBytes() {
        // maxDataBytes (3) <= chunkMetaSize (4)
        let assembler = Assembler(totalSize: 100, maxDataBytes: 3)
        XCTAssertEqual(assembler.totalChunkCount, 0)
        XCTAssertTrue(assembler.isComplete())
        
        // Verify addChunk does not crash
        let dummyChunk = Data([0x00, 0x01, 0x02])
        assembler.addChunk(dummyChunk)
        XCTAssertEqual(assembler.crcFailureCount, 0)
    }

    func testAssemblerInitializationWithNormalMaxDataBytes() {
        // maxDataBytes (20) > chunkMetaSize (4), effective payload size = 16
        // totalSize = 32, so totalChunks = 32 / 16 = 2
        let assembler = Assembler(totalSize: 32, maxDataBytes: 20)
        XCTAssertEqual(assembler.totalChunkCount, 2)
        XCTAssertFalse(assembler.isComplete())
    }

    func testVerifierTransferHandlerResponseSizeParsing() {
        let mockDelegate = MockVerifierTransferHandlerDelegate()
        let handler = VerifierTransferHandler(delegate: mockDelegate)
        
        // 1. Valid size: 100 bytes (big endian UInt32 = 0x00000064)
        let validData = Data([0x00, 0x00, 0x00, 0x64])
        handler.handleResponseSize(validData, maxDataBytes: 20)
        XCTAssertNil(mockDelegate.failedMessage)
        
        // 2. Invalid size (not 4 bytes)
        let invalidData = Data([0x00, 0x00, 0x64])
        handler.handleResponseSize(invalidData, maxDataBytes: 20)
        XCTAssertEqual(mockDelegate.failedMessage, "Verifier received invalid response size")
        
        // Reset failed message
        mockDelegate.failedMessage = nil
        
        // 3. Size <= 0
        let zeroData = Data([0x00, 0x00, 0x00, 0x00])
        handler.handleResponseSize(zeroData, maxDataBytes: 20)
        XCTAssertEqual(mockDelegate.failedMessage, "Verifier received empty response")
    }

    func testEachAdvertisementGetsAFreshNameThatIsSharedInTheQR() throws {
        let verifier = Verifier()

        let first = try advertisedName(verifier.startAdvertisement("OVPMOSIP"))
        let second = try advertisedName(verifier.startAdvertisement("OVPMOSIP"))
        verifier.disconnect()

        XCTAssertNotEqual(first, "OVPMOSIP")
        XCTAssertNotEqual(first, second)
    }

    func testFreshAdvertisementNameIsEightUrlSafeCharactersSoIOSDoesNotTruncateIt() {
        // base64url alphabet, no padding
        let urlSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        let name = Verifier.freshAdvertisementName()

        XCTAssertEqual(name.utf8.count, 8)
        XCTAssertTrue(name.unicodeScalars.allSatisfy { urlSafe.contains($0) })
    }

    private func advertisedName(_ uri: String) throws -> String? {
        let components = try XCTUnwrap(URLComponents(string: uri))
        return components.queryItems?.first(where: { $0.name == "name" })?.value
    }

    func testVerifierDisconnect() {
        let verifier = Verifier()
        // Should not crash when bleCommunicator is nil
        verifier.disconnect()
        
        _ = verifier.startAdvertisement("TestDevice")
        // Should stop the advertising and clear communicator without crash
        verifier.disconnect()
    }
}

