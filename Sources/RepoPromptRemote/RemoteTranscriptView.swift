import SwiftUI
import UIKit
import RepoPromptRemoteProtocol

enum RemoteTranscriptViewportUpdate: Equatable {
    case initial
    case preserve
    case newActivity

    static func classify(
        oldItems: [RemoteTranscriptItem],
        newItems: [RemoteTranscriptItem]
    ) -> Self {
        guard !oldItems.isEmpty else { return .initial }
        guard let oldTail = oldItems.last,
              let tailIndex = newItems.firstIndex(where: { $0.id == oldTail.id })
        else { return .preserve }

        let oldIDs = Set(oldItems.map(\.id))
        let hasAppendedItem = newItems.index(after: tailIndex) < newItems.endIndex
            && newItems[newItems.index(after: tailIndex)...].contains { !oldIDs.contains($0.id) }
        let tailChanged = !sameActivityContent(oldTail, newItems[tailIndex])
        return hasAppendedItem || tailChanged ? .newActivity : .preserve
    }

    private static func sameActivityContent(
        _ lhs: RemoteTranscriptItem,
        _ rhs: RemoteTranscriptItem
    ) -> Bool {
        lhs.turnID == rhs.turnID
            && lhs.timestamp == rhs.timestamp
            && lhs.sequenceIndex == rhs.sequenceIndex
            && lhs.kind == rhs.kind
            && lhs.semanticKind == rhs.semanticKind
            && lhs.role == rhs.role
            && lhs.text == rhs.text
            && lhs.toolName == rhs.toolName
            && lhs.toolStatus == rhs.toolStatus
            && lhs.summaryOnly == rhs.summaryOnly
            && lhs.attachments?.map(\.id) == rhs.attachments?.map(\.id)
    }
}

private struct RemoteTranscriptBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct RemoteChatView: View {
    @EnvironmentObject private var model: RemoteAppModel

    let sessionID: UUID
    let workspaceID: String
    let title: String
    let initialRunState: RemoteRunState?

    @State private var message = ""
    @State private var expandedGroupIDs: Set<String> = []
    @State private var expandedDetailIDs: Set<UUID> = []
    @State private var visibleItemIDs: Set<UUID> = []
    @State private var didInitialScroll = false
    @State private var isNearBottom = true
    @State private var showsNewActivity = false
    @State private var prependAnchorID: UUID?
    @State private var itemCountBeforePrepend = 0
    @State private var scrollViewportHeight: CGFloat = 0

    init(
        sessionID: UUID,
        workspaceID: String,
        title: String,
        initialRunState: RemoteRunState?
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.title = title
        self.initialRunState = initialRunState
    }

    private var session: SessionRow? {
        model.sessions.first(where: { $0.id == sessionID })
    }

    private var items: [RemoteTranscriptItem] {
        model.transcriptItemsBySessionID[sessionID] ?? []
    }

    private var presentation: [RemoteTranscriptPresentationElement] {
        RemoteTranscriptPresentation.elements(from: items)
    }

    private var runState: RemoteRunState {
        session?.runState ?? initialRunState ?? .idle
    }

    private var runNoticeState: RemoteRunState? {
        guard session?.pendingInteraction == nil else { return nil }
        switch runState {
        case .opening, .working, .waitingForInput, .blocked, .cancelled:
            return runState
        case .failed:
            let latestTurn = items.last?.turnID
            return items.reversed().prefix { $0.turnID == latestTurn }
                .contains { $0.role == "error" } ? nil : .failed
        case .completed, .idle:
            return nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    olderPageControl(proxy: proxy)

                    if items.isEmpty {
                        emptyTranscript
                    } else {
                        ForEach(presentation) { element in
                            presentationView(element)
                        }
                    }

                    if let runNoticeState {
                        RemoteRunNotice(state: runNoticeState, activity: session?.latestMeaningfulActivity)
                        .id("run-notice")
                    }

                    if let session, let interaction = session.pendingInteraction {
                        RemoteInteractionCard(session: session, interaction: interaction)
                            .environmentObject(model)
                            .id("pending-interaction-\(interaction.id)")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("transcript-bottom")
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: RemoteTranscriptBottomPreferenceKey.self,
                                    value: geometry.frame(in: .named("transcript-scroll-space")).maxY
                                )
                            }
                        }
                        .onDisappear { isNearBottom = false }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .coordinateSpace(name: "transcript-scroll-space")
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { scrollViewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in
                            scrollViewportHeight = height
                        }
                }
            }
            .onPreferenceChange(RemoteTranscriptBottomPreferenceKey.self) { bottomY in
                guard scrollViewportHeight > 0 else { return }
                let wasNearBottom = isNearBottom
                isNearBottom = bottomY <= scrollViewportHeight + 24
                if isNearBottom, !wasNearBottom {
                    showsNewActivity = false
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if showsNewActivity {
                    Button {
                        withAnimation { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
                        showsNewActivity = false
                    } label: {
                        Label("New activity", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                }
            }
            .onChange(of: items) { oldItems, newItems in
                handleItemsChanged(oldItems: oldItems, newItems: newItems, proxy: proxy)
            }
            .onChange(of: runNoticeState) { _, _ in
                guard isNearBottom else { return }
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RemoteChatComposer(
                    message: $message,
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    runState: runState,
                    pendingInteraction: session?.pendingInteraction,
                    session: session
                )
                .environmentObject(model)
            }
            .task(id: sessionID) {
                didInitialScroll = false
                isNearBottom = true
                showsNewActivity = false
                prependAnchorID = nil
                visibleItemIDs = []
                if !items.isEmpty {
                    didInitialScroll = true
                    await Task.yield()
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                model.loadTranscript(for: sessionID)
            }
        }
        .background(Color.remoteChatBackground.ignoresSafeArea())
        .navigationTitle(session?.title ?? title)
    }

    @ViewBuilder
    private func olderPageControl(proxy: ScrollViewProxy) -> some View {
        if model.transcriptHasMore(for: sessionID) {
            Button {
                let visibleAnchor = items.first(where: { visibleItemIDs.contains($0.id) })?.id
                prependAnchorID = visibleAnchor ?? items.first?.id
                itemCountBeforePrepend = items.count
                model.loadMoreTranscript(for: sessionID)
            } label: {
                Label("Load earlier", systemImage: "arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Keeps the current message in place while older messages are inserted above it.")
        } else if case .loading = model.transcriptTimelinesBySessionID[sessionID]?.olderPageState {
            ProgressView("Loading earlier activity…")
                .frame(maxWidth: .infinity)
        }
    }

    private var emptyTranscript: some View {
        Group {
            if case let .failed(message) = model.transcriptTimelinesBySessionID[sessionID]?.initialLoadState {
                ContentUnavailableView {
                    Label("Conversation unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { model.loadTranscript(for: sessionID) }
                }
            } else {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "text.bubble",
                    description: Text("The conversation will appear as the Mac reports it.")
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private func presentationView(_ element: RemoteTranscriptPresentationElement) -> some View {
        switch element {
        case let .narrative(item, semantic):
            RemoteNarrativeRow(item: item, semantic: semantic) {
                model.loadTranscriptDetails(for: sessionID, itemID: item.id)
            }
                .id(item.id)
                .onAppear { visibleItemIDs.insert(item.id) }
                .onDisappear { visibleItemIDs.remove(item.id) }
        case let .activityGroup(groupItems, exceptional):
            RemoteActivityGroupView(
                items: groupItems,
                exceptional: exceptional,
                isExpanded: exceptional != expandedGroupIDs.contains(element.id),
                expandedDetailIDs: $expandedDetailIDs,
                onToggleGroup: {
                    if expandedGroupIDs.contains(element.id) {
                        expandedGroupIDs.remove(element.id)
                    } else {
                        expandedGroupIDs.insert(element.id)
                    }
                },
                onToggleDetails: { item in
                    if expandedDetailIDs.contains(item.id) {
                        expandedDetailIDs.remove(item.id)
                    } else {
                        expandedDetailIDs.insert(item.id)
                        model.loadTranscriptDetails(for: sessionID, itemID: item.id)
                    }
                },
                onLoadDetails: { item in model.loadTranscriptDetails(for: sessionID, itemID: item.id) }
            )
            .id(groupItems.first?.id)
            .onAppear { groupItems.forEach { visibleItemIDs.insert($0.id) } }
            .onDisappear { groupItems.forEach { visibleItemIDs.remove($0.id) } }
        }
    }

    private func handleItemsChanged(
        oldItems: [RemoteTranscriptItem],
        newItems: [RemoteTranscriptItem],
        proxy: ScrollViewProxy
    ) {
        guard !newItems.isEmpty else { return }
        if let anchor = prependAnchorID, newItems.count > itemCountBeforePrepend {
            DispatchQueue.main.async {
                proxy.scrollTo(anchor, anchor: .top)
                prependAnchorID = nil
            }
            return
        }
        if !didInitialScroll {
            didInitialScroll = true
            DispatchQueue.main.async { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            return
        }

        guard RemoteTranscriptViewportUpdate.classify(
            oldItems: oldItems,
            newItems: newItems
        ) == .newActivity else { return }

        if isNearBottom {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        } else {
            showsNewActivity = true
        }
    }
}

private struct RemoteNarrativeRow: View {
    let item: RemoteTranscriptItem
    let semantic: RemoteTranscriptSemanticKind
    let loadDetails: () -> Void

    private var isUser: Bool { semantic == .userRequest }
    private var isSummary: Bool { semantic == .summary }
    private var isPreamble: Bool { semantic == .assistantPreamble }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                if isUser || isSummary {
                    HStack(spacing: 6) {
                        if isSummary {
                            Image(systemName: "text.append")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.remoteWarmOrange)
                        }
                        Text(isUser ? "You" : "Conversation summary")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }

                if let text = item.text, !text.isEmpty {
                    RemoteMarkdownText(markdown: text)
                    .font(.subheadline)
                    .foregroundStyle(isUser ? Color.white : (isPreamble ? Color.white.opacity(0.68) : Color.white.opacity(0.92)))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        isUser ? Color.remoteUserBubble : Color.remoteChatBackground,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                }

                RemoteTranscriptAttachments(item: item, loadDetails: loadDetails)
                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !isUser { Spacer(minLength: 18) }
        }
    }
}

private struct RemoteTranscriptAttachments: View {
    @EnvironmentObject private var model: RemoteAppModel
    let item: RemoteTranscriptItem
    let loadDetails: () -> Void

    var body: some View {
        ForEach(item.attachments ?? []) { attachment in
            if let data = attachment.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 250, maxHeight: 250)
                    .clipShape(.rect(cornerRadius: 9))
                    .accessibilityLabel(attachment.name)
            } else if attachment.isImage {
                Button(action: loadDetails) {
                    Label(attachment.name, systemImage: "photo")
                }
                .buttonStyle(.bordered)
                .disabled(model.transcriptDetailStates[item.id] == .loading)
                .accessibilityHint("Loads the image preview from the Mac")
            } else {
                Label(attachment.name, systemImage: "doc")
                    .padding(7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .font(.caption)

        if item.attachments?.contains(where: { $0.isImage && $0.thumbnail == nil }) == true {
            switch model.transcriptDetailStates[item.id] {
            case .loading?: ProgressView("Loading previews…").font(.caption)
            case .failed?: Text("Preview request failed. Tap the image to retry.").font(.caption)
            case .loaded?: Text("Preview unavailable").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
    }
}

struct RemoteMarkdownText: View {
    let markdown: String

    private var blocks: [RemoteMarkdownBlock] {
        RemoteMarkdownDocumentParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: RemoteMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            RemoteInlineMarkdownText(markdown: text)
        case let .heading(level, text):
            RemoteInlineMarkdownText(markdown: text)
                .font(headingFont(for: level))
                .accessibilityAddTraits(.isHeader)
        case let .list(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(markerText(for: item.marker))
                            .font(.subheadline.monospacedDigit())
                            .frame(minWidth: 18, alignment: .trailing)
                        RemoteInlineMarkdownText(markdown: item.text)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                    .accessibilityElement(children: .combine)
                }
            }
        case let .blockQuote(text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.remoteWarmOrange.opacity(0.65))
                    .frame(width: 3)
                RemoteInlineMarkdownText(markdown: text)
                    .foregroundStyle(.secondary)
            }
        case let .codeBlock(language, code):
            RemoteCodeBlock(language: language, code: code)
        case let .table(table):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                            RemoteInlineMarkdownText(markdown: cell).bold()
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                RemoteInlineMarkdownText(markdown: cell)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        case let .image(alt, url):
            RemoteMarkdownImage(alt: alt, url: url)
        case .thematicBreak:
            Divider()
                .overlay(Color.white.opacity(0.16))
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        case 3: .headline.weight(.bold)
        case 4: .subheadline.weight(.bold)
        default: .subheadline.weight(.semibold)
        }
    }

    private func markerText(for marker: RemoteMarkdownListItem.Marker) -> String {
        switch marker {
        case .bullet: "•"
        case let .ordered(number): "\(number)."
        }
    }
}

private struct RemoteCodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language ?? "Code")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 34, minHeight: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .onChange(of: code) { _, _ in copied = false }
    }
}

private struct RemoteMarkdownImage: View {
    let alt: String
    let url: URL
    @State private var loadImage = false

    private var label: String { alt.isEmpty ? "Image" : alt }

    var body: some View {
        if loadImage {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit().accessibilityLabel(label)
                case .failure:
                    Label("Image unavailable", systemImage: "photo").accessibilityHint(label)
                default:
                    ProgressView(label)
                }
            }
            .frame(maxHeight: 320)
        } else {
            Button { loadImage = true } label: {
                Label(label, systemImage: "photo")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Loads the image from its source")
        }
    }
}

private struct RemoteInlineMarkdownText: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(markdown)
        }
    }
}

private struct RemoteRunNotice: View {
    let state: RemoteRunState
    let activity: String?

    private var isWorking: Bool { state == .opening || state == .working }

    private var title: String {
        switch state {
        case .opening: "Starting…"
        case .working: "Thinking…"
        case .waitingForInput: "Waiting for input"
        case .blocked: "Run blocked"
        case .failed: "Run failed"
        default: "Run cancelled"
        }
    }

    private var noticeIcon: String {
        switch state {
        case .waitingForInput: "clock"
        case .cancelled: "stop.circle"
        default: "exclamationmark.circle"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isWorking {
                ProgressView().controlSize(.small).tint(Color.remoteWarmOrange)
            } else {
                Image(systemName: noticeIcon)
            }
            // The desktop's latest activity already contains the useful status while running.
            Text((isWorking || state == .waitingForInput) ? activity ?? title : title)
        }
        .font(.footnote)
        .foregroundStyle(state == .failed ? Color.red : .secondary)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct RemoteActivityGroupView: View {
    let items: [RemoteTranscriptItem]
    let exceptional: Bool
    let isExpanded: Bool
    @Binding var expandedDetailIDs: Set<UUID>
    let onToggleGroup: () -> Void
    let onToggleDetails: (RemoteTranscriptItem) -> Void
    let onLoadDetails: (RemoteTranscriptItem) -> Void

    private var toolNames: [String] {
        Array(Set(items.compactMap(\.toolName))).sorted()
    }

    private var accent: Color { exceptional ? .red : .secondary }

    private var aggregateStatus: RemoteToolActivityState? {
        RemoteToolActivityState.aggregate(items)
    }

    private var title: String {
        if exceptional {
            let semantic = items.first.map(RemoteTranscriptPresentation.semanticKind(for:))
            switch semantic {
            case .permission?: return "Permission required"
            case .question?: return "Question"
            case .approval?: return "Approval required"
            default: return "Activity needs attention"
            }
        }
        if items.count == 1, let toolName = items.first?.toolName { return toolName }
        let count = items.filter { $0.toolName != nil }.count
        if count == items.count { return "\(count) tool calls" }
        return "\(items.count) activities"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleGroup) {
                HStack(spacing: 10) {
                    Image(systemName: exceptional ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.footnote.weight(.semibold))
                        if !toolNames.isEmpty, toolNames != [title] {
                            Text(toolNames.prefix(3).joined(separator: " · "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let text = items.first?.text, !text.isEmpty {
                            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if let aggregateStatus {
                            Text(aggregateStatus.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(aggregateStatus.tint)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        RemoteActivityItemView(
                            item: item,
                            isExpanded: expandedDetailIDs.contains(item.id),
                            onToggleDetails: { onToggleDetails(item) },
                            onLoadDetails: { onLoadDetails(item) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(accent.opacity(exceptional ? 0.075 : 0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(exceptional ? 0.28 : 0.12), lineWidth: 1)
        }
    }
}

private struct RemoteActivityItemView: View {
    @EnvironmentObject private var model: RemoteAppModel
    let item: RemoteTranscriptItem
    let isExpanded: Bool
    let onToggleDetails: () -> Void
    let onLoadDetails: () -> Void

    private var state: RemoteToolActivityState? { RemoteToolActivityState(item) }
    private var hasDetails: Bool { item.detail != nil || item.detailText?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                if let state {
                    Image(systemName: state.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.tint)
                        .accessibilityLabel(state.label)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.toolName ?? item.role.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption.monospaced().weight(.semibold))
                    if let text = item.text, !text.isEmpty {
                        RemoteMarkdownText(markdown: text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if item.detailAvailable || hasDetails {
                    Button(action: onToggleDetails) {
                        Image(systemName: isExpanded ? "eye.slash" : "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide tool details" : "Show tool details")
                }
            }
            RemoteTranscriptAttachments(item: item, loadDetails: onLoadDetails)
            if isExpanded {
                if let detail = item.detail {
                    RemoteToolDetails(detail: detail, showsSummary: item.text == nil)
                } else if let text = item.detailText, !text.isEmpty {
                    RemoteCodeBlock(language: nil, code: text)
                } else {
                    switch model.transcriptDetailStates[item.id] {
                    case .failed?:
                        Button("Retry loading details", action: onLoadDetails).font(.caption)
                    case .loaded?:
                        Text("No additional details").font(.caption).foregroundStyle(.secondary)
                    default:
                        ProgressView("Loading details…").font(.caption)
                    }
                }
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension RemoteToolActivityState {
    var tint: Color {
        switch self {
        case .running, .warning: .orange
        case .completed: .green
        case .failed: .red
        case .pending, .cancelled, .unknown: .secondary
        }
    }

    var icon: String {
        switch self {
        case .running: "arrow.clockwise"
        case .pending: "clock"
        case .completed: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

private struct RemoteToolDetails: View {
    let detail: RemoteTranscriptDetail
    let showsSummary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSummary, let summary = detail.summaryText { RemoteMarkdownText(markdown: summary) }
            payload("Arguments", detail.argumentsJSON)
            payload("Result", detail.resultJSON)
            if !detail.keyPaths.isEmpty {
                RemoteCodeBlock(language: "Files", code: detail.keyPaths.joined(separator: "\n"))
            }
            if let exitCode = detail.exitCode { LabeledContent("Exit code", value: String(exitCode)) }
            if let processID = detail.processID { LabeledContent("Process", value: processID) }
            if let thinking = detail.reasoning, !thinking.isEmpty {
                Text("Reasoning").font(.caption.weight(.semibold))
                RemoteMarkdownText(markdown: thinking)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func payload(_ title: String, _ raw: String?) -> some View {
        if let raw, !raw.isEmpty {
            let value = RemoteTranscriptPresentation.formattedToolPayload(raw)
            RemoteCodeBlock(language: title, code: value)
        }
    }
}

private struct RemoteChatComposer: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Binding var message: String
    let sessionID: UUID
    let workspaceID: String
    let runState: RemoteRunState
    let pendingInteraction: RemoteInteractionSummary?
    let session: SessionRow?

    @StateObject private var attachments = RemoteAttachmentDraft()
    @State private var pendingCommandID: UUID?
    @State private var pendingCancelID: UUID?
    @State private var pendingConfigurationID: UUID?

    private var policy: RemoteComposerPolicy {
        .resolve(runState: runState, pendingInteraction: pendingInteraction)
    }

    private var canSend: Bool {
        let hasText = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return model.canControlChat && policy.primaryOperation != nil
            && (hasText || !attachments.files.isEmpty)
            && (attachments.files.isEmpty || (policy.canAttach && model.canSendAttachments))
            && !attachments.isLoading
            && pendingCommandID == nil
            && pendingConfigurationID == nil
    }

    private var configurationControls: RemoteSessionConfigurationControls? {
        guard model.agentCatalogMetadata?.supportsSessionConfiguration == true else { return nil }
        return session?.configurationControls
    }

    var body: some View {
        RemoteComposerSurface {
            VStack(spacing: 0) {
                if policy.isInteractionBlocking {
                    Label("Respond to the request above", systemImage: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }

                RemoteAttachmentDraftStrip(draft: attachments, isSending: pendingCommandID != nil)
                HStack(alignment: .center, spacing: 8) {
                    if model.agentCatalogMetadata?.supportsAttachments == true {
                        RemoteAttachmentPicker(
                            draft: attachments,
                            isEnabled: policy.canAttach && model.canSendAttachments && pendingCommandID == nil,
                            onError: model.presentError
                        )
                        .padding(.leading, 6)
                    }
                    TextField(placeholder, text: $message, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(.leading, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 46, alignment: .center)
                        .offset(y: 5)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .disabled(!model.canControlChat || policy.primaryOperation == nil || pendingCommandID != nil)

                    if policy.canCancel && model.canControlChat {
                        Button {
                            guard pendingCancelID == nil else { return }
                            pendingCancelID = model.cancel(sessionID: sessionID, workspaceID: workspaceID)
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.red)
                                .frame(width: 36, height: 36)
                                .background(Color.red.opacity(0.12), in: Circle())
                                .overlay {
                                    Circle().stroke(Color.red.opacity(0.24), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(pendingCancelID != nil)
                        .accessibilityLabel("Cancel run")
                    }

                    RemoteComposerSendButton(title: "Send", isEnabled: canSend, action: send)
                        .padding(.trailing, 8)
                }
                .padding(.vertical, 4)

                if let controls = configurationControls,
                   let session,
                   session.agent != nil,
                   session.model != nil
                {
                    Divider()

                    RemoteAgentSelectionBar(
                        agents: model.agentCatalog,
                        selectedAgentID: session.agent,
                        selectedModelID: session.model,
                        selectedReasoningEffortID: session.reasoningEffort,
                        allowedAgentIDs: Set(controls.agent.allowedValueIDs),
                        allowedModelIDs: Set(controls.model.allowedValueIDs),
                        allowedReasoningEffortIDs: Set(controls.reasoningEffort.allowedValueIDs),
                        allowsAgentSwitch: false,
                        isModelMutable: controls.model.isMutable,
                        isEffortMutable: controls.reasoningEffort.isMutable,
                        isPending: pendingConfigurationID != nil,
                        toolCatalog: model.agentCatalogMetadata?.toolCatalog,
                        onSelectModel: configureModel,
                        onSelectReasoningEffort: configureReasoningEffort,
                        onToggleTool: { setting, revision in
                            pendingConfigurationID = model.configureTool(
                                workspaceID: workspaceID,
                                sessionID: sessionID,
                                settingID: setting.id,
                                enabled: !setting.isEnabled,
                                expectedRevision: revision
                            )
                        }
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                }
            }
        }
        .onChange(of: model.commandActivity) { _, activity in
            if let completion = activity.completion(for: pendingCommandID) {
                pendingCommandID = nil
                if completion.outcome == .accepted {
                    message = ""
                    attachments.clear()
                }
            }
            if activity.completion(for: pendingCancelID) != nil { pendingCancelID = nil }
            if activity.completion(for: pendingConfigurationID) != nil { pendingConfigurationID = nil }
        }
    }

    private var placeholder: String {
        if !model.canControlChat { return "Read only" }
        switch policy.primaryOperation {
        case .steer?: return "Steer this run…"
        case .resume?: return "Resume with…"
        case .followUp?: return "Reply…"
        default: return "Respond above"
        }
    }

    private func send() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        pendingCommandID = model.continueChat(
            sessionID: sessionID,
            workspaceID: workspaceID,
            message: trimmed,
            runState: runState,
            attachments: attachments.files
        )
    }

    private func configureModel(agentID: String, modelID: String, reasoningEffortID: String?) {
        guard pendingConfigurationID == nil else { return }
        pendingConfigurationID = model.configureSession(
            sessionID: sessionID,
            workspaceID: workspaceID,
            agentID: agentID,
            modelID: modelID,
            reasoningEffort: reasoningEffortID
        )
    }

    private func configureReasoningEffort(_ reasoningEffortID: String) {
        guard pendingConfigurationID == nil else { return }
        pendingConfigurationID = model.configureSession(
            sessionID: sessionID,
            workspaceID: workspaceID,
            reasoningEffort: reasoningEffortID
        )
    }
}
