# Remote Chat-List Parity: Plan

## Goal

Make the iOS remote chat list feel as responsive and information-dense as the desktop Agent Mode sidebar: newly created or updated chats appear while the app is open, valid parent/child sessions render recursively with safe root fallback, and each row uses the desktop chat-list status-symbol semantics without conflating transport health with chat lifecycle.

The Mac remains authoritative; the remote app consumes the existing snapshot/event contract and must preserve the current selection while marking newly relevant background activity unseen.

## Background

- The desktop sidebar projects persisted/live session metadata through `AgentModeSidebarSessionBuilder`, recursively emits valid parent/child subtrees, rejects cycles/self-links, and promotes unresolved lineage to roots (`repoprompt-ce/Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeSidebarSessionBuilder.swift:492-711`).
- Desktop row symbols combine hierarchy identity and ephemeral unseen/run state: running animation, unseen waiting/completed/failed markers, child arrow, root disclosure, and ordinary root dot (`repoprompt-ce/Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentSessionRows.swift:382-467,515-614`; `AgentModeSidebarUIStore.swift:3-70`).
- Remote global and project chat lists currently iterate `model.sessions` flat and only expose parent/child links in detail metadata (`Sources/RepoPromptRemote/RemoteTabView.swift:140-201,283-382,532-605`).
- The shared session model already carries `parentSessionID`, ordered `childSessionIDs`, `runState`, activity/timestamps, and `isLive` (`Packages/RepoPromptRemoteProtocol/Sources/RepoPromptRemoteProtocol/RemoteModels.swift:314-374`), while `SessionRow` drops some presentation fields during snapshot projection (`Sources/RepoPromptRemote/RemoteAppModel.swift:856-890`).
- Pairing bootstraps an authoritative snapshot. Desktop polls its state at roughly one-second intervals; the phone consumes bounded short-poll SSE replay, retries after 500 ms, and refreshes on cursor gaps/stale replay (`repoprompt-ce/Sources/RepoPrompt/Infrastructure/Remote/RemoteGateway.swift:247-376,632-650`; `Sources/RepoPromptRemote/RemoteAppModel.swift:734-779`; `Sources/RepoPromptRemote/RemoteSnapshotReducer.swift:10-85`).
- Existing tests cover protocol replay and reducer projection, but not SwiftUI list hierarchy, row status precedence, unseen projection, selection stability, or end-to-end live-update latency (`Tests/RepoPromptRemoteTests/RemoteReadOnlyClientTests.swift:6-122`; `Packages/RepoPromptRemoteProtocol/Tests/RepoPromptRemoteProtocolTests/RemoteContractTests.swift:19-204`).
- Planning decisions: match desktop's recursive hierarchy and unresolved-lineage root fallback; copy desktop status-symbol precedence exactly while keeping connection status separate; update in place without changing the current selection and mark new background rows unseen.

## Approach

Extend the existing Mac-authoritative snapshot/event path; do not change the wire schema, add persistence, or introduce a second transport in the default path. First make the CE projection and event baseline complete enough to announce live-only/new sessions. Then make `RemoteAppModel` the single owner of old/new snapshot reconciliation and ephemeral unseen state. Finally, project both remote lists through shared pure hierarchy/status logic and one UUID route model for row navigation and notification sheets. Include only lightweight root collapse so the desktop disclosure symbol is functional; defer search, date sections, pinning, and hidden-descendant chips. Keep connection banners and toolbar health indicators independent from per-chat status.

## Work Items

1. **Make CE session projection and first observation complete.**
   - **Touch:** `repoprompt-ce/Sources/RepoPrompt/Infrastructure/Remote/RemoteControlServices.swift:277-314`, `RemoteGateway.swift:247-275`, `Tests/RepoPromptTests/Remote/RemoteSnapshotProjectionTests.swift`.
   - Project the union of persisted session-index records and live Agent Mode sessions, keyed by stable session ID. Live run state, parent, activity, interaction, and other current fields override persisted fallbacks; deduplicate records deterministically across workspace contexts. Do not omit a live-only session while its index entry is being written.
   - Ensure the gateway establishes its comparison baseline before the first timed poll can hide an initial creation, while retaining the existing one-second observation cadence, event coalescing, bounded replay, and snapshot authority.
   - **Validation:** Add focused CE coverage for live-only creation, persisted/live overlay, parent/activity changes, new-session events, lifecycle event selection, and initial-baseline behavior. Keep the existing protocol and replay contracts unchanged; no protocol-version or credential changes.

2. **Centralize iOS reconciliation and ephemeral unseen state.**
   - **Touch:** `repoprompt-remote/Sources/RepoPromptRemote/RemoteAppModel.swift:571-607,684-705,734-779,856-890`, `RemoteSnapshotReducer.swift:10-85`, `Tests/RepoPromptRemoteTests/RemoteReadOnlyClientTests.swift`.
   - Keep reducer ownership limited to ordered event acceptance and authoritative snapshot replacement. `RemoteAppModel` owns one commit contract: take the prior published snapshot, the newly accepted snapshot, the update source, and the currently visible session ID; derive unseen transitions; then publish once. Use a UUID-keyed presentation token so row navigation and notification sheets share the same visibility/acknowledgement semantics.
   - Seed the baseline without badges. Thereafter, mark a session unseen only for a background insertion or transition into waiting-for-input, blocked, completed, or failed; running/opening clears stale unseen state; opening a chat acknowledges it; duplicate/identical events do not re-mark it; removed sessions are cleaned up. Preserve this state across ordinary reconnects and clear it on unpair. Snapshot/gap recovery compares the final recovered state with the prior baseline, so an eligible terminal state still becomes unseen even when an intermediate transition was missed.
   - **Validation:** Cover stable-ID append/update without duplication, initial seeding, every eligible transition, visible-session suppression, acknowledgement, running-state clearing, duplicate delivery, removal cleanup, and gap-recovery replacement. Keep all mutation on the existing `@MainActor` model.

3. **Add shared pure hierarchy and desktop-parity status projection.**
   - **Add:** `Sources/RepoPromptRemote/RemoteChatListProjection.swift` and `Tests/RepoPromptRemoteTests/RemoteChatListProjectionTests.swift`; retain `lastUpdatedAt` in the presentation input and register new files with the app/test targets.
   - Build one projector used by both global and project-scoped lists. Filter the visible scope before linking parents; sort deterministically by activity then session ID; use `parentSessionID` as the only attachment authority and ignore conflicting `childSessionIDs` for structure; promote missing-parent and self-linked nodes to roots. For a cycle, detach every member of the cyclic component as a root, remove only the cyclic edges, and attach otherwise-valid descendants normally. Recursively emit valid descendants with depth and only the `hasChildren` metadata needed for disclosure. Root and sibling ordering should follow the desktop activity-first behavior.
   - Add a pure status-slot resolver that accepts chat run state, unseen state, and hierarchy metadata—but not connection state. Match desktop precedence: active opening/working treatment first; unseen waiting/blocked treatment next; unseen completed/failed check or exclamation may replace the identity glyph; otherwise render child arrow, expandable-root disclosure, or root dot with the corresponding desktop tint/semantics.
   - **Validation:** Test three-level nesting, sibling/subtree ordering, missing/cross-scope parents, self-links, multi-node cycles, deterministic ties, collapse filtering, and a table of status-precedence combinations.

4. **Replace flat list rendering with UUID-stable hierarchical navigation.**
   - **Touch:** `Sources/RepoPromptRemote/RemoteTabView.swift:140-201,283-451,454-605` and the new projection types.
   - Make `ChatsView` and `ProjectChatsView` consume the same projector, with ephemeral collapsed-root IDs and expanded-by-default roots. Use a fixed-width status plate driven by the resolver; keep existing status text/detail and the separate connection banner/toolbar indicator.
   - Introduce one UUID-only `ChatRoute` owner for both row pushes and notification sheets; do not capture mutable `SessionRow` values as navigation identity. Keep the current route/detail open when another session arrives, rows reorder, titles change, or a session temporarily disappears; rebind to current snapshot data when it returns and retain fallback metadata when it does not. Register/unregister the route’s session ID with the model’s visible-session token so opening a row acknowledges exactly that chat. Deep links should wait for the UUID to resolve before being consumed.
   - **Validation:** Prove that inserting/reordering/updating another session does not change the open route; opening an unseen row clears its marker; global and project-scoped lists share the same hierarchy and status semantics for their visible sessions.

5. **Run layered contract tests and real-app responsiveness acceptance.**
   - **Touch:** existing CE Remote projection tests, remote protocol tests, iOS reducer/projection tests, and `docs/plans/remote-chat-list-parity-2026-07-22.md` for recorded evidence.
   - Run shared replay/coalescer/serialization tests, CE snapshot/event tests, and iOS reconciliation/projection tests. Confirm that `RemoteModels.swift`, replay capacity, credentials, and persistence schemas remain unchanged.
   - Validate with the real CE debug app and iOS Simulator, followed by a physical iPhone: keep chat A open while the Mac creates/updates chat B; verify B appears without refresh and A remains selected; exercise nested and malformed lineage; verify unseen transitions, acknowledgement, replay-window reconnect, and stale-cursor snapshot recovery. Measure repeated Mac-to-phone transitions on a healthy LAN and record desktop poll time, event cursor, phone visibility time, and recovery path. Compare p95 visibility with the latency bound selected below; the current architecture’s healthy-path contribution is roughly 0–1.5 seconds before network/decoding overhead. If the required bound is below that floor, cadence/transport work becomes a prerequisite before UI work. Package-only or mock-transport results are not end-to-end evidence.

## Open Questions

- Confirm the p95 visibility target for a healthy LAN. The recommended first acceptance gate is to measure the existing approximately 0–1.5 second observation contribution plus network/decoding overhead; a stricter target changes implementation order by requiring transport/cadence work before the list projection.

## References

- Desktop hierarchy/order: `repoprompt-ce/Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeSidebarSessionBuilder.swift:492-711`.
- Desktop row symbols and unseen semantics: `repoprompt-ce/Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentSessionRows.swift:382-467,515-614`; `AgentSessionSidebarUIStore.swift:3-70`.
- Remote authority and replay contract: `repoprompt-ce/docs/architecture/remote-control.md:16-29,46-74,151-157`; `repoprompt-ce/Sources/RepoPrompt/Infrastructure/Remote/RemoteGateway.swift:247-376,632-650`.
- Remote client projection and UI seams: `Sources/RepoPromptRemote/RemoteAppModel.swift:571-779,856-890`; `Sources/RepoPromptRemote/RemoteTabView.swift:140-605`.
- Shared protocol/reducer tests: `Packages/RepoPromptRemoteProtocol/Tests/RepoPromptRemoteProtocolTests/RemoteContractTests.swift:19-204`; `Tests/RepoPromptRemoteTests/RemoteReadOnlyClientTests.swift:6-169`.
- Prior local integration plan: `docs/plans/local-dev-integration-2026-07-21.md`.
