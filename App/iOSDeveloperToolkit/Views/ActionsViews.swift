import DeviceKit
import SwiftUI
import ToolkitCore
import ToolkitFeatures

/// Presentation groups keep the native catalog and saved profile categories unchanged.
private enum GuidedCommandCategory: String, CaseIterable, Identifiable {
    case deviceBasics = "Device Basics"
    case appsAndFiles = "Apps & Files"
    case loggingAndCapture = "Logging & Capture"
    case developerAndDVT = "Developer & DVT"
    case webAndDiscovery = "Web & Discovery"
    case deviceActions = "Device Actions"
    case simulator = "Simulator"

    var id: String {
        switch self {
        case .deviceBasics: return "device-basics"
        case .appsAndFiles: return "apps-files"
        case .loggingAndCapture: return "logging-capture"
        case .developerAndDVT: return "developer-dvt"
        case .webAndDiscovery: return "web-discovery"
        case .deviceActions: return "device-actions"
        case .simulator: return "simulator"
        }
    }

    var profileCategory: String {
        switch self {
        case .deviceBasics, .appsAndFiles, .deviceActions, .simulator: return rawValue
        case .webAndDiscovery: return "Network & Discovery"
        case .loggingAndCapture, .developerAndDVT: return "All"
        }
    }

    func contains(_ action: ActionDescriptor) -> Bool {
        switch self {
        case .deviceBasics, .appsAndFiles, .deviceActions, .simulator:
            return action.category == rawValue
        case .loggingAndCapture:
            return action.category == "Capture & Instruments" && ["sysdiagnose", "packet-capture", "bluetooth-capture"].contains(action.id)
        case .developerAndDVT:
            return action.category == "Developer Services" || (action.category == "Capture & Instruments" && ["screenshot", "instruments"].contains(action.id))
        case .webAndDiscovery:
            return action.category == "Network & Discovery"
        }
    }
}

private enum GuidedCommandFilter: Hashable {
    case all
    case category(GuidedCommandCategory)
    case savedCategory(String)

    static func saved(_ category: String) -> GuidedCommandFilter {
        if category == "All" { return .all }
        if let group = GuidedCommandCategory.allCases.first(where: { $0.profileCategory == category }) {
            return .category(group)
        }
        return .savedCategory(category)
    }

    var profileCategory: String {
        switch self {
        case .all: return "All"
        case .category(let category): return category.profileCategory
        case .savedCategory(let category): return category
        }
    }

    func contains(_ action: ActionDescriptor) -> Bool {
        switch self {
        case .all: return true
        case .category(let category): return category.contains(action)
        case .savedCategory(let category): return action.category == category
        }
    }
}

struct ActionsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selectedFilter: GuidedCommandFilter?
    @State private var writtenProfileCategory: String?

    private var filter: GuidedCommandFilter {
        selectedFilter ?? GuidedCommandFilter.saved(model.actionsCategory)
    }

    private var actions: [ActionDescriptor] {
        ActionCatalog.all.filter { action in
            filter.contains(action)
                && (search.isEmpty || action.title.localizedCaseInsensitiveContains(search) || action.summary.localizedCaseInsensitiveContains(search) || (action.replacesLegacy ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search guided commands", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("command-search")
                Picker("Category", selection: Binding(get: { filter }, set: { selectFilter($0) })) {
                    Text("All categories").tag(GuidedCommandFilter.all)
                    ForEach(GuidedCommandCategory.allCases) { category in
                        Text(category.rawValue)
                            .tag(GuidedCommandFilter.category(category))
                            .accessibilityIdentifier("command-category-\(category.id)")
                    }
                    if case .savedCategory(let category) = filter {
                        Text("\(category) (saved filter)").tag(GuidedCommandFilter.savedCategory(category))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("command-categories")
                List(selection: $model.selectedActionID) {
                    ForEach(GuidedCommandCategory.allCases.filter { category in actions.contains { category.contains($0) } }) { category in
                        Section(category.rawValue) {
                            ForEach(actions.filter { category.contains($0) }) { action in
                                ActionListRow(action: action, device: model.selectedDevice)
                                    .tag(action.id)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("actions-list")
                Button {
                    model.openAdvancedMode()
                } label: {
                    Label("Advanced Mode (devicectl)…", systemImage: "terminal")
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .frame(width: 270)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TargetHeader()
                    Text("This app provides \(ActionCatalog.all.count) native actions; Python's 49 presets are not all available here. Direct Python DVT telemetry streams and DVT path listing are unavailable. Use Instruments recording for supported performance telemetry. Simulator actions are additional Swift features.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("command-coverage-note")
                    if let id = model.selectedActionID, let action = ActionCatalog.descriptor(id) {
                        ActionDetailView(action: action)
                            .id(action.id)
                    } else {
                        ContentUnavailableView("Choose an Action", systemImage: "bolt", description: Text("Actions are grouped by what they do. Each one shows its risk, what it needs, and exactly how it runs before anything happens."))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: model.actionsCategory) { _, category in
            if category != writtenProfileCategory {
                selectedFilter = nil
                writtenProfileCategory = nil
            }
        }
        .onChange(of: model.selectedActionID) { _, identifier in
            if let identifier, let action = ActionCatalog.descriptor(identifier), !filter.contains(action) {
                selectedFilter = nil
                writtenProfileCategory = nil
            }
        }
        .onChange(of: model.actionsNavigationID) { _, _ in
            selectedFilter = nil
            writtenProfileCategory = nil
            search = ""
        }
    }

    private func selectFilter(_ filter: GuidedCommandFilter) {
        selectedFilter = filter
        let category = filter.profileCategory
        let action = model.selectedActionID.flatMap(ActionCatalog.descriptor)
        // A combined presentation filter is stored as All; profile validation still compares
        // the selected action with its unchanged native catalog category.
        let profileCategory = action.map { category == "All" || $0.category == category ? category : "All" } ?? category
        writtenProfileCategory = profileCategory
        model.actionsCategory = profileCategory
    }
}

struct ActionListRow: View {
    let action: ActionDescriptor
    let device: Device?

    var body: some View {
        let available = device.map { action.supports($0.kind) && $0.kind != .demo } ?? false
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(action.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: action.risk.symbolName)
                .foregroundStyle(action.risk == .readOnly ? Color.secondary : (action.risk == .highImpact ? Color.red : Color.orange))
                .help(action.risk.label)
        }
        .opacity(available ? 1 : 0.5)
        // One element per row: otherwise the identifier is copied onto the title, summary, and
        // risk icon, and VoiceOver reads them as three separate items.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityValue(available ? action.risk.label : "\(action.risk.label), not available for this device")
        .accessibilityHint(action.summary)
        .accessibilityIdentifier("action-\(action.id)")
    }
}

struct ActionDetailView: View {
    @Environment(AppModel.self) private var model
    let action: ActionDescriptor
    @State private var values: [String: String] = [:]
    @State private var result: ActionResult?
    @State private var confirmation: PendingConfirmation?
    private var isRunning: Bool {
        model.operations.contains { $0.title == action.title }
    }

    var body: some View {
        let device = model.selectedDevice
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(action.title).font(.title2.bold())
                Spacer()
                RiskBadge(risk: action.risk)
            }
            Text(action.summary).font(.title3)
            if !action.notes.isEmpty {
                Text(action.notes).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card(title: "How it runs", systemImage: "gearshape.2") {
                InfoRow("Mechanism", action.mechanism, monospaced: true)
                InfoRow("Works with", action.kinds.map(\.label).sorted().joined(separator: ", "))
                if let legacy = action.replacesLegacy {
                    InfoRow("Replaces", legacy, explanation: "The pymobiledevice3 command this action replaced in version 0.3.", monospaced: true)
                }
                if !action.requirements.isEmpty {
                    InfoRow("Needs", action.requirements.map(\.label).joined(separator: " · "))
                }
                ReadinessStatusView(requirements: action.requirements, device: device, subject: "this action")
            }
            if !action.parameters.isEmpty {
                Card(title: "Details", systemImage: "slider.horizontal.3") {
                    ForEach(action.parameters) { parameter in
                        ParameterField(parameter: parameter, value: Binding(get: { values[parameter.id] ?? parameter.defaultValue }, set: { values[parameter.id] = $0 }))
                    }
                }
            }
            HStack {
                Button {
                    request(device)
                } label: {
                    Label(isRunning ? "Running…" : "Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || !canRun(device))
                .accessibilityIdentifier("run-action")
                if isRunning { ProgressView().controlSize(.small) }
                if let reason = blockReason(device) {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let result {
                ActionResultView(result: result)
            }
        }
        .sheet(item: $confirmation) { pending in
            ConfirmationSheet(title: pending.title, detail: pending.detail, requirement: pending.requirement, target: pending.target, commandPreview: pending.commandPreview, onConfirm: pending.action)
        }
    }

    private func canRun(_ device: Device?) -> Bool { blockReason(device) == nil }

    private func blockReason(_ device: Device?) -> String? {
        guard let device else {
            return action.requirements.contains(where: { $0 != .xcode }) ? "Select a device first." : nil
        }
        if device.kind == .demo { return "Actions are disabled in Demo Mode." }
        if !action.supports(device.kind) { return "Not available for \(device.kind.label.lowercased())s." }
        return nil
    }

    private func request(_ device: Device?) {
        let target = device?.target
        let requirement = ConfirmationRequirement.make(for: action.risk, target: target)
        let resolvedValues = action.parameters.reduce(into: [String: String]()) { $0[$1.id] = values[$1.id] ?? $1.defaultValue }
        do {
            _ = try ActionCatalog.validate(action, values: resolvedValues)
        } catch {
            model.present(error)
            return
        }
        if requirement.risk == .readOnly {
            run(target, resolvedValues)
        } else {
            confirmation = PendingConfirmation(title: action.title, detail: "\(action.risk.explanation)\n\n\(action.summary)", requirement: requirement, target: target, commandPreview: action.mechanism) {
                run(target, resolvedValues)
            }
        }
    }

    private func run(_ target: DeviceTarget?, _ values: [String: String]) {
        let executor = model.executor
        let action = self.action
        Task {
            guard !isRunning else { return }
            let outcome = await model.run(action.title, workspace: .actions, target: target, transport: action.mechanism, outputPaths: action.parameters.filter { $0.kind == .outputFile || $0.kind == .outputDirectory }.compactMap { values[$0.id] }) { _ in
                try await executor.execute(action, target: target, values: values)
            }
            if let outcome { result = outcome }
        }
    }
}

struct ParameterField: View {
    let parameter: ActionParameter
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.label).frame(width: 150, alignment: .leading)
                switch parameter.kind {
                case .template:
                    Picker(parameter.label, selection: $value) {
                        ForEach(parameter.choices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                case .outputFile:
                    TextField(parameter.label, text: $value).textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        let current = URL(fileURLWithPath: value)
                        if let url = FilePanels.save(title: parameter.label, suggestedName: current.lastPathComponent, allowedExtension: parameter.fileExtension ?? "", directory: current.deletingLastPathComponent()) {
                            value = url.path
                        }
                    }
                case .outputDirectory:
                    TextField(parameter.label, text: $value).textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        if let url = FilePanels.chooseFolder(title: parameter.label, directory: URL(fileURLWithPath: value)) { value = url.path }
                    }
                default:
                    TextField(parameter.label, text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(parameter.kind == .text ? .body : .body.monospaced())
                }
            }
            if !parameter.help.isEmpty {
                Text(parameter.help).font(.caption).foregroundStyle(.secondary).padding(.leading, 150)
            }
        }
    }
}

struct ActionResultView: View {
    let result: ActionResult

    var body: some View {
        Card(title: "Result", systemImage: "checkmark.circle") {
            Text(result.summary).font(.title3)
            if !result.details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.details.prefix(400).enumerated()), id: \.offset) { _, detail in
                        InfoRow(detail.0, detail.1)
                    }
                    if result.details.count > 400 {
                        Text("\(result.details.count - 400) more rows are in the raw output.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !result.outputFiles.isEmpty {
                HStack {
                    ForEach(result.outputFiles, id: \.self) { url in
                        Button("Show \(url.lastPathComponent) in Finder") { FilePanels.reveal(url) }
                    }
                }
            }
            if !result.raw.isEmpty {
                DisclosureGroup("Raw output") {
                    RawOutputView(text: result.raw)
                    Button("Copy Raw Output") { Pasteboard.copy(result.raw) }.controlSize(.small)
                }
            }
            Text("Finished \(result.finishedAt.formatted(date: .omitted, time: .standard)) · \(String(format: "%.1f", result.finishedAt.timeIntervalSince(result.startedAt))) s · \(result.target?.shortLabel ?? "This Mac")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Free-form devicectl arguments, always bound to the selected device and classified by risk.
struct AdvancedModeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var output = ""
    @State private var confirmation: PendingConfirmation?
    private var isRunning: Bool {
        model.operations.contains { $0.title == "devicectl (Advanced Mode)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Mode").font(.title2.bold())
            Text("Runs `xcrun devicectl` with the arguments you type — without a shell, so pipes, redirects, and substitutions are plain text. Device commands always target the selected device; the toolkit adds `--device` for you and refuses any other device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("devicectl").font(.body.monospaced()).foregroundStyle(.secondary)
                TextField("device info apps", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(prepare)
                Button("Run", action: prepare).disabled(isRunning || text.isEmpty)
            }
            if let prepared = try? ActionExecutor.prepareAdvanced(text, target: model.selectedTarget) {
                HStack {
                    RiskBadge(risk: prepared.risk)
                    Text("devicectl " + prepared.arguments.map(ShellQuoting.quote).joined(separator: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            RawOutputView(text: output, maxHeight: .infinity)
                .frame(minHeight: 240)
            HStack {
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .onAppear { text = model.advancedModeText }
        .onChange(of: text) { _, value in model.advancedModeText = value }
        .sheet(item: $confirmation) { pending in
            ConfirmationSheet(title: pending.title, detail: pending.detail, requirement: pending.requirement, target: pending.target, commandPreview: pending.commandPreview, onConfirm: pending.action)
        }
    }

    private func prepare() {
        do {
            let prepared = try ActionExecutor.prepareAdvanced(text, target: model.selectedTarget)
            let target = model.selectedTarget
            let preview = "xcrun devicectl " + prepared.arguments.map(ShellQuoting.quote).joined(separator: " ")
            if prepared.risk == .readOnly {
                execute(prepared.arguments, target)
            } else {
                confirmation = PendingConfirmation(title: "Run this devicectl command?", detail: prepared.risk.explanation, requirement: .make(for: prepared.risk, target: target), target: target, commandPreview: preview) {
                    execute(prepared.arguments, target)
                }
            }
        } catch {
            model.present(error)
        }
    }

    private func execute(_ arguments: [String], _ target: DeviceTarget?) {
        let executor = model.executor
        Task {
            guard !isRunning else { return }
            let result = await model.run("devicectl (Advanced Mode)", workspace: .actions, target: target, transport: "xcrun devicectl", argv: arguments) { _ in
                try await executor.runAdvanced(arguments: arguments)
            }
            if let result {
                output = result.standardOutputText + (result.standardErrorText.isEmpty ? "" : "\n" + result.standardErrorText) + "\n[exit status \(result.exitCode.map(String.init) ?? "signal")]"
            }
        }
    }
}
