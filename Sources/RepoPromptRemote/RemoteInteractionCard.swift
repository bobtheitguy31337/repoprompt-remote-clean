import SwiftUI
import RepoPromptRemoteProtocol

struct RemoteInteractionCard: View {
    @EnvironmentObject private var model: RemoteAppModel

    let session: SessionRow
    let interaction: RemoteInteractionSummary

    @State private var response = ""
    @State private var pendingCommandID: UUID?

    private var isApproval: Bool { interaction.kind == .approval }
    private var isSecure: Bool {
        interaction.requiresSecureEntry || interaction.kind == .secretInput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                interaction.title ?? (isApproval ? "Approval required" : "Your response is needed"),
                systemImage: isApproval ? "hand.raised.fill" : (isSecure ? "lock.fill" : "questionmark.circle.fill")
            )
            .font(.headline)
            .foregroundStyle(Color.remoteWarmOrange)

            if let prompt = interaction.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if let reason = interaction.responseUnavailableReason {
                Label(reason, systemImage: "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isApproval {
                HStack {
                    Button("Decline", role: .destructive) { submit(decision: "decline") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Approve") { submit(decision: "approve") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Group {
                    if isSecure {
                        SecureField("Secure response", text: $response)
                            .privacySensitive()
                            .accessibilityHint("The value is sent once and is not stored in the app transcript.")
                    } else {
                        TextField("Response", text: $response, axis: .vertical)
                            .lineLimit(1...5)
                    }
                }
                .textFieldStyle(.roundedBorder)

                HStack {
                    if isSecure {
                        Label("Sent once; never added to chat", systemImage: "lock.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .privacySensitive()
                    }
                    Spacer()
                    Button("Send") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(14)
        .background(Color.remoteWarmOrange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.remoteWarmOrange.opacity(0.35), lineWidth: 1)
        }
        .disabled(pendingCommandID != nil)
        .opacity(pendingCommandID == nil ? 1 : 0.65)
        .onChange(of: model.commandActivity) { _, activity in
            guard let completion = activity.completion(for: pendingCommandID) else { return }
            pendingCommandID = nil
            if completion.outcome == .accepted || isSecure { response = "" }
        }
    }

    private func submit(decision: String? = nil) {
        guard pendingCommandID == nil, let interactionID = UUID(uuidString: interaction.id) else { return }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingCommandID = model.respond(
            sessionID: session.id,
            workspaceID: session.workspaceID,
            interactionID: interactionID,
            decision: decision,
            message: !isApproval && !isSecure ? trimmed : nil,
            secret: !isApproval && isSecure ? response : nil
        )
    }
}
