import Foundation

@available(iOS 13.0, *)
protocol VerifierCryptoBox {
    func getPublicKey() -> Data
    func buildSecretsTranslator(nonce: Data, walletPublicKey: Data) -> SecretTranslator
}
