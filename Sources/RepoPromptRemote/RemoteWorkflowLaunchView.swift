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
    @State private var message = ""
    @StateObject private var attachments = RemoteAttachmentDraft()
    @State private var pendingCommandID: UUID?
    @State private var pendingToolCommandID: UUID?
    @State private var showsAllWorkflows = false
    @State private var workflowCardHeight: CGFloat = 0
    @State private var selectedAgentID: String?
    @State private var selectedModelID: String?
    @State private var selectedReasoningEffortID: String?

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

    private var supportsAgentSelection: Bool {
        model.agentCatalogMetadata?.supportsStartSelection == true
            && model.agentCatalog.contains(where: {
                $0.isAvailable && $0.modelDescriptors?.contains(where: \.isAvailable) == true
            })
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            launchComposer
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
        .onAppear { reconcileAgentSelection() }
        .onChange(of: model.workflowCatalog) { _, catalog in
            selectedWorkflowID = RemoteWorkflowCatalogOrdering.reconciledSelection(
                selectedWorkflowID,
                in: catalog
            )
        }
        .onChange(of: model.agentCatalog) { _, _ in reconcileAgentSelection() }
        .onChange(of: model.agentCatalogMetadata) { _, _ in reconcileAgentSelection() }
        .onChange(of: model.commandActivity) { _, activity in
            if let completion = activity.completion(for: pendingCommandID) {
                pendingCommandID = nil
                if completion.outcome == .accepted {
                    message = ""
                    attachments.clear()
                }
            }
            if activity.completion(for: pendingToolCommandID) != nil {
                pendingToolCommandID = nil
            }
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

    private var launchComposer: some View {
        RemoteComposerSurface {
            VStack(spacing: 0) {
                RemoteAttachmentDraftStrip(draft: attachments, isSending: pendingCommandID != nil)
                HStack(alignment: .center, spacing: 8) {
                    if model.agentCatalogMetadata?.supportsAttachments == true {
                        RemoteAttachmentPicker(
                            draft: attachments,
                            isEnabled: model.canSendAttachments && pendingCommandID == nil,
                            onError: model.presentError
                        )
                        .padding(.leading, 6)
                    }
                    TextField(model.canControlChat ? "Send a message…" : "Read only", text: $message, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(.leading, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 46, alignment: .center)
                        .offset(y: 5)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .disabled(!model.canControlChat || pendingCommandID != nil)

                    RemoteComposerSendButton(title: "Send", isEnabled: canSend, action: send)
                        .padding(.trailing, 8)
                }
                .padding(.vertical, 4)

                if supportsAgentSelection {
                    Divider()
                        .opacity(0.7)

                    RemoteAgentSelectionBar(
                        agents: model.agentCatalog,
                        selectedAgentID: selectedAgentID,
                        selectedModelID: selectedModelID,
                        selectedReasoningEffortID: selectedReasoningEffortID,
                        allowedAgentIDs: nil,
                        allowedModelIDs: nil,
                        allowedReasoningEffortIDs: nil,
                        allowsAgentSwitch: true,
                        isModelMutable: pendingCommandID == nil,
                        isEffortMutable: pendingCommandID == nil,
                        isPending: pendingCommandID != nil || pendingToolCommandID != nil,
                        toolCatalog: model.agentCatalogMetadata?.toolCatalog,
                        onSelectModel: selectModel,
                        onSelectReasoningEffort: { selectedReasoningEffortID = $0 },
                        onToggleTool: { setting, revision in
                            pendingToolCommandID = model.configureTool(
                                workspaceID: workspace.workspaceID,
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
    }

    private var canSend: Bool {
        let hasText = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return model.canControlChat && (hasText || !attachments.files.isEmpty)
            && (attachments.files.isEmpty || model.canSendAttachments)
            && !attachments.isLoading && pendingCommandID == nil
    }

    private func send() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        pendingCommandID = model.startRun(
            in: workspace.workspaceID,
            message: trimmed,
            workflowID: selectedWorkflowID,
            agentID: supportsAgentSelection ? selectedAgentID : nil,
            modelID: supportsAgentSelection ? selectedModelID : nil,
            reasoningEffort: supportsAgentSelection ? selectedReasoningEffortID : nil,
            attachments: attachments.files
        )
    }

    private func reconcileAgentSelection() {
        guard supportsAgentSelection else {
            selectedAgentID = nil
            selectedModelID = nil
            selectedReasoningEffortID = nil
            return
        }
        let availableAgents = model.agentCatalog.filter {
            $0.isAvailable && $0.modelDescriptors?.contains(where: \.isAvailable) == true
        }
        let desktopDefault = model.agentCatalogMetadata?.defaultSelection
        let requestedAgentID = selectedAgentID ?? desktopDefault?.agentID
        guard let agent = availableAgents.first(where: { $0.id == requestedAgentID }) else {
            selectedAgentID = nil
            selectedModelID = nil
            selectedReasoningEffortID = nil
            return
        }
        let models = agent.modelDescriptors?.filter(\.isAvailable) ?? []
        let requestedModelID = selectedModelID
            ?? (desktopDefault?.agentID == agent.id ? desktopDefault?.modelID : nil)
        guard let selectedModel = models.first(where: { $0.id == requestedModelID }) else {
            selectedAgentID = nil
            selectedModelID = nil
            selectedReasoningEffortID = nil
            return
        }
        let efforts = selectedModel.reasoningEfforts
        let defaultEffortID = desktopDefault?.agentID == agent.id && desktopDefault?.modelID == selectedModel.id
            ? desktopDefault?.reasoningEffort
            : selectedModel.defaultReasoningEffortID
        let effort = efforts.first(where: { $0.id == selectedReasoningEffortID })?.id
            ?? efforts.first(where: { $0.id == defaultEffortID })?.id
        selectedAgentID = agent.id
        selectedModelID = selectedModel.id
        selectedReasoningEffortID = effort
    }

    private func selectModel(agentID: String, modelID: String, reasoningEffortID: String?) {
        selectedAgentID = agentID
        selectedModelID = modelID
        selectedReasoningEffortID = reasoningEffortID
        reconcileAgentSelection()
    }
}

struct RemoteComposerSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.black.opacity(0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.24), radius: 7, y: 3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.remoteChatBackground)
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
    let onSelectModel: (_ agentID: String, _ modelID: String, _ reasoningEffortID: String?) -> Void
    let onSelectReasoningEffort: (_ reasoningEffortID: String) -> Void
    let onToggleTool: (_ setting: RemoteToolSettingDescriptor, _ revision: Int) -> Void

    @State private var showsModelPicker = false
    @State private var modelPickerAgents: [RemoteAgentDescriptor] = []
    @State private var modelPickerSelectedAgentID: String?
    @State private var modelPickerSelectedModelID: String?

    private var selectedAgent: RemoteAgentDescriptor? {
        agents.first(where: { $0.id == selectedAgentID })
    }

    private var selectedModel: RemoteModelDescriptor? {
        selectedAgent?.modelDescriptors?.first(where: { $0.id == selectedModelID })
    }

    private var availableAgents: [RemoteAgentDescriptor] {
        agents.filter { agent in
            agent.isAvailable
                && (allowsAgentSwitch || agent.id == selectedAgentID)
                && (allowedAgentIDs?.contains(agent.id) ?? true)
                && agent.modelDescriptors?.contains(where: \.isAvailable) == true
        }
    }

    private var availableEfforts: [RemoteReasoningEffortDescriptor] {
        selectedModel?.reasoningEfforts.filter {
            allowedReasoningEffortIDs?.contains($0.id) ?? true
        } ?? []
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                modelPickerAgents = availableAgents.compactMap { agent in
                    let models = availableModels(for: agent)
                    guard !models.isEmpty else { return nil }
                    return RemoteAgentDescriptor(
                        id: agent.id,
                        displayName: agent.displayName,
                        models: models.map(\.id),
                        isAvailable: true,
                        modelDescriptors: models,
                        defaultModelID: agent.defaultModelID
                    )
                }
                modelPickerSelectedAgentID = selectedAgentID
                modelPickerSelectedModelID = selectedModelID
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
            .disabled(!isModelMutable || availableAgents.isEmpty || isPending)
            .sheet(isPresented: $showsModelPicker) {
                NavigationStack {
                    List {
                        ForEach(modelPickerAgents, id: \.id) { agent in
                            Section(agent.displayName) {
                                ForEach(agent.modelDescriptors ?? [], id: \.id) { candidate in
                                    Button {
                                        onSelectModel(agent.id, candidate.id, candidate.defaultReasoningEffortID)
                                        showsModelPicker = false
                                    } label: {
                                        HStack {
                                            Text(candidate.displayName)
                                            Spacer()
                                            if agent.id == modelPickerSelectedAgentID,
                                               candidate.id == modelPickerSelectedModelID
                                            {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
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

            if !availableEfforts.isEmpty {
                Menu {
                    ForEach(availableEfforts, id: \.id) { effort in
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
                .disabled(!isEffortMutable || isPending)
            }

            if let toolCatalog, selectedAgentID == toolCatalog.providerID {
                RemoteToolsButton(catalog: toolCatalog, isPending: isPending, onToggle: onToggleTool)
            }

            if isPending {
                ProgressView().controlSize(.mini)
            }
        }
        .opacity((isModelMutable || isEffortMutable) ? 1 : 0.58)
        .accessibilityElement(children: .contain)
    }

    private var modelLabel: String {
        let agentName = selectedAgent?.displayName ?? "Agent"
        let modelName = selectedModel?.displayName ?? selectedModelID ?? "Mac default"
        return "\(agentName) · \(modelName)"
    }

    private var effortLabel: String {
        availableEfforts.first(where: { $0.id == selectedReasoningEffortID })?.displayName
            ?? selectedReasoningEffortID?.capitalized
            ?? "Effort"
    }

    private func availableModels(for agent: RemoteAgentDescriptor) -> [RemoteModelDescriptor] {
        agent.modelDescriptors?.filter { model in
            model.isAvailable
                && (agent.id != selectedAgentID || (allowedModelIDs?.contains(model.id) ?? true))
        } ?? []
    }
}

private struct RemoteToolsButton: View {
    let catalog: RemoteToolCatalog
    let isPending: Bool
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
                                        .disabled(!snapshot.isMutable || !setting.isMutable || setting.isRequired)
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
