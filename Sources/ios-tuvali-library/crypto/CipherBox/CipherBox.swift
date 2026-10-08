import Foundation

protocol CipherBox {
    func encrypt(message: Data) throws -> Data
    func decrypt(message: Data) throws -> Data
}
