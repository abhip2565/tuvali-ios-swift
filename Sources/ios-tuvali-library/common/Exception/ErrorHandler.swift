import Foundation

private let logger = TaggedLogger(tag: "ErrorHandler")

class ErrorHandler {
    public static var sharedInstance = ErrorHandler()
    private var walletExceptionHandler: WalletExceptionHandler?
    private var onError: ((_ message: String, _ code: String) -> Void)?

    private init() {}

    func handleException(type: ExceptionType, error: WalletErrorEnum) {
        if type == .walletException {
            walletExceptionHandler?.handle(error: error)
        } else if type == .verifierException {
        } else {
            handleUnknownException(error: error)
        }
    }

    func setOnError(onError: @escaping (_ message: String, _ code: String) -> Void) {
        self.onError = onError
        walletExceptionHandler = WalletExceptionHandler(error: self.onError!)
    }

    private func handleUnknownException(error: WalletErrorEnum) {
        logger.error("Error in OpenID4vBLE: \(error.description)")
        self.onError?(error.description, error.code)
    }
}

enum ExceptionType {
    case walletException
    case verifierException
}
