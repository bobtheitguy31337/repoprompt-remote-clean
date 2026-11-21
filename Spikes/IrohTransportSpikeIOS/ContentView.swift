import SwiftUI
import UIKit

struct IrohSpikeContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: IrohSpikeModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Ephemeral Swift-owned test identity") {
                    SecureField("64-hex secret", text: $model.secretHex)
                        .font(.caption.monospaced())
                        .privacySensitive()
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Enable public relay fallback", isOn: $model.relayEnabled)
                    HStack {
                        Button("Generate") { model.generateSecret() }
                        Button(model.running ? "Restart" : "Start") {
                            Task { await model.start() }
                        }
                        Button("Stop") { Task { await model.stop() } }
                    }
                    Text("The harness never persists or prints the secret. Re-enter the same value after relaunch to verify endpoint-ID stability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Local endpoint") {
                    LabeledContent("Endpoint ID") {
                        Text(model.endpointID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    TextEditor(text: .constant(model.addressJSON))
                        .font(.caption2.monospaced())
                        .frame(minHeight: 100)
                    Button("Copy address JSON") {
                        UIPasteboard.general.string = model.addressJSON
                    }
                }

                Section("Connect to peer") {
                    TextField("Paste peer address JSON", text: $model.remoteAddressJSON, axis: .vertical)
                        .font(.caption2.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect") { Task { await model.connect() } }
                    LabeledContent("Iroh paths") {
                        Text(model.pathSummary).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    Button("Refresh path/address") { model.refreshDiagnostics() }
                }

                Section("Opaque framed echo") {
                    TextField("Message", text: $model.message)
                    TextField("Count (1…10000)", text: $model.messageCount)
                        .keyboardType(.numberPad)
                    Button("Send echoes") { Task { await model.sendEchoes() } }
                    Button("Verify >1 MiB rejection") {
                        Task { await model.verifyOversizedFrame() }
                    }
                }

                Section("Status") {
                    Text(model.status).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("Iroh Transport Spike")
        }
        .overlay {
            if scenePhase != .active {
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
    }
}
