import XCTest
import Foundation
import RepoPromptRemoteProtocol
@testable import RepoPromptRemote

final class RemoteReadOnlyClientTests: XCTestCase {
    func testChatListProjectionUsesPersistedWorkspaceForSavedSession() {
        let savedWorkspaceID = "saved-workspace"
        let snapshotWorkspaceID = "active-workspace"
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 100)
        let historyEntry = RemoteHistoryEntry(
            id: sessionID,
            workspaceID: savedWorkspaceID,
            sessionName: "Saved chat",
            lastActivityAt: now,
            turnCount: 12,
            runState: .completed
        )
        let liveSession = SessionRow(RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: snapshotWorkspaceID,
            sessionName: "Live chat title",
            runState: .working,
            lastUpdatedAt: now.addingTimeInterval(10),
            isLive: true
        ))
        let newLiveSession = SessionRow(RemoteSessionSummary(
            sessionID: UUID(),
            workspaceID: snapshotWorkspaceID,
            sessionName: "New live chat",
            runState: .working,
            lastUpdatedAt: now.addingTimeInterval(20),
            isLive: true
        ))

        let savedChats = RemoteChatListProjection.project(
            historyEntries: [historyEntry],
            sessions: [liveSession, newLiveSession],
            workspaceID: savedWorkspaceID
        )
        XCTAssertEqual(savedChats.map(\.id), [sessionID])
        XCTAssertEqual(savedChats.first?.workspaceID, savedWorkspaceID)
        XCTAssertEqual(savedChats.first?.title, "Live chat title")
        XCTAssertEqual(savedChats.first?.runState, .working)
        XCTAssertEqual(savedChats.first?.turnCount, 12)

        let activeChats = RemoteChatListProjection.project(
            historyEntries: [historyEntry],
            sessions: [liveSession, newLiveSession],
            workspaceID: snapshotWorkspaceID
        )
        XCTAssertEqual(activeChats.map(\.id), [newLiveSession.id])
    }

    func testReducerAppliesOrderedSessionEventAndRejectsGap() {
        let desktopID = "desktop-1"
        let sessionID = UUID()
        let snapshot = RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: desktopID,
                displayName: "Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            eventCursor: 4
        )
        var reducer = RemoteSnapshotReducer()
        reducer.replace(with: snapshot)

        let event = RemoteEvent(
            desktopInstanceID: desktopID,
            sequence: 5,
            type: .sessionUpdated,
            payload: .session(
                RemoteSessionSummary(
                    sessionID: sessionID,
                    workspaceID: "workspace-1",
                    runState: .working,
                    isLive: true
                )
            )
        )

        XCTAssertEqual(reducer.apply(event), .applied)
        XCTAssertEqual(reducer.snapshot?.eventCursor, 5)
        XCTAssertEqual(reducer.snapshot?.sessions.first?.sessionID, sessionID)
        XCTAssertEqual(reducer.apply(event), .duplicate)

        let gap = RemoteEvent(
            desktopInstanceID: desktopID,
            sequence: 7,
            type: .runProgressed,
            payload: .empty
        )
        XCTAssertEqual(reducer.apply(gap), .snapshotRequired)
    }

    func testReducerTranscriptRevisionSignalOnlyAdvancesAuthoritativeCursor() {
        let desktopID = "desktop-1"
        let sessionID = UUID()
        let session = RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: "workspace-1",
            transcriptRevision: 1,
            runState: .working,
            isLive: true
        )
        var reducer = RemoteSnapshotReducer()
        reducer.replace(with: RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: desktopID,
                displayName: "Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            sessions: [session],
            eventCursor: 8
        ))

        let event = RemoteEvent(
            desktopInstanceID: desktopID,
            sequence: 9,
            type: .transcriptItemsAppended,
            sessionID: sessionID,
            payload: .text("2")
        )
        XCTAssertEqual(reducer.apply(event), .applied)
        XCTAssertEqual(reducer.cursor, 9)
        XCTAssertEqual(reducer.snapshot?.sessions.first?.transcriptRevision, 1)
    }

    func testReducerAppliesWorkspaceAndRemovesResolvedAttention() {
        let desktopID = "desktop-1"
        let sessionID = UUID()
        let attentionID = UUID()
        let snapshot = RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: desktopID,
                displayName: "Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            workspaces: [RemoteWorkspaceSummary(workspaceID: "workspace-1", name: "Old", isOpen: false)],
            attentionItems: [RemoteAttentionItem(id: attentionID, kind: .agentNeedsInput, sessionID: sessionID, title: "Input")],
            eventCursor: 1
        )
        var reducer = RemoteSnapshotReducer()
        reducer.replace(with: snapshot)

        XCTAssertEqual(
            reducer.apply(RemoteEvent(
                desktopInstanceID: desktopID,
                sequence: 2,
                type: .workspaceReady,
                payload: .workspace(RemoteWorkspaceSummary(workspaceID: "workspace-1", name: "New", isOpen: true))
            )),
            .applied
        )
        XCTAssertEqual(reducer.snapshot?.workspaces.first?.name, "New")

        XCTAssertEqual(
            reducer.apply(RemoteEvent(
                desktopInstanceID: desktopID,
                sequence: 3,
                type: .interactionResolved,
                payload: .attentionRemoved(attentionID)
            )),
            .applied
        )
        XCTAssertTrue(reducer.snapshot?.attentionItems.isEmpty == true)
    }

    func testReducerAppliesCatalogChange() {
        let desktopID = "desktop-1"
        var reducer = RemoteSnapshotReducer()
        reducer.replace(with: RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: desktopID,
                displayName: "Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            eventCursor: 1
        ))

        let event = RemoteEvent(
            desktopInstanceID: desktopID,
            sequence: 2,
            type: .catalogChanged,
            payload: .catalog(RemoteCatalogPayload(
                workflows: [RemoteWorkflowDescriptor(id: "builtin-review", displayName: "Review", isBuiltIn: true)],
                agents: [RemoteAgentDescriptor(id: "codexExec", displayName: "Codex CLI", isAvailable: true)]
            ))
        )

        XCTAssertEqual(reducer.apply(event), .applied)
        XCTAssertEqual(reducer.snapshot?.workflowCatalog.first?.displayName, "Review")
        XCTAssertEqual(reducer.snapshot?.agentCatalog.first?.id, "codexExec")
    }
}
