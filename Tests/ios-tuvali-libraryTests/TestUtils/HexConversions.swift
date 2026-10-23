import Foundation

extension String {
    func hexToBytes() -> [UInt8] {
        precondition(count.isMultiple(of: 2), "Hex string has an odd length")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count / 2)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            guard let byte = UInt8(self[index..<next], radix: 16) else { fatalError("Not hex: \(self[index..<next])") }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
