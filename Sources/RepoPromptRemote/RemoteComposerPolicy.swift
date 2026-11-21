import RepoPromptRemoteProtocol

struct RemoteComposerPolicy: Equatable {
    let primaryOperation: RemoteCommandOperation?
    let primaryLabel: String
    let canCancel: Bool
    let isInteractionBlocking: Bool

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
