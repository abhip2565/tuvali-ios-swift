import SwiftUI
import ios_tuvali_library
import UIKit

struct ContentView: View {
    @State private var selectedRole: DemoRole = .verifier
    @State private var verifierName = "TUVALI-IOS"
    @State private var verifierURI = ""
    @State private var walletURI = ""
    @State private var payload = "{\"credential\":\"sample-vp\",\"issuedAt\":\"2026-04-25\"}"
    @State private var receivedPayload = "Waiting for wallet data"
    @State private var activityLog: [String] = ["Ready"]

    private let wallet = Wallet()
    private let verifier = Verifier()

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    HeaderView()

                    RoleSwitch(selectedRole: $selectedRole)

                    if selectedRole == .verifier {
                        verifierPanel
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        walletPanel
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }

                    LogPanel(entries: activityLog)
                }
                .padding(20)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: selectedRole)
        .onAppear(perform: subscribeToTuvaliEvents)
    }

    private var verifierPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelTitle(icon: "dot.radiowaves.left.and.right", title: "Verifier Station", subtitle: "Advertise this phone and receive a VP over BLE.")

            LabeledField(title: "Verifier name", text: $verifierName, prompt: "STADONENTRY")

            Button(action: startVerifier) {
                PrimaryButtonLabel(title: "Start verifier", icon: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(PrimaryButtonStyle())

            if !verifierURI.isEmpty {
                URIBlock(title: "Share this URI", value: verifierURI, actionTitle: "Copy URI") {
                    UIPasteboard.general.string = verifierURI
                    appendLog("Verifier URI copied")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Received payload")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(receivedPayload)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(spacing: 12) {
                Button("Accept") {
                    verifier.sendVerificationStatus(.ACCEPTED)
                    appendLog("Verifier sent ACCEPTED")
                }
                .buttonStyle(StatusButtonStyle(tint: .green))

                Button("Reject") {
                    verifier.sendVerificationStatus(.REJECTED)
                    appendLog("Verifier sent REJECTED")
                }
                .buttonStyle(StatusButtonStyle(tint: .red))
            }
        }
        .panelStyle()
    }

    private var walletPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelTitle(icon: "wallet.pass", title: "Wallet Console", subtitle: "Paste a verifier URI, connect, then send encrypted data.")

            LabeledMultilineField(title: "Verifier URI", text: $walletURI, prompt: "OPENID4VP://connect?name=...&key=...")

            HStack(spacing: 12) {
                Button(action: pasteURI) {
                    SecondaryButtonLabel(title: "Paste", icon: "doc.on.clipboard")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button(action: startWallet) {
                    PrimaryButtonLabel(title: "Connect", icon: "link")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            LabeledMultilineField(title: "Payload", text: $payload, prompt: "Credential or VP payload")

            Button(action: sendPayload) {
                PrimaryButtonLabel(title: "Send payload", icon: "paperplane.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button("Disconnect wallet") {
                wallet.disconnect()
                appendLog("Wallet disconnect requested")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .panelStyle()
    }

    private func subscribeToTuvaliEvents() {
        wallet.subscribe(handleEvent)
        verifier.subscribe(handleEvent)
    }

    private func startVerifier() {
        verifierURI = verifier.startAdvertisement(verifierName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "TUVALI-IOS" : verifierName)
        UIPasteboard.general.string = verifierURI
        walletURI = verifierURI
        appendLog("Verifier advertising started")
    }

    private func pasteURI() {
        walletURI = UIPasteboard.general.string ?? walletURI
        appendLog("URI pasted")
    }

    private func startWallet() {
        wallet.startConnection(walletURI)
        appendLog("Wallet connection started")
    }

    private func sendPayload() {
        wallet.send(payload)
        appendLog("Wallet sent payload request")
    }

    private func handleEvent(_ event: Event) {
        DispatchQueue.main.async {
            switch event {
            case is ConnectedEvent:
                appendLog("BLE connected")
            case is SecureChannelEstablishedEvent:
                appendLog("Secure channel established")
            case is DataSentEvent:
                appendLog("Wallet data sent")
            case let dataEvent as DataReceivedEvent:
                receivedPayload = dataEvent.data
                appendLog("Verifier received data: \(dataEvent.totalChunkCount) chunks")
            case let statusEvent as VerificationStatusEvent:
                appendLog("Wallet received status: \(statusEvent.status == .ACCEPTED ? "ACCEPTED" : "REJECTED")")
            case let errorEvent as ErrorEvent:
                appendLog("Error \(errorEvent.code): \(errorEvent.message)")
            case is DisconnectedEvent:
                appendLog("BLE disconnected")
            default:
                appendLog("Event: \(String(describing: type(of: event)))")
            }
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        activityLog.insert("\(formatter.string(from: Date()))  \(message)", at: 0)
        activityLog = Array(activityLog.prefix(8))
    }
}

enum DemoRole: String, CaseIterable, Identifiable {
    case verifier = "Verifier"
    case wallet = "Wallet"

    var id: String { rawValue }
}

struct HeaderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tuvali BLE Lab")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("Run this device as a verifier or wallet and test encrypted local transfer over Bluetooth Low Energy.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.top, 18)
    }
}

struct RoleSwitch: View {
    @Binding var selectedRole: DemoRole

    var body: some View {
        HStack(spacing: 8) {
            ForEach(DemoRole.allCases) { role in
                Button {
                    selectedRole = role
                } label: {
                    Text(role.rawValue)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(selectedRole == role ? .black : .white.opacity(0.78))
                        .background(selectedRole == role ? Color.white : Color.white.opacity(0.1), in: Capsule())
                }
            }
        }
        .padding(6)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

struct PanelTitle: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.white.opacity(0.82))
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
        }
    }
}

struct LabeledMultilineField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.white.opacity(0.82))
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 104)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(prompt)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(18)
                    }
                }
        }
    }
}

struct URIBlock: View {
    let title: String
    let value: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button(actionTitle, action: action)
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

struct LogPanel: View {
    let entries: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session log")
                .font(.headline)
                .foregroundStyle(.white)
            ForEach(entries, id: \.self) { entry in
                Text(entry)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelStyle()
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.02, green: 0.08, blue: 0.13), Color(red: 0.05, green: 0.20, blue: 0.22), Color(red: 0.04, green: 0.04, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color.teal.opacity(0.28))
                    .frame(width: 260, height: 260)
                    .blur(radius: 34)
                    .offset(x: 90, y: -80)
            }
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 80, style: .continuous)
                    .fill(Color.orange.opacity(0.13))
                    .frame(width: 240, height: 240)
                    .rotationEffect(.degrees(22))
                    .blur(radius: 18)
                    .offset(x: -90, y: 120)
            }
    }
}

struct PrimaryButtonLabel: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
    }
}

struct SecondaryButtonLabel: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(Color.white.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct StatusButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(tint.opacity(configuration.isPressed ? 0.46 : 0.74), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding(18)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 18)
    }
}

#Preview {
    ContentView()
}
