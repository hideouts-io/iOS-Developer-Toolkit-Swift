import SwiftUI
import ToolkitCore
import ToolkitFeatures

struct SecurityAnalysisView: View {
    @Environment(AppModel.self) private var app
    @State private var section = SecurityAnalysisSection.overview

    var body: some View {
        @Bindable var security = app.security
        WorkspacePage(workspace: .securityAnalysis) {
            Card(
                title: "Local analysis boundary",
                systemImage: "lock.shield",
                subtitle: "Selected evidence stays on this Mac. Network access occurs only when you explicitly update a listed intelligence source. A non-detection is never presented as proof that a device is clean."
            ) {
                Text(security.analysisStatus)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("security-status")
            }

            Picker("Security Analysis section", selection: $section) {
                ForEach(SecurityAnalysisSection.allCases) { value in
                    Text(value.title)
                        .tag(value)
                        .accessibilityIdentifier("security-section-\(value.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("security-sections")

            sectionView
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch section {
        case .overview: overview
        case .analyze: analyze
        case .findings: findings
        case .intelligence: intelligence
        case .reports: reports
        case .methodology: methodology
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                metric("Evidence", app.security.evidenceRoot?.lastPathComponent ?? "Not selected", "doc.text.magnifyingglass")
                metric("Intelligence", "\(app.security.intelligence.reduce(0) { $0 + $1.indicators.count }) indicators", "scope")
                metric("Coverage", app.security.report.map { "\($0.filesExamined) files" } ?? "Not run", "checklist")
                metric("Findings", "\(app.security.report?.correlatedFindings.count ?? 0) correlated", "exclamationmark.magnifyingglass")
            }
            Card(title: "Recommended workflow", systemImage: "arrow.triangle.branch", subtitle: "Preserve evidence first, document the source, then analyze a copy with current, attributable intelligence.") {
                numbered(1, "Collect or choose evidence", "Use a decrypted local backup, unpacked sysdiagnose, imported file/folder, or existing MVT results.")
                numbered(2, "Load intelligence", "Import a local STIX/JSON file or explicitly update one trusted, commit-pinned source.")
                numbered(3, "Analyze and review", "Treat matches as investigative leads. Inspect coverage warnings, source provenance, and false-positive notes.")
                numbered(4, "Export", "Write a new owner-only JSON, CSV, or self-contained HTML report. Existing files are never overwritten.")
            }
        }
    }

    private var analyze: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Evidence source", systemImage: "externaldrive", subtitle: sourceExplanation) {
                Picker("Acquisition method", selection: Bindable(app.security).acquisitionMethod) {
                    ForEach(SecurityAcquisitionMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .accessibilityIdentifier("security-acquisition-method")
                HStack {
                    Text(app.security.evidenceRoot?.path ?? "No evidence selected")
                        .font(.callout.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Choose File…") { app.security.evidenceRoot = FilePanels.chooseFile(title: "Choose local evidence", allowedExtensions: [], directory: nil) }
                        .disabled(app.security.acquisitionMethod != .importedEvidence)
                        .accessibilityIdentifier("security-choose-file")
                    Button("Choose Folder…") { chooseEvidenceFolder() }
                        .accessibilityIdentifier("security-choose-folder")
                }
                HStack {
                    Button("Open Backup") { app.workspace = .backup }
                    Button("Open Evidence Capture") { app.workspace = .evidence }
                    Spacer()
                    if app.security.isRunning {
                        Button("Stop", role: .destructive) { app.security.cancel() }
                            .accessibilityIdentifier("security-stop")
                    } else {
                        Button("Run Local Analysis") { Task { await app.security.analyze(app: app) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(app.security.evidenceRoot == nil)
                            .accessibilityIdentifier("security-run")
                    }
                }
            }
            DisclosureGroup("Safety limits and coverage") {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow("Maximum files", SecurityAnalysisModel.maximumFiles.formatted())
                    InfoRow("Maximum file size", ByteFormatting.string(SecurityAnalysisModel.maximumFileBytes))
                    InfoRow("Maximum total content", ByteFormatting.string(SecurityAnalysisModel.maximumTotalBytes))
                    InfoRow("Maximum SQLite rows", SecurityAnalysisModel.maximumSQLiteRows.formatted())
                    Text("Files over a limit, inaccessible content, unsupported formats, parser failures, and malformed records remain explicit warnings. Symbolic links are refused.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
            .accessibilityIdentifier("security-limits")
        }
    }

    private var findings: some View {
        Group {
            if let report = app.security.report {
                VStack(alignment: .leading, spacing: 16) {
                    Card(title: "Analysis summary", systemImage: "chart.bar.doc.horizontal", subtitle: report.statusSummary) {
                        HStack {
                            Text("\(report.correlatedFindings.count) correlated findings")
                            Divider().frame(height: 18)
                            Text("\(report.filesExamined) files")
                            Divider().frame(height: 18)
                            Text(ByteFormatting.string(report.bytesExamined))
                        }
                        .font(.callout.monospacedDigit())
                        if !report.acquisitionWarnings.isEmpty {
                            Label("\(report.acquisitionWarnings.count) acquisition warnings require review", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    if report.correlatedFindings.isEmpty {
                        ContentUnavailableView("No known indicators detected", systemImage: "magnifyingglass", description: Text("This applies only to the evidence and intelligence coverage shown above. It is not a clean-device verdict."))
                            .frame(minHeight: 220)
                    } else {
                        HSplitView {
                            List(report.correlatedFindings, selection: Bindable(app.security).selectedFindingID) { finding in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(finding.title).font(.headline).lineLimit(2)
                                    Text("\(finding.severity.rawValue.capitalized) · \(finding.classification.label)")
                                        .font(.caption)
                                        .foregroundStyle(severityColor(finding.severity))
                                    Text(finding.artifactPaths.first ?? "Unknown artifact")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .tag(finding.id)
                            }
                            .frame(minWidth: 260, minHeight: 300)
                            findingDetail
                                .frame(minWidth: 320, minHeight: 300)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No analysis yet", systemImage: "shield.checkered", description: Text("Choose evidence in Analyze, then run the local scanner."))
                    .frame(minHeight: 360)
            }
        }
    }

    private var findingDetail: some View {
        ScrollView {
            if let finding = app.security.selectedFinding {
                VStack(alignment: .leading, spacing: 12) {
                    Text(finding.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(finding.explanation).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    InfoRow("Severity", finding.severity.rawValue.capitalized)
                    InfoRow("Classification", finding.classification.label)
                    InfoRow("Matched indicator", finding.matchedIndicator ?? "—", monospaced: true)
                    InfoRow("Scanners", finding.scannerNames.joined(separator: ", "))
                    InfoRow("Artifacts", finding.artifactPaths.joined(separator: "\n"), monospaced: true)
                    Text("False-positive considerations").font(.headline)
                    ForEach(finding.falsePositiveNotes, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if app.security.investigatorMode {
                        Divider()
                        InfoRow("Correlation ID", finding.correlationID, monospaced: true)
                        InfoRow("Finding IDs", finding.findingIDs.joined(separator: "\n"), monospaced: true)
                        InfoRow("Timestamps", finding.timestamps.joined(separator: "\n"), monospaced: true)
                    }
                    Toggle("Investigator details", isOn: Bindable(app.security).investigatorMode)
                }
                .padding(12)
            } else {
                Text("Choose a finding to inspect.").foregroundStyle(.secondary).padding()
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var intelligence: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Trusted update sources", systemImage: "network.badge.shield.half.filled", subtitle: "Updates happen only when you press the button. GitHub commit metadata is resolved first, then the exact commit-pinned STIX file is downloaded over HTTPS and cached owner-only.") {
                Picker("Source", selection: Bindable(app.security).selectedTrustedSourceID) {
                    ForEach(TrustedIntelligenceUpdater.sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                if let source = app.security.selectedTrustedSource {
                    Text(source.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("\(source.repository)/\(source.path) · \(source.licenseName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                HStack {
                    Button("Update Selected Source") { Task { await app.security.updateTrustedSource(app: app) } }
                        .disabled(app.security.isRunning)
                        .accessibilityIdentifier("security-update-intelligence")
                    Button("Import Local STIX/JSON…") { importIntelligence() }
                        .disabled(app.security.isRunning)
                        .accessibilityIdentifier("security-import-intelligence")
                    if app.security.isRunning { Button("Stop", role: .destructive) { app.security.cancel() } }
                }
                Text(app.security.intelligenceStatus).font(.callout).foregroundStyle(.secondary)
            }
            Card(title: "Loaded intelligence", systemImage: "scope") {
                if app.security.intelligence.isEmpty {
                    Text("No bundles loaded. Native acquisition can still inventory supported artifacts, but it cannot produce an IOC match without indicators.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(app.security.intelligence) { bundle in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bundle.provenance.sourceName).font(.headline)
                            Text("\(bundle.indicators.count) indicators · SHA-256 \(bundle.provenance.sha256)")
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text("Imported \(bundle.provenance.importedAt) · signature \(bundle.provenance.signatureStatus)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Remove") { app.security.remove(bundle) }
                    }
                    Divider()
                }
            }
        }
    }

    private var reports: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Export investigation report", systemImage: "square.and.arrow.up", subtitle: "Reports include scanner status, evidence coverage, intelligence provenance, correlation, limitations, and the explicit no-clean-verdict boundary.") {
                if let report = app.security.report {
                    InfoRow("Analysis ID", report.analysisID, monospaced: true)
                    InfoRow("Evidence", report.evidenceRoot, monospaced: true)
                    HStack {
                        exportButton("JSON", format: .json)
                        exportButton("CSV", format: .csv)
                        exportButton("HTML", format: .html)
                    }
                } else {
                    Text("Run an analysis before exporting a report.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("security-reports-empty")
                }
            }
        }
    }

    private var methodology: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "What the native scanner does", systemImage: "doc.text.magnifyingglass") {
                bullet("Opens a decrypted iOS backup through its Manifest.db in immutable, read-only SQLite mode.")
                bullet("Inventories bounded local files without following symbolic links or accepting unsafe backup file IDs.")
                bullet("Extracts path, filename, bounded text, plist, JSON, SQLite-row, and requested cryptographic-hash observations.")
                bullet("Matches exact supported IOC types and correlates shared indicators across artifacts.")
                bullet("Normalizes existing MVT *_detected.json output without bundling or reimplementing MVT.")
            }
            Card(title: "What it does not establish", systemImage: "exclamationmark.shield") {
                bullet("A match is not standalone proof of infection, attribution, persistence, or compromise.")
                bullet("A non-match is not proof that a device is clean.")
                bullet("Unavailable, encrypted, oversized, malformed, unsupported, or uncollected artifacts remain coverage gaps.")
                bullet("The toolkit does not jailbreak iOS, bypass a passcode, decrypt protected traffic, or expose an unrestricted filesystem.")
            }
            Card(title: "Supported IOC subset", systemImage: "curlybraces") {
                Text(SecurityIndicatorType.allCases.map(\.rawValue).joined(separator: ", "))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("STIX support is intentionally limited to equality comparisons joined by OR. AND, LIKE, MATCHES, IN, NOT, temporal, and behavioral expressions are rejected or recorded as skipped warnings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceExplanation: String {
        switch app.security.acquisitionMethod {
        case .backup: return "Choose the device-specific folder containing Manifest.db from a decrypted local backup."
        case .sysdiagnose: return "Choose an already unpacked sysdiagnose folder. Archives are not extracted implicitly."
        case .importedEvidence: return "Choose one regular file or a local folder of artifacts."
        case .mvtResults: return "Choose an existing MVT output folder containing *_detected.json files. MVT remains independently installed and run."
        }
    }

    private var statusColor: Color {
        guard let report = app.security.report else { return .secondary }
        if report.scannerExecutions.contains(where: { $0.status != .completed }) { return .orange }
        if report.correlatedFindings.contains(where: { $0.severity == .critical || $0.severity == .high }) { return .red }
        return report.correlatedFindings.isEmpty ? .secondary : .orange
    }

    private func chooseEvidenceFolder() {
        app.security.evidenceRoot = FilePanels.chooseFolder(title: "Choose local evidence", directory: app.security.evidenceRoot, canCreate: false)
    }

    private func importIntelligence() {
        guard let url = FilePanels.chooseFile(title: "Import STIX or JSON intelligence", allowedExtensions: ["stix2", "stix", "json"], directory: nil) else { return }
        Task { await app.security.importIntelligence(url, app: app) }
    }

    private func exportButton(_ title: String, format: SecurityReportFormat) -> some View {
        Button("Export \(title)…") {
            guard let destination = FilePanels.save(
                title: "Export \(title) security report",
                suggestedName: "security-analysis.\(format.rawValue)",
                allowedExtension: format.rawValue,
                directory: nil
            ) else { return }
            app.security.export(format, to: destination, app: app)
        }
        .accessibilityIdentifier("security-export-\(format.rawValue)")
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        Card(title: title, systemImage: symbol) {
            Text(value).font(.title3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
        }
    }

    private func numbered(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.bold()).frame(width: 22, height: 22).background(.blue.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func severityColor(_ severity: SecurityFindingSeverity) -> Color {
        switch severity {
        case .informational: return .secondary
        case .low: return .blue
        case .medium: return .orange
        case .high, .critical: return .red
        }
    }
}

private enum SecurityAnalysisSection: String, CaseIterable, Identifiable {
    case overview
    case analyze
    case findings
    case intelligence
    case reports
    case methodology

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .analyze: return "Analyze"
        case .findings: return "Findings"
        case .intelligence: return "Intelligence"
        case .reports: return "Reports"
        case .methodology: return "Methodology"
        }
    }
}
