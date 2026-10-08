import Foundation

protocol SecretTranslator {
    func getNonce() -> Data
    func encryptToSend(data: Data) throws -> Data
    func decryptUponReceive(data: Data) throws -> Data
}
