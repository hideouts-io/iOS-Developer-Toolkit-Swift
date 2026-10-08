import Foundation
import Observation
import ToolkitCore
import ToolkitFeatures

@Observable
@MainActor
final class SecurityAnalysisModel {
    static let intelligenceMaximumBytes = 25 * 1024 * 1024
    static let maximumFiles = 20_000
    static let maximumFileBytes: Int64 = 25 * 1024 * 1024
    static let maximumTotalBytes: Int64 = 512 * 1024 * 1024
    static let maximumSQLiteRows = 25_000

    var acquisitionMethod = SecurityAcquisitionMethod.backup
    var evidenceRoot: URL?
    var intelligence: [IntelligenceBundle] = []
    var selectedTrustedSourceID = TrustedIntelligenceUpdater.sources[0].id
    var report: SecurityAnalysisReport?
    var selectedFindingID: String?
    var investigatorMode = false
    var analysisStatus = "Choose locally stored evidence and optional threat intelligence. Nothing is uploaded."
    var intelligenceStatus = "No threat-intelligence bundle loaded."
    var activeOperation: RunningOperation?

    var selectedFinding: CorrelatedSecurityFinding? {
        guard let selectedFindingID else { return report?.correlatedFindings.first }
        return report?.correlatedFindings.first { $0.id == selectedFindingID }
    }

    var selectedTrustedSource: TrustedIntelligenceSource? {
        TrustedIntelligenceUpdater.sources.first { $0.id == selectedTrustedSourceID }
    }

    var isRunning: Bool { activeOperation != nil }

    func importIntelligence(_ url: URL, app: AppModel) async {
        let importedAt = ISO8601DateFormatter().string(from: Date())
        let maximumBytes = Self.intelligenceMaximumBytes
        let result = await app.run(
            "Import threat intelligence",
            workspace: .securityAnalysis,
            target: nil,
            transport: "Local file",
            argv: [url.path],
            outputPaths: [],
            presentErrors: true,
            onStart: { [weak self] operation in self?.activeOperation = operation }
        ) { _ in
            try ThreatIntelligence.loadLocalFile(
                url,
                sourceName: url.lastPathComponent,
                organization: "Local import",
                sourceURL: nil,
                version: nil,
                commit: nil,
                publishedAt: nil,
                signatureStatus: "not-provided",
                importedAt: importedAt,
                maximumBytes: maximumBytes
            )
        }
        activeOperation = nil
        guard let result else { return }
        replace(result)
        intelligenceStatus = "Imported \(result.indicators.count) indicators from \(result.provenance.sourceName)."
    }

    func updateTrustedSource(app: AppModel) async {
        guard let source = selectedTrustedSource else {
            app.present(ToolkitError.invalidInput("Choose a trusted intelligence source before updating."))
            return
        }
        let cache = Self.intelligenceCacheDirectory()
        let maximumBytes = Self.intelligenceMaximumBytes
        let result = await app.run(
            "Update \(source.name)",
            workspace: .securityAnalysis,
            target: nil,
            transport: "HTTPS commit-pinned download",
            argv: [source.repository, source.branch, source.path],
            outputPaths: [cache.path],
            presentErrors: true,
            onStart: { [weak self] operation in self?.activeOperation = operation }
        ) { operation in
            operation.report("Resolving the latest commit…")
            return try await TrustedIntelligenceUpdater.update(
                source,
                destinationRoot: cache,
                maximumBytes: maximumBytes,
                attempts: 3
            )
        }
        activeOperation = nil
        guard let result else { return }
        replace(result)
        intelligenceStatus = "Updated \(result.provenance.sourceName) at commit \(result.provenance.commit?.prefix(12) ?? "unknown"): \(result.indicators.count) indicators."
    }

    func analyze(app: AppModel) async {
        guard let evidenceRoot else {
            app.present(ToolkitError.invalidInput("Choose evidence before starting Security Analysis."))
            return
        }
        let request = SecurityScanRequest(
            evidenceRoot: evidenceRoot,
            acquisitionMethod: acquisitionMethod,
            intelligence: intelligence,
            maximumFiles: Self.maximumFiles,
            maximumFileBytes: Self.maximumFileBytes,
            maximumTotalBytes: Self.maximumTotalBytes,
            maximumSQLiteRows: Self.maximumSQLiteRows
        )
        report = nil
        selectedFindingID = nil
        analysisStatus = "Analyzing local evidence…"
        let result = await app.run(
            "Security Analysis",
            workspace: .securityAnalysis,
            target: nil,
            transport: acquisitionMethod == .mvtResults ? "Local MVT result normalization" : "Local bounded artifact analysis",
            argv: [acquisitionMethod.rawValue, evidenceRoot.path],
            outputPaths: [],
            presentErrors: true,
            onStart: { [weak self] operation in self?.activeOperation = operation }
        ) { operation in
            operation.report("Reading bounded evidence…")
            return try await SecurityAnalysisEngine.analyze(request)
        }
        activeOperation = nil
        guard let result else {
            analysisStatus = "Analysis did not finish. Review Session Activity for the recorded failure or cancellation."
            return
        }
        report = result
        selectedFindingID = result.correlatedFindings.first?.id
        analysisStatus = result.statusSummary
    }

    func cancel() {
        activeOperation?.cancel()
    }

    func export(_ format: SecurityReportFormat, to destination: URL, app: AppModel) {
        guard let report else {
            app.present(ToolkitError.invalidInput("Run Security Analysis before exporting a report."))
            return
        }
        do {
            try SecurityReportWriter.write(report, format: format, to: destination)
            app.statusMessage = "Saved \(format.rawValue.uppercased()) security report."
        } catch {
            app.present(error)
        }
    }

    func remove(_ bundle: IntelligenceBundle) {
        intelligence.removeAll { $0.id == bundle.id }
        intelligenceStatus = intelligence.isEmpty ? "No threat-intelligence bundle loaded." : "\(intelligence.count) intelligence bundles loaded."
    }

    private func replace(_ bundle: IntelligenceBundle) {
        intelligence.removeAll { $0.provenance.sourceName == bundle.provenance.sourceName }
        intelligence.append(bundle)
        intelligence.sort { $0.provenance.sourceName.localizedCaseInsensitiveCompare($1.provenance.sourceName) == .orderedAscending }
    }

    private static func intelligenceCacheDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(ToolkitVersion.applicationName)/Security Intelligence", isDirectory: true)
    }
}
