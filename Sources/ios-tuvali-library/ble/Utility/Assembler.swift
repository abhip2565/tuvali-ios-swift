import Foundation

class Assembler {
    private let maxDataBytes: Int
    private let chunkMetaSize = BLEConstants.seqNumberReservedByteSize + BLEConstants.mtuReservedByteSize
    private var data: Data
    private var chunkReceivedMarker: [Bool]
    private(set) var crcFailureCount = 0

    init(totalSize: Int, maxDataBytes: Int) {
        self.maxDataBytes = maxDataBytes
        self.data = Data(repeating: 0, count: totalSize)
        let effectivePayloadSize = maxDataBytes - chunkMetaSize
        let totalChunks = Int(ceil(Double(totalSize) / Double(effectivePayloadSize)))
        self.chunkReceivedMarker = Array(repeating: false, count: max(totalChunks, 0))
    }

    var totalChunkCount: Int {
        return chunkReceivedMarker.count
    }

    func addChunk(_ chunkData: Data) {
        guard chunkData.count >= chunkMetaSize, chunkData.count <= maxDataBytes else {
            return
        }

        let seqNumber = Util.networkOrderedByteArrayToInt(num: chunkData.subdata(in: 0..<2))
        let crcReceived = UInt16(Util.networkOrderedByteArrayToInt(num: chunkData.subdata(in: 2..<4)))
        let payload = chunkData.subdata(in: 4..<chunkData.count)

        guard CRC.verify(d: payload, expected: crcReceived) else {
            crcFailureCount += 1
            return
        }

        let seqIndex = seqNumber.toSeqIndex()
        guard seqIndex >= 0, seqIndex < chunkReceivedMarker.count else {
            return
        }

        let effectivePayloadSize = maxDataBytes - chunkMetaSize
        let start = seqIndex * effectivePayloadSize
        let end = min(start + payload.count, data.count)
        guard start < end else {
            return
        }

        data.replaceSubrange(start..<end, with: payload.prefix(end - start))
        chunkReceivedMarker[seqIndex] = true
    }

    func isComplete() -> Bool {
        return !chunkReceivedMarker.contains(false)
    }

    func missedSequenceNumbers() -> [Int] {
        return chunkReceivedMarker.enumerated().compactMap { index, received in
            received ? nil : index.toSeqNumber()
        }
    }

    func assembledData() -> Data {
        return data
    }
}
