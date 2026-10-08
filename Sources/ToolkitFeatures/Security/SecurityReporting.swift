import Foundation
import ToolkitCore

public enum SecurityReportFormat: String, CaseIterable, Sendable, Identifiable {
    case json
    case csv
    case html

    public var id: String { rawValue }
}

public enum SecurityReportWriter {
    public static func write(_ report: SecurityAnalysisReport, format: SecurityReportFormat, to destination: URL) throws {
        let expectedExtensions: Set<String>
        switch format {
        case .json: expectedExtensions = ["json"]
        case .csv: expectedExtensions = ["csv"]
        case .html: expectedExtensions = ["html", "htm"]
        }
        guard expectedExtensions.contains(destination.pathExtension.lowercased()) else {
            throw ToolkitError.invalidInput("The \(format.rawValue.uppercased()) report name must end in \(expectedExtensions.sorted().map { "." + $0 }.joined(separator: " or ")).")
        }
        let data: Data
        switch format {
        case .json: data = try renderJSON(report)
        case .csv: data = Data(renderCSV(report).utf8)
        case .html: data = Data(renderHTML(report).utf8)
        }
        try SecureFileIO.writeNewFile(data, to: destination)
    }

    public static func renderJSON(_ report: SecurityAnalysisReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report) + Data("\n".utf8)
    }

    public static func renderCSV(_ report: SecurityAnalysisReport) -> String {
        let header = [
            "analysis_id", "started_at", "finished_at", "acquisition_method", "evidence_root",
            "files_examined", "bytes_examined", "scanner_statuses", "acquisition_warnings", "limitations",
            "correlation_id", "title", "severity", "classification", "matched_indicator",
            "indicator_type", "scanners", "artifact_paths", "timestamps", "finding_ids",
            "explanation", "false_positive_notes",
        ]
        let reportFields = [
            report.analysisID,
            report.startedAt,
            report.finishedAt,
            report.acquisitionMethod.rawValue,
            report.evidenceRoot,
            String(report.filesExamined),
            String(report.bytesExamined),
            report.scannerExecutions.map { "\($0.metadata.name)=\($0.status.rawValue)" }.joined(separator: "; "),
            report.acquisitionWarnings.joined(separator: "; "),
            report.limitations.joined(separator: "; "),
        ]
        let findingRows = report.correlatedFindings.map { finding in
            reportFields + [
                finding.correlationID,
                finding.title,
                finding.severity.rawValue,
                finding.classification.rawValue,
                finding.matchedIndicator ?? "",
                finding.indicatorType?.rawValue ?? "",
                finding.scannerNames.joined(separator: "; "),
                finding.artifactPaths.joined(separator: "; "),
                finding.timestamps.joined(separator: "; "),
                finding.findingIDs.joined(separator: "; "),
                finding.explanation,
                finding.falsePositiveNotes.joined(separator: "; "),
            ]
        }
        let rows = findingRows.isEmpty ? [reportFields + Array(repeating: "", count: header.count - reportFields.count)] : findingRows
        return ([header] + rows).map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    public static func renderHTML(_ report: SecurityAnalysisReport) -> String {
        let findingRows: String
        if report.correlatedFindings.isEmpty {
            findingRows = #"<tr><td colspan="6">No findings in analyzed coverage.</td></tr>"#
        } else {
            findingRows = report.correlatedFindings.map { finding in
                "<tr><td>\(html(finding.severity.rawValue))</td><td>\(html(finding.classification.rawValue))</td><td>\(html(finding.title))</td><td>\(html(finding.scannerNames.joined(separator: ", ")))</td><td>\(html(finding.artifactPaths.joined(separator: "; ")))</td><td>\(html(finding.explanation))</td></tr>"
            }.joined()
        }
        let scanners = report.scannerExecutions.map { execution in
            let error = execution.errorMessage.map { ": \(html($0))" } ?? ""
            return "<li>\(html(execution.metadata.name)) \(html(execution.metadata.version)) — \(html(execution.status.rawValue))\(error)</li>"
        }.joined()
        let intelligence = report.intelligence.isEmpty
            ? "<li>No external intelligence bundle was used.</li>"
            : report.intelligence.map { bundle in
                "<li>\(html(bundle.provenance.sourceName)) — \(bundle.indicators.count) indicators; SHA-256 <code>\(html(bundle.provenance.sha256))</code>; signature \(html(bundle.provenance.signatureStatus))</li>"
            }.joined()
        let acquisitionWarnings = report.acquisitionWarnings.isEmpty
            ? "<li>No acquisition warnings were recorded.</li>"
            : report.acquisitionWarnings.map { "<li>\(html($0))</li>" }.joined()
        let limitations = report.limitations.map { "<li>\(html($0))</li>" }.joined()
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>iOS Security Analysis \(html(report.analysisID))</title>
        <style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;max-width:1100px;margin:32px auto;padding:0 20px;color:#18202d}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccd3df;padding:8px;text-align:left;vertical-align:top}th{background:#eef3fa}code{word-break:break-all}.status{padding:12px;border-left:5px solid #3f6fb6;background:#eef5ff}</style>
        </head><body><h1>iOS Security Analysis</h1><p class="status">\(html(report.statusSummary))</p>
        <h2>Executive Summary</h2><p>Analysis ID: <code>\(html(report.analysisID))</code><br>
        Evidence: <code>\(html(report.evidenceRoot))</code><br>Method: \(html(report.acquisitionMethod.rawValue))<br>
        Files examined: \(report.filesExamined); bytes examined: \(report.bytesExamined); correlated findings: \(report.correlatedFindings.count)</p>
        <h2>Scanner Versions and Status</h2><ul>\(scanners)</ul><h2>Acquisition Warnings</h2><ul>\(acquisitionWarnings)</ul><h2>Threat Intelligence</h2><ul>\(intelligence)</ul>
        <h2>Correlated Findings</h2><table><thead><tr><th>Severity</th><th>Classification</th><th>Finding</th><th>Detected by</th><th>Evidence</th><th>Explanation</th></tr></thead><tbody>\(findingRows)</tbody></table>
        <h2>Methodology</h2><p>Evidence was read locally with bounded parsers. Scanner output was normalized and findings sharing a correlation key were merged into one investigative event. No evidence was uploaded.</p>
        <h2>Limitations</h2><ul>\(limitations)</ul></body></html>
        """
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func html(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
