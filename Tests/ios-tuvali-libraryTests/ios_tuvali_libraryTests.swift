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

    func testVerifierUrlEncoding() {
        let verifier = Verifier()
        // Test advertising identifier with special characters and spaces
        let advName = "Test Name!@# 123"
        let uri = verifier.startAdvertisement(advName)
        
        // Check that the returned URI is formatted correctly
        XCTAssertTrue(uri.hasPrefix("OPENID4VP://connect?"))
        
        // Parse the URI using URLComponents to verify components
        guard let components = URLComponents(string: uri) else {
            XCTFail("Failed to parse URI: \(uri)")
            return
        }
        
        let nameQueryItem = components.queryItems?.first(where: { $0.name == "name" })
        XCTAssertNotNil(nameQueryItem)
        XCTAssertEqual(nameQueryItem?.value, advName)
        
        // Ensure that in the raw URI string, spaces and special characters are encoded
        XCTAssertTrue(uri.contains("Test%20Name"))
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

