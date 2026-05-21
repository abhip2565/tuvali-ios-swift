import Foundation
import CoreBluetooth

@available(iOS 13.0, *)
protocol VerifierTransferHandlerDelegate: AnyObject {
    func sendDataOverNotification(charUUID: CBUUID, data: Data)
    func onResponseReceived(data: Data, crcFailureCount: Int, totalChunkCount: Int)
    func onResponseReceivedFailed(_ message: String)
}

@available(iOS 13.0, *)
class VerifierTransferHandler {
    private weak var delegate: VerifierTransferHandlerDelegate?
    private var assembler: Assembler?
    private var maxDataBytes = BLEConstants.MAX_ALLOWED_DATA_LEN

    init(delegate: VerifierTransferHandlerDelegate) {
        self.delegate = delegate
    }

    func handleResponseSize(_ data: Data, maxDataBytes: Int) {
        guard data.count == 4 else {
            delegate?.onResponseReceivedFailed("Verifier received invalid response size")
            return
        }
        self.maxDataBytes = maxDataBytes
        var beSize: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &beSize) { dst in
            data.copyBytes(to: dst)
        }
        let responseSize = Int(UInt32(bigEndian: beSize))
        guard responseSize > 0 else {
            delegate?.onResponseReceivedFailed("Verifier received empty response")
            return
        }
        assembler = Assembler(totalSize: responseSize, maxDataBytes: maxDataBytes)
    }

    func handleResponseChunk(_ data: Data) {
        guard let assembler, !assembler.isComplete() else {
            return
        }
        assembler.addChunk(data)
    }

    func handleTransferReportRequest(_ data: Data) {
        guard let reportType = data.first else {
            return
        }

        if reportType == UInt8(SemaphoreMarker.Error.rawValue) {
            delegate?.onResponseReceivedFailed("Wallet reported an error during transfer")
            return
        }

        guard reportType == UInt8(SemaphoreMarker.RequestReport.rawValue), let assembler else {
            return
        }

        if assembler.isComplete() {
            let report = TransferReport(type: .SUCCESS, totalPages: 0, missingSequences: [])
            delegate?.sendDataOverNotification(charUUID: NetworkCharNums.TRANSFER_REPORT_RESPONSE_CHAR_UUID, data: report.toBytes(maxDataBytes: maxDataBytes))
            delegate?.onResponseReceived(
                data: assembler.assembledData(),
                crcFailureCount: assembler.crcFailureCount,
                totalChunkCount: assembler.totalChunkCount
            )
            return
        }

        let missed = assembler.missedSequenceNumbers()
        if Double(missed.count) > (0.7 * Double(assembler.totalChunkCount)) {
            delegate?.onResponseReceivedFailed("Failing transfer as missing chunks are more than 70% of total chunks")
            return
        }

        let report = TransferReport(type: .MISSING_CHUNKS, totalPages: 1, missingSequences: missed)
        delegate?.sendDataOverNotification(charUUID: NetworkCharNums.TRANSFER_REPORT_RESPONSE_CHAR_UUID, data: report.toBytes(maxDataBytes: maxDataBytes))
    }
}
