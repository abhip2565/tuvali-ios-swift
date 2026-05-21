import Foundation

@available(iOS 13.0, *)
class VerifierCryptoBoxImpl: VerifierCryptoBox {
    private let selfCryptoBox = CryptoBoxImpl()

    func getPublicKey() -> Data {
        return selfCryptoBox.getPublicKey()
    }

    func buildSecretsTranslator(nonce: Data, walletPublicKey: Data) -> SecretTranslator {
        let cipherPackage = selfCryptoBox.createCipherPackage(
            otherPublicKey: walletPublicKey,
            senderInfo: CryptoConstants.VERIFIER_INFO,
            recieverInfo: CryptoConstants.WALLET_INFO,
            nonceBytes: nonce
        )
        return SenderTransferOwnershipOfData(CipherPackage: cipherPackage, nonce: nonce)
    }
}
