import Foundation
import RepoPromptRemoteProtocol

enum RemoteSnapshotApplyResult: Equatable {
    case applied
    case duplicate
    case snapshotRequired
}

/// Applies the authoritative snapshot/event contract without allowing an event
/// gap or duplicate to manufacture state on the phone.
struct RemoteSnapshotReducer {
    private(set) var snapshot: RemoteSnapshot?
    private var seenEventIDs: Set<UUID> = []

    var cursor: UInt64 { snapshot?.eventCursor ?? 0 }

    mutating func replace(with snapshot: RemoteSnapshot) {
        self.snapshot = snapshot
        seenEventIDs.removeAll(keepingCapacity: true)
    }

    mutating func apply(_ event: RemoteEvent) -> RemoteSnapshotApplyResult {
        guard let snapshot else { return .snapshotRequired }
        guard event.desktopInstanceID == snapshot.desktop.instanceID else { return .snapshotRequired }
        if seenEventIDs.contains(event.eventID) || event.sequence <= snapshot.eventCursor {
            return .duplicate
        }
        guard event.sequence == snapshot.eventCursor + 1 else { return .snapshotRequired }

        let workspaces = snapshot.workspaces
        var updatedWorkspaces = workspaces
        var sessions = snapshot.sessions
        var attentionItems = snapshot.attentionItems
        var authorization = snapshot.authorization
        var workflowCatalog = snapshot.workflowCatalog
        var agentCatalog = snapshot.agentCatalog
        var agentCatalogMetadata = snapshot.agentCatalogMetadata

        switch event.payload {
        case let .workspace(value):
            if let index = updatedWorkspaces.firstIndex(where: { $0.workspaceID == value.workspaceID }) {
                updatedWorkspaces[index] = value
            } else {
                updatedWorkspaces.append(value)
            }
        case let .session(value):
            if let index = sessions.firstIndex(where: { $0.sessionID == value.sessionID }) {
                sessions[index] = value
            } else {
                sessions.append(value)
            }
        case let .attention(value):
            if let index = attentionItems.firstIndex(where: { $0.id == value.id }) {
                attentionItems[index] = value
            } else {
                attentionItems.append(value)
            }
        case let .attentionRemoved(id):
            attentionItems.removeAll { $0.id == id }
        case let .authorization(value):
            authorization = value
        case let .catalog(value):
            workflowCatalog = value.workflows
            agentCatalog = value.agents
            agentCatalogMetadata = value.metadata
        case .empty, .text:
            break
        }

        self.snapshot = RemoteSnapshot(
            protocolVersion: snapshot.protocolVersion,
            desktop: snapshot.desktop,
            connection: snapshot.connection,
            authorization: authorization,
            workspaces: updatedWorkspaces,
            sessions: sessions,
            attentionItems: attentionItems,
            workflowCatalog: workflowCatalog,
            agentCatalog: agentCatalog,
            agentCatalogMetadata: agentCatalogMetadata,
            eventCursor: event.sequence,
            transcriptRevisionEpoch: snapshot.transcriptRevisionEpoch
        )
        seenEventIDs.insert(event.eventID)
        if seenEventIDs.count > 2048 {
            seenEventIDs.removeAll(keepingCapacity: true)
        }
        return .applied
    }
}
