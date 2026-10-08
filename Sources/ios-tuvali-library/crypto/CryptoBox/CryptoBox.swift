import Foundation
import CryptoKit

protocol CryptoBox {
    func createCipherPackage(otherPublicKey: Data, senderInfo: String, recieverInfo: String, nonceBytes: Data) throws -> CipherPackage
    func getPublicKey() -> Data
}

