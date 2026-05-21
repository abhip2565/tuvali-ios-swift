import Foundation

@available(iOS 13.0, *)
class VerifierCryptoBoxBuilder {
    func build() -> VerifierCryptoBox {
        return VerifierCryptoBoxImpl()
    }
}
