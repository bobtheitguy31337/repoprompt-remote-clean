import Foundation
import RepoPromptRemoteProtocol

struct RemoteSessionUnseenState: Equatable {
    var attentionRunState: RemoteRunState?
    var hasUnreadNarrative: Bool
    var markedAt: Date

    init(
        attentionRunState: RemoteRunState? = nil,
        hasUnreadNarrative: Bool = false,
        markedAt: Date = Date()
    ) {
        self.attentionRunState = attentionRunState
        self.hasUnreadNarrative = hasUnreadNarrative
        self.markedAt = markedAt
    }

    var isEmpty: Bool {
        attentionRunState == nil && !hasUnreadNarrative
    }
}

enum RemoteTranscriptRevisionDisposition: Equatable {
    case ignore
    case recordOnly
    case refreshLatest
    case markUnread
}

enum RemoteTranscriptRevisionReconciliation {
    static func disposition(
        incomingRevision: UInt64,
        knownRevision: UInt64?,
        loadedRevision: UInt64?,
        isVisible: Bool
    ) -> RemoteTranscriptRevisionDisposition {
        guard incomingRevision > (knownRevision ?? 0) else { return .ignore }
        if isVisible {
            if let loadedRevision, incomingRevision <= loadedRevision { return .recordOnly }
            return .refreshLatest
        }
        return .markUnread
    }

    static func isEpochReset(previous: RemoteSnapshot?, current: RemoteSnapshot) -> Bool {
        guard let previous else { return false }
        if previous.transcriptRevisionEpoch != current.transcriptRevisionEpoch,
           previous.transcriptRevisionEpoch != nil || current.transcriptRevisionEpoch != nil
        {
            return true
        }
        if previous.desktop.instanceID != current.desktop.instanceID
            || current.eventCursor < previous.eventCursor
        {
            return true
        }
        // Older CE builds have no epoch. An authoritative per-session decrease
        // is the only explicit restart signal they can provide.
        guard current.transcriptRevisionEpoch == nil else { return false }
        let previousRevisions = Dictionary(uniqueKeysWithValues: previous.sessions.compactMap { session in
            session.transcriptRevision.map { (session.sessionID, $0) }
        })
        return current.sessions.contains { session in
            guard let currentRevision = session.transcriptRevision,
                  let previousRevision = previousRevisions[session.sessionID]
            else { return false }
            return currentRevision < previousRevision
        }
    }
}

enum RemoteSessionUnseenProjection {
    static func reconcileRunTransitions(
        previous: [RemoteSessionSummary],
        current: [RemoteSessionSummary],
        existing: [UUID: RemoteSessionUnseenState],
        visibleSessionID: UUID?,
        isInitial: Bool,
        now: Date = Date()
    ) -> [UUID: RemoteSessionUnseenState] {
        let currentIDs = Set(current.map(\.sessionID))
        var result = existing.filter { currentIDs.contains($0.key) }
        guard !isInitial else { return result }
        let previousByID = previous.reduce(into: [UUID: RemoteSessionSummary]()) { values, session in
            if let old = values[session.sessionID], old.lastUpdatedAt >= session.lastUpdatedAt { return }
            values[session.sessionID] = session
        }
        for session in current where session.sessionID != visibleSessionID {
            guard let previousState = previousByID[session.sessionID]?.runState,
                  previousState != session.runState,
                  createsAttention(session.runState)
            else { continue }
            var unseen = result[session.sessionID] ?? RemoteSessionUnseenState(markedAt: now)
            unseen.attentionRunState = session.runState
            unseen.markedAt = now
            result[session.sessionID] = unseen
        }
        return result
    }

    static func markingNarrative(
        sessionID: UUID,
        in existing: [UUID: RemoteSessionUnseenState],
        now: Date = Date()
    ) -> [UUID: RemoteSessionUnseenState] {
        var result = existing
        var unseen = result[sessionID] ?? RemoteSessionUnseenState(markedAt: now)
        unseen.hasUnreadNarrative = true
        unseen.markedAt = now
        result[sessionID] = unseen
        return result
    }

    static func acknowledging(
        sessionID: UUID,
        in existing: [UUID: RemoteSessionUnseenState]
    ) -> [UUID: RemoteSessionUnseenState] {
        var result = existing
        result[sessionID] = nil
        return result
    }

    private static func createsAttention(_ state: RemoteRunState) -> Bool {
        switch state {
        case .waitingForInput, .blocked, .completed, .failed: true
        case .idle, .opening, .working, .cancelled: false
        }
    }
}

enum RemoteSessionStatusPresentation: Equatable {
    case idle
    case opening
    case working
    case waiting(unseen: Bool)
    case blocked(unseen: Bool)
    case completed(unseen: Bool)
    case failed(unseen: Bool)
    case cancelled
    case unreadNarrative
}

struct RemoteSessionNavigationRow: Identifiable, Equatable {
    let item: RemoteChatListItem
    let depth: Int
    let hasChildren: Bool
    let validParentID: UUID?
    let status: RemoteSessionStatusPresentation
    let unseenDescendantCount: Int

    var id: UUID { item.id }
}

/// Pure mobile navigation projection derived from authoritative session lineage
/// plus ephemeral phone-only unseen state.
enum RemoteSessionNavigationProjection {
    static func project(
        items: [RemoteChatListItem],
        sessions: [RemoteSessionSummary],
        selectedSessionID: UUID?,
        unseenBySessionID: [UUID: RemoteSessionUnseenState]
    ) -> [RemoteSessionNavigationRow] {
        let deduplicated = deduplicate(items)
        guard let workspaceID = deduplicated.first?.workspaceID else { return [] }
        let workspaceItems = deduplicated.filter { $0.workspaceID == workspaceID }
        let itemsByID = Dictionary(uniqueKeysWithValues: workspaceItems.map { ($0.id, $0) })
        let sessionByID = sessions
            .filter { itemsByID[$0.sessionID] != nil }
            .reduce(into: [UUID: RemoteSessionSummary]()) { result, session in
                guard session.workspaceID == workspaceID else { return }
                if let existing = result[session.sessionID], existing.lastUpdatedAt >= session.lastUpdatedAt {
                    return
                }
                result[session.sessionID] = session
            }

        var parentByID: [UUID: UUID] = [:]
        for (id, item) in itemsByID {
            guard let parentID = sessionByID[id]?.parentSessionID,
                  parentID != id,
                  let parent = itemsByID[parentID],
                  parent.workspaceID == item.workspaceID
            else { continue }
            parentByID[id] = parentID
        }

        let cycleMembers = cyclicSessionIDs(parentByID: parentByID, allIDs: Set(itemsByID.keys))
        let originalParents = parentByID
        for id in itemsByID.keys {
            var visited: Set<UUID> = []
            var ancestor: UUID? = id
            var reachesCycle = false
            while let current = ancestor, visited.insert(current).inserted {
                if cycleMembers.contains(current) {
                    reachesCycle = true
                    break
                }
                ancestor = originalParents[current]
            }
            if reachesCycle {
                // Match desktop fallback: reject every candidate edge whose
                // ancestor walk reaches malformed cyclic lineage.
                parentByID[id] = nil
            }
        }

        var childrenByID: [UUID: [UUID]] = [:]
        for (childID, parentID) in parentByID {
            childrenByID[parentID, default: []].append(childID)
        }
        for parentID in childrenByID.keys {
            childrenByID[parentID]?.sort { orderedBefore($0, $1, itemsByID: itemsByID) }
        }

        var subtreeActivityCache: [UUID: Date] = [:]
        func subtreeActivity(_ id: UUID) -> Date {
            if let cached = subtreeActivityCache[id] { return cached }
            var latest = itemsByID[id]?.lastActivityAt ?? .distantPast
            for child in childrenByID[id] ?? [] {
                latest = max(latest, subtreeActivity(child))
            }
            subtreeActivityCache[id] = latest
            return latest
        }

        var descendantUnseenCache: [UUID: Int] = [:]
        func unseenCountIncludingSelf(_ id: UUID) -> Int {
            if let cached = descendantUnseenCache[id] { return cached }
            let own = unseenBySessionID[id]?.isEmpty == false ? 1 : 0
            let total = own + (childrenByID[id] ?? []).reduce(0) { $0 + unseenCountIncludingSelf($1) }
            descendantUnseenCache[id] = total
            return total
        }

        let roots = itemsByID.keys.filter { parentByID[$0] == nil }.sorted {
            let lhsActivity = subtreeActivity($0)
            let rhsActivity = subtreeActivity($1)
            if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
            return $0.uuidString < $1.uuidString
        }

        var rows: [RemoteSessionNavigationRow] = []
        func emit(_ id: UUID, depth: Int) {
            guard let item = itemsByID[id] else { return }
            let children = childrenByID[id] ?? []
            let session = sessionByID[id]
            let unseen = unseenBySessionID[id]
            rows.append(RemoteSessionNavigationRow(
                item: item,
                depth: depth,
                hasChildren: !children.isEmpty,
                validParentID: parentByID[id],
                status: status(runState: session?.runState ?? item.runState, unseen: unseen),
                unseenDescendantCount: children.reduce(0) { $0 + unseenCountIncludingSelf($1) }
            ))
            for child in children {
                emit(child, depth: depth + 1)
            }
        }
        for root in roots {
            emit(root, depth: 0)
        }

        // Selection is intentionally not used for ordering. Keeping it as an
        // input documents that recomputation must not move the selected row.
        _ = selectedSessionID
        return rows
    }

    static func stableSelectionID(
        current: UUID?,
        rows: [RemoteSessionNavigationRow]
    ) -> UUID? {
        guard let current, rows.contains(where: { $0.id == current }) else { return nil }
        return current
    }

    private static func deduplicate(_ items: [RemoteChatListItem]) -> [RemoteChatListItem] {
        Array(items.reduce(into: [UUID: RemoteChatListItem]()) { result, item in
            if let existing = result[item.id] {
                if orderedBefore(item, existing) { result[item.id] = item }
            } else {
                result[item.id] = item
            }
        }.values)
    }

    private static func orderedBefore(_ lhs: RemoteChatListItem, _ rhs: RemoteChatListItem) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func orderedBefore(
        _ lhs: UUID,
        _ rhs: UUID,
        itemsByID: [UUID: RemoteChatListItem]
    ) -> Bool {
        guard let lhsItem = itemsByID[lhs], let rhsItem = itemsByID[rhs] else {
            return lhs.uuidString < rhs.uuidString
        }
        return orderedBefore(lhsItem, rhsItem)
    }

    private static func cyclicSessionIDs(
        parentByID: [UUID: UUID],
        allIDs: Set<UUID>
    ) -> Set<UUID> {
        var cycleMembers: Set<UUID> = []
        var globallyVisited: Set<UUID> = []

        for start in allIDs where !globallyVisited.contains(start) {
            var path: [UUID] = []
            var indexByID: [UUID: Int] = [:]
            var current: UUID? = start
            while let id = current, !globallyVisited.contains(id) {
                if let cycleStart = indexByID[id] {
                    cycleMembers.formUnion(path[cycleStart...])
                    break
                }
                indexByID[id] = path.count
                path.append(id)
                current = parentByID[id]
            }
            globallyVisited.formUnion(path)
        }
        return cycleMembers
    }

    private static func status(
        runState: RemoteRunState,
        unseen: RemoteSessionUnseenState?
    ) -> RemoteSessionStatusPresentation {
        switch runState {
        case .opening: return .opening
        case .working: return .working
        default: break
        }

        switch unseen?.attentionRunState {
        case .failed?: return .failed(unseen: true)
        case .waitingForInput?: return .waiting(unseen: true)
        case .blocked?: return .blocked(unseen: true)
        case .completed?: return .completed(unseen: true)
        default: break
        }
        if unseen?.hasUnreadNarrative == true { return .unreadNarrative }

        switch runState {
        case .idle: return .idle
        case .opening: return .opening
        case .working: return .working
        case .waitingForInput: return .waiting(unseen: false)
        case .blocked: return .blocked(unseen: false)
        case .completed: return .completed(unseen: false)
        case .failed: return .failed(unseen: false)
        case .cancelled: return .cancelled
        }
    }
}
