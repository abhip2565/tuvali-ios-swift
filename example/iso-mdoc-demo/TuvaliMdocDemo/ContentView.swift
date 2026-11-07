import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = DemoModel()
    @State private var importingRoot = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Test QR engagement, BLE and encrypted mdoc sessions. Sharing sends the requested fields of a built-in test mDL (self-signed test issuer), built and signed with OpenID4VP.")
                        .font(.subheadline)
                    Text(model.status).font(.headline).accessibilityIdentifier("sessionStatus")
                    if model.running {
                        Button("Cancel", role: .destructive) { model.cancel() }
                    } else {
                        Button("Start ISO mdoc presentation") { model.start() }
                            .accessibilityIdentifier("startPresentation")
                    }
                }
                if let image = model.qrImage {
                    Section("Scan with your reader") {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .padding(20).background(.white)
                            .accessibilityLabel("mdoc engagement QR code")
                    }
                }
                if let request = model.request {
                    Section("Request #\(request.requestNumber)") {
                        ForEach(Array(request.documents.enumerated()), id: \.offset) { _, document in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(document.docType).font(.headline)
                                Text(describeTrust(document.readerTrust)).font(.subheadline)
                                ForEach(document.nameSpaces.keys.sorted(), id: \.self) { namespace in
                                    Text(namespace).font(.caption).foregroundStyle(.secondary)
                                    ForEach((document.nameSpaces[namespace] ?? [:]).keys.sorted(), id: \.self) { element in
                                        Text("\(element) · retain: \(document.nameSpaces[namespace]?[element] == true ? "yes" : "no")")
                                    }
                                }
                            }
                        }
                        Button("Share requested test mDL fields") { model.choose(send: true) }
                        Button("Decline", role: .destructive) { model.choose(send: false) }
                    }
                }
                Section("Reader trust root (optional)") {
                    Text(model.rootName).font(.caption)
                    Button("Import DER root certificate") { importingRoot = true }.disabled(model.running)
                }
                Section("Run log") {
                    ShareLink("Share log", item: model.log.joined(separator: "\n"))
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Tuvali mdoc test")
            .fileImporter(isPresented: $importingRoot, allowedContentTypes: [.data]) { result in
                switch result {
                case let .success(url): model.loadRoot(url)
                case let .failure(error): model.record("Import failed: \(error.localizedDescription)")
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background { model.cancel() }
            }
        }
    }
}
