import Foundation

@objc(Verifier)
public class Verifier: NSObject {
    @available(iOS 13.0, *)
    private var bleCommunicator: VerifierBleCommunicator?
    private let eventEmitter = EventEmitter.sharedInstance

    public override init() {
        super.init()
        ErrorHandler.sharedInstance.setOnError(onError: self.handleError)
    }

    @available(iOS 13.0, *)
    public func startAdvertisement(_ advIdentifier: String) -> String {
        bleCommunicator?.stop()
        let communicator = VerifierBleCommunicator(eventEmitter: eventEmitter)
        bleCommunicator = communicator
        communicator.startAdvertisement(advIdentifier: advIdentifier)
        let encodedName = advIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? advIdentifier
        return "OPENID4VP://connect?name=\(encodedName)&key=\(communicator.publicKey.toHex())"
    }

    @available(iOS 13.0, *)
    public func disconnect() {
        bleCommunicator?.stop()
        bleCommunicator = nil
    }

    @available(iOS 13.0, *)
    public func sendVerificationStatus(_ status: VerificationStatusEvent.VerificationStatus) {
        bleCommunicator?.notifyVerificationStatus(accepted: status == .ACCEPTED)
    }

    public func subscribe(_ listener: @escaping (Event) -> Void) {
        eventEmitter.addListener(listener: listener)
    }

    public func unsubscribe() {
        eventEmitter.removeListeners()
    }

    func getModuleName(completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(["iOS Verifier"])
        }
    }

    @objc
    static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    @objc
    func constantsToExport() -> [AnyHashable: Any] {
        return [
            "name": "verifier",
            "platform": "ios"
        ]
    }

    private func handleError(_ message: String, _ code: String) {
        eventEmitter.emitErrorEvent(message: message, code: code)
    }
}
