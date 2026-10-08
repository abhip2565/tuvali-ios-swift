import Foundation
import CryptoKit

protocol WalletCryptoBox {
    func buildSecretsTranslator(verifierPublicKey: Data) throws -> SecretTranslator
    func getPublicKey() -> Data
}
