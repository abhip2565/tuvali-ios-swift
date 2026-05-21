import Foundation

public struct DataReceivedEvent: Event {
    public let data: String
    public let crcFailureCount: Int
    public let totalChunkCount: Int

    public init(data: String, crcFailureCount: Int = 0, totalChunkCount: Int = 0) {
        self.data = data
        self.crcFailureCount = crcFailureCount
        self.totalChunkCount = totalChunkCount
    }
}
