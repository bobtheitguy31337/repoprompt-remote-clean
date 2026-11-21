import RepoPromptRemoteProtocol

struct RemoteComposerPolicy: Equatable {
    let primaryOperation: RemoteCommandOperation?
    let primaryLabel: String
    let canCancel: Bool
    let isInteractionBlocking: Bool

    static let newChat = Self(primaryOperation: .startRun, primaryLabel: "Send", canCancel: false, isInteractionBlocking: false)

    var canAttach: Bool { primaryOperation != nil && !canCancel }

    static func resolve(
        runState: RemoteRunState,
        pendingInteraction: RemoteInteractionSummary?
    ) -> Self {
        let canCancel: Bool
        switch runState {
        case .opening, .working, .waitingForInput, .blocked:
            canCancel = true
        case .idle, .completed, .failed, .cancelled:
            canCancel = false
        }

        guard pendingInteraction == nil else {
            return Self(
                primaryOperation: nil,
                primaryLabel: "Respond above",
                canCancel: canCancel,
                isInteractionBlocking: true
            )
        }

        switch runState {
        case .opening, .working:
            return Self(
                primaryOperation: .steer,
                primaryLabel: "Steer",
                canCancel: canCancel,
                isInteractionBlocking: false
            )
        case .waitingForInput, .blocked, .idle:
            return Self(
                primaryOperation: .followUp,
                primaryLabel: "Reply",
                canCancel: canCancel,
                isInteractionBlocking: false
            )
        case .completed, .failed, .cancelled:
            return Self(
                primaryOperation: .resume,
                primaryLabel: "Resume",
                canCancel: canCancel,
                isInteractionBlocking: false
            )
        }
    }
}

/// A fresh chat reflects the Mac's default until the user chooses a model or effort.
enum RemoteLaunchSelection {
    static func resolve(
        draft: RemoteAgentSelection?,
        desktopDefault: RemoteAgentSelection?,
        agents: [RemoteAgentDescriptor]
    ) -> RemoteAgentSelection? {
        for selection in [draft, desktopDefault].compactMap({ $0 }) {
            guard let agent = agents.first(where: { $0.id == selection.agentID && $0.isAvailable }),
                  let model = agent.modelDescriptors?.first(where: { $0.id == selection.modelID && $0.isAvailable })
            else { continue }
            let requested = model.reasoningEfforts.first { $0.id == selection.reasoningEffort }?.id
            let fallback = model.reasoningEfforts.first { $0.id == model.defaultReasoningEffortID }?.id
            return RemoteAgentSelection(
                agentID: agent.id,
                modelID: model.id,
                reasoningEffort: requested ?? fallback
            )
        }
        return nil
    }

    static func modelLabel(_ displayName: String) -> String {
        displayName.replacingOccurrences(of: #"(?i)\bsol$"#, with: "SOL", options: .regularExpression)
    }
}
