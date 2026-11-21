import SwiftUI
import RepoPromptRemoteProtocol

private enum RemoteWorkflowCardHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum RemoteWorkflowCatalogOrdering {
    static func ordered(_ workflows: [RemoteWorkflowDescriptor]) -> [RemoteWorkflowDescriptor] {
        guard workflows.contains(where: { $0.featuredRank != nil }) else {
            return workflows
        }
        return workflows.enumerated().sorted { lhs, rhs in
            switch (lhs.element.featuredRank, rhs.element.featuredRank) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    static func reconciledSelection(
        _ selectedWorkflowID: String?,
        in workflows: [RemoteWorkflowDescriptor]
    ) -> String? {
        guard let selectedWorkflowID else { return nil }
        return workflows.contains(where: { $0.id == selectedWorkflowID }) ? selectedWorkflowID : nil
    }
}

struct RemoteWorkflowLaunchView: View {
    @EnvironmentObject private var model: RemoteAppModel

    let workspace: RemoteWorkspaceSummary
    let onCancel: () -> Void

    @State private var selectedWorkflowID: String?
    @State private var showsAllWorkflows = false
    @State private var workflowCardHeight: CGFloat = 0

    private let workflowCardMinimumHeight: CGFloat = 112

    private var orderedWorkflows: [RemoteWorkflowDescriptor] {
        RemoteWorkflowCatalogOrdering.ordered(model.workflowCatalog)
    }

    private var featuredWorkflows: [RemoteWorkflowDescriptor] {
        orderedWorkflows.filter { $0.featuredRank != nil }
    }

    private var primaryWorkflows: [RemoteWorkflowDescriptor] {
        featuredWorkflows.isEmpty ? orderedWorkflows : featuredWorkflows
    }

    private var remainingWorkflows: [RemoteWorkflowDescriptor] {
        guard !featuredWorkflows.isEmpty else { return [] }
        return orderedWorkflows.filter { $0.featuredRank == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("What are we building?")
                        .font(.largeTitle.bold())
                }

                if orderedWorkflows.isEmpty {
                    fallbackCard
                } else {
                    defaultWorkflowCard

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(primaryWorkflows, id: \.id) { workflow in
                            workflowCard(workflow)
                        }
                    }

                    if !remainingWorkflows.isEmpty {
                        DisclosureGroup("All workflows", isExpanded: $showsAllWorkflows) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(remainingWorkflows, id: \.id) { workflow in
                                    workflowCard(workflow)
                                }
                            }
                            .padding(.top, 12)
                        }
                        .font(.headline)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RemoteChatComposer(
                workspaceID: workspace.workspaceID,
                destination: .newChat(workflowID: selectedWorkflowID)
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel", action: onCancel)
            }
        }
        .onPreferenceChange(RemoteWorkflowCardHeightPreferenceKey.self) { height in
            guard height > 0, abs(workflowCardHeight - height) > 0.5 else { return }
            workflowCardHeight = height
        }
        .onChange(of: model.workflowCatalog) { _, catalog in
            selectedWorkflowID = RemoteWorkflowCatalogOrdering.reconciledSelection(
                selectedWorkflowID,
                in: catalog
            )
        }
    }

    private var fallbackCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No workflow")
                .font(.headline)
            Text("This Mac does not publish workflow details. Your prompt will be sent without a workflow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var defaultWorkflowCard: some View {
        Button {
            selectedWorkflowID = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("No workflow")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Send your prompt without applying a workflow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedWorkflowID == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.remoteWarmOrange)
                }
            }
            .padding(14)
            .background(
                selectedWorkflowID == nil ? Color.remoteWarmOrange.opacity(0.15) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        selectedWorkflowID == nil ? Color.remoteWarmOrange.opacity(0.72) : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(selectedWorkflowID == nil ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private func workflowCard(_ workflow: RemoteWorkflowDescriptor) -> some View {
        let accent = Color(remoteHex: workflow.accentColorHex) ?? .remoteWarmOrange
        let hasAuthoritativeVisuals = workflow.iconName != nil
            || workflow.accentColorHex != nil
            || workflow.descriptionText != nil
        Button {
            selectedWorkflowID = workflow.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: workflow.iconName ?? "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(hasAuthoritativeVisuals ? accent : .secondary)
                    .frame(width: 42, height: 42)
                    .background(
                        (hasAuthoritativeVisuals ? accent : Color.secondary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(workflow.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = workflow.descriptionText, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if selectedWorkflowID == workflow.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 20, height: 20)
            }
            .padding(14)
            .frame(
                maxWidth: .infinity,
                minHeight: max(workflowCardHeight, workflowCardMinimumHeight),
                alignment: .topLeading
            )
            .background(
                selectedWorkflowID == workflow.id ? accent.opacity(0.13) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        selectedWorkflowID == workflow.id ? accent.opacity(0.65) : Color.secondary.opacity(0.15),
                        lineWidth: 1
                    )
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RemoteWorkflowCardHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(workflow.displayName) workflow")
        .accessibilityValue(selectedWorkflowID == workflow.id ? "Selected" : "Not selected")
    }
}

struct RemoteComposerSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
            .overlay(alignment: .top) { Divider() }
    }
}

struct RemoteAgentSelectionBar: View {
    let agents: [RemoteAgentDescriptor]
    let selectedAgentID: String?
    let selectedModelID: String?
    let selectedReasoningEffortID: String?
    let allowedAgentIDs: Set<String>?
    let allowedModelIDs: Set<String>?
    let allowedReasoningEffortIDs: Set<String>?
    let allowsAgentSwitch: Bool
    let isModelMutable: Bool
    let isEffortMutable: Bool
    let isPending: Bool
    let toolCatalog: RemoteToolCatalog?
    let canEditTools: Bool
    let onSelectModel: (_ agentID: String, _ modelID: String) -> Void
    let onSelectReasoningEffort: (_ reasoningEffortID: String) -> Void
    let onToggleTool: (_ setting: RemoteToolSettingDescriptor, _ revision: Int) -> Void

    @State private var showsModelPicker = false
    private var selectedModel: RemoteModelDescriptor? {
        agents.first(where: { $0.id == selectedAgentID })?.modelDescriptors?.first(where: { $0.id == selectedModelID })
    }

    private var hasSelectableModel: Bool {
        agents.contains { agent in
            agent.isAvailable && agent.modelDescriptors?.contains {
                $0.isAvailable && canSelectModel($0.id, for: agent.id)
            } == true
        }
    }

    private var effortOptions: [RemoteReasoningEffortDescriptor] {
        selectedModel?.reasoningEfforts ?? []
    }

    private func canSelectModel(_ modelID: String, for agentID: String) -> Bool {
        isModelMutable && !isPending
            && (allowsAgentSwitch || agentID == selectedAgentID)
            && (allowedAgentIDs?.contains(agentID) ?? true)
            && (agentID != selectedAgentID || (allowedModelIDs?.contains(modelID) ?? true))
    }

    private func canSelectEffort(_ effortID: String) -> Bool {
        isEffortMutable && !isPending && (allowedReasoningEffortIDs?.contains(effortID) ?? true)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showsModelPicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                    Text(modelLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 30)
                .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .disabled(!hasSelectableModel)
            .sheet(isPresented: $showsModelPicker) {
                NavigationStack {
                    List {
                        ForEach(agents.filter(\.isAvailable), id: \.id) { agent in
                            Section(agent.displayName) {
                                ForEach((agent.modelDescriptors ?? []).filter(\.isAvailable), id: \.id) { candidate in
                                    Button {
                                        onSelectModel(agent.id, candidate.id)
                                        showsModelPicker = false
                                    } label: {
                                        HStack {
                                            Text(RemoteLaunchSelection.modelLabel(candidate.displayName))
                                            Spacer()
                                            if agent.id == selectedAgentID,
                                               candidate.id == selectedModelID
                                            {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                    .disabled(!canSelectModel(candidate.id, for: agent.id))
                                }
                            }
                        }
                    }
                    .navigationTitle("Model")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showsModelPicker = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }

            if !effortOptions.isEmpty {
                Menu {
                    ForEach(effortOptions, id: \.id) { effort in
                        Button {
                            onSelectReasoningEffort(effort.id)
                        } label: {
                            HStack {
                                Text(effort.displayName)
                                if effort.id == selectedReasoningEffortID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(!canSelectEffort(effort.id))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(effortLabel)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 30)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .accessibilityLabel("Reasoning level")
                .accessibilityValue(effortLabel)
                .disabled(!effortOptions.contains { canSelectEffort($0.id) })
            }

            if let toolCatalog, selectedAgentID == toolCatalog.providerID {
                RemoteToolsButton(catalog: toolCatalog, isPending: isPending, canEdit: canEditTools, onToggle: onToggleTool)
            }

            if isPending {
                ProgressView().controlSize(.mini)
            }
        }
        .opacity((isModelMutable || isEffortMutable) ? 1 : 0.58)
        .accessibilityElement(children: .contain)
    }

    private var modelLabel: String {
        RemoteLaunchSelection.modelLabel(selectedModel?.displayName ?? selectedModelID ?? "Mac default")
    }

    private var effortLabel: String {
        effortOptions.first(where: { $0.id == selectedReasoningEffortID })?.displayName
            ?? selectedReasoningEffortID?.capitalized
            ?? "Reasoning"
    }
}

private struct RemoteToolsButton: View {
    let catalog: RemoteToolCatalog
    let isPending: Bool
    let canEdit: Bool
    let onToggle: (RemoteToolSettingDescriptor, Int) -> Void
    @State private var presentedCatalog: RemoteToolCatalog?

    var body: some View {
        Button {
            presentedCatalog = catalog
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text("Tools")
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .disabled(isPending)
        .sheet(isPresented: Binding(
            get: { presentedCatalog != nil },
            set: { if !$0 { presentedCatalog = nil } }
        )) {
            if let snapshot = presentedCatalog {
                NavigationStack {
                    Form {
                        ForEach(["tools", "mcp_servers"], id: \.self) { category in
                            let settings = snapshot.settings.filter { $0.category == category }
                            if !settings.isEmpty {
                                Section(category == "tools" ? "Tools" : "MCP Servers") {
                                    ForEach(settings) { setting in
                                        Toggle(setting.displayName, isOn: Binding(
                                            get: { setting.isEnabled },
                                            set: { enabled in
                                                onToggle(setting, snapshot.revision)
                                                presentedCatalog = nil
                                            }
                                        ))
                                        .disabled(!canEdit || !snapshot.isMutable || !setting.isMutable || setting.isRequired)
                                    }
                                }
                            }
                        }
                        if let reason = snapshot.unavailableReason {
                            Text(reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Codex Tools")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { presentedCatalog = nil }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

struct RemoteComposerSendButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isEnabled ? Color.white : Color.primary.opacity(0.72))
            .padding(.horizontal, 13)
            .frame(minHeight: 36)
            .background {
                Capsule()
                    .fill(isEnabled ? Color.remoteWarmOrange : Color.primary.opacity(0.12))
                    .overlay {
                        Capsule().stroke(
                            isEnabled ? Color.white.opacity(0.18) : Color.primary.opacity(0.22),
                            lineWidth: 1
                        )
                    }
            }
            .shadow(color: .black.opacity(isEnabled ? 0.2 : 0.08), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

extension Color {
    static let remoteWarmOrange = Color(red: 0.91, green: 0.38, blue: 0.13)
    static let remoteChatBackground = Color(red: 0.12, green: 0.12, blue: 0.115)
    static let remoteUserBubble = Color(red: 0.25, green: 0.46, blue: 0.62)

    init?(remoteHex value: String?) {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }
}
