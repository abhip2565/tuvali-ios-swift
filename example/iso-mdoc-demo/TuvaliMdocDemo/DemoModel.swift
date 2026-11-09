import CoreImage.CIFilterBuiltins
import Security
import SwiftCBOR
import SwiftUI
import ios_tuvali_library

func emptyDeviceResponse(docTypes: [String]) -> Data {
    let errors: [CBOR] = Set(docTypes).sorted().map { .map([.utf8String($0): .unsignedInt(0)]) }
    let response: CBOR = .map([
        "version": "1.0",
        "documentErrors": .array(errors),
        "status": 0,
    ])
    return Data(response.encode())
}

@MainActor
final class DemoModel: ObservableObject, MdocCallbacks {
    @Published private(set) var running = false
    @Published private(set) var status = "Ready"
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var request: MdocRequest?
    @Published private(set) var log: [String] = []
    @Published private(set) var rootName = "None — signed readers will be unverified"

    private let presenter = MdocPresenter()
    private var task: Task<Void, Never>?
    private var decision: CheckedContinuation<MdocSharingDecision, Error>?
    private var trustedRoots: [Data] = []

    func start() {
        guard !running else { return }
        running = true
        log = []
        task = Task {
            defer {
                running = false
                qrImage = nil
                request = nil
                task = nil
            }
            do {
                let result = try await presenter.present(
                    options: MdocPresentationOptions(trustedReaderRoots: trustedRoots), callbacks: self
                )
                switch result {
                case let .completed(confirmed):
                    record("Response sent. Reader ended session: \(confirmed ? "yes" : "no").")
                case .declined: record("Declined")
                case .cancelled: record("Cancelled")
                case let .failed(failure, detail): record("Failed: \(failure). \(detail ?? "")")
                }
            } catch is CancellationError {
                record("Cancelled")
            } catch {
                record("Could not start: \(error)")
            }
        }
    }

    func cancel() { presenter.cancel() }

    func choose(send: Bool) {
        guard let pending = decision, let request = request else { return }
        decision = nil
        self.request = nil
        guard send else { return pending.resume(returning: .decline) }
        Task { @MainActor in
            do {
                let answer = try await DemoWallet.answer(request)
                record("Sharing \(answer.sharedElements.isEmpty ? "no elements" : answer.sharedElements.joined(separator: ", ")) (\(answer.deviceResponse.count) bytes, built by OpenID4VP)")
                pending.resume(returning: .send(deviceResponse: answer.deviceResponse))
            } catch {
                record("Could not build the response: \(error); declining")
                pending.resume(returning: .decline)
            }
        }
    }

    func loadRoot(_ url: URL) {
        guard !running else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let data = try Data(contentsOf: url)
            guard SecCertificateCreateWithData(nil, data as CFData) != nil else {
                record("Select a DER-encoded X.509 root certificate.")
                return
            }
            trustedRoots = [data]
            rootName = url.lastPathComponent
        } catch { record("Root import failed: \(error.localizedDescription)") }
    }

    func onQrReady(_ qrText: String) async throws {
        try Task.checkCancellation()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(qrText.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                                                   from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else {
            throw CocoaError(.coderInvalidValue)
        }
        qrImage = UIImage(cgImage: image)
        record("Scan the QR with an ISO mdoc reader.")
    }

    nonisolated func onProgress(_ progress: MdocProgress) {
        Task { @MainActor [weak self] in
            guard let self = self, self.running else { return }
            switch progress {
            case .waitingForReader: self.record("Waiting for reader")
            case .connected:
                self.qrImage = nil
                self.record("Connected")
            case .requestReceived: self.record("Request received")
            case .sendingResponse: self.record("Sending response")
            }
        }
    }

    func onRequest(_ request: MdocRequest) async throws -> MdocSharingDecision {
        try Task.checkCancellation()
        self.request = request
        defer { self.request = nil }
        record("Request #\(request.requestNumber): \(request.documents.count) document(s)")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { decision = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                let pending = self?.decision
                self?.decision = nil
                pending?.resume(throwing: CancellationError())
            }
        }
    }

    func record(_ message: String) {
        status = message
        log.append("\(Date().formatted(date: .omitted, time: .standard)) \(message)")
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }
}

func describeTrust(_ trust: ReaderTrustStatus) -> String {
    switch trust {
    case .notSigned: return "Not signed"
    case let .verified(name): return "Verified: \(name ?? "unnamed reader")"
    case let .unverified(name, reason): return "Unverified: \(name ?? "unnamed reader"). \(reason)"
    case let .invalid(reason): return "INVALID: \(reason)"
    }
}
