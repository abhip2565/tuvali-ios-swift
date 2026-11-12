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

    /// iOS cannot advertise service data, so wallets tell verifiers apart by local name.
    /// A fixed name would make nearby verifiers look identical, so every advertisement
    /// uses a fresh random name and `advIdentifier` is not used on iOS.
    @available(iOS 13.0, *)
    public func startAdvertisement(_ advIdentifier: String) -> String {
        bleCommunicator?.stop()
        let name = Self.freshAdvertisementName()
        let communicator = VerifierBleCommunicator(eventEmitter: eventEmitter)
        bleCommunicator = communicator
        communicator.startAdvertisement(advIdentifier: name)
        return Self.connectionURI(name: name, publicKey: communicator.publicKey)
    }

    /// 6 random bytes as base64url: 8 characters. iOS shortens the advertised local name
    /// to 8 characters to make room for its own manufacturer data, so a longer name would
    /// reach wallets truncated and never match the name in the QR.
    static func freshAdvertisementName() -> String {
        let bytes = Data((0..<6).map { _ in UInt8.random(in: .min ... .max) })
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func connectionURI(name: String, publicKey: Data) -> String {
        var components = URLComponents()
        components.scheme = "OPENID4VP"
        components.host = "connect"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "key", value: publicKey.toHex())
        ]
        return components.string!
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
