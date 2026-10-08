import Foundation
import ToolkitCore

public enum SecurityAnalysisEngine {
    public static func analyze(_ request: SecurityScanRequest) async throws -> SecurityAnalysisReport {
        try validate(request)
        let worker = Task.detached(priority: .userInitiated) { try analyzeSynchronously(request) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func matches(_ observation: EvidenceObservation, indicator: SecurityIndicator) -> Bool {
        let expected = normalize(indicator.type, indicator.value)
        let actual = normalize(indicator.type, observation.observedValue)
        guard !expected.isEmpty else { return false }
        switch indicator.type {
        case .md5: return observation.observedType == "md5" && actual == expected
        case .sha1: return observation.observedType == "sha1" && actual == expected
        case .sha256, .certificateSHA256: return observation.observedType == "sha256" && actual == expected
        case .filename: return observation.observedType == "filename" && actual == expected
        case .path: return observation.observedType == "path" && (actual == expected || actual.hasSuffix("/" + expected))
        default: break
        }
        guard observation.observedType == "text" else { return false }
        let text = observation.observedValue
        switch indicator.type {
        case .domain:
            return regexMatches(#"(?i)(?<![A-Za-z0-9.-])(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}(?![A-Za-z0-9.-])"#, in: text).contains { domain in
                let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return normalized == expected || normalized.hasSuffix("." + expected)
            }
        case .url: return text.lowercased().contains(expected)
        case .ipv4, .ipv6: return boundedMatch(expected, characterClass: "0-9A-Fa-f:.", text: text)
        case .email: return boundedMatch(expected, characterClass: "A-Za-z0-9._%+@-", text: text)
        case .phone:
            return regexMatches(#"(?<!\w)\+?\d[\d\s().-]{6,}\d(?!\w)"#, in: text).contains { normalize(.phone, $0) == expected }
        case .bundleID, .process, .configurationProfileID:
            return boundedMatch(expected, characterClass: "A-Za-z0-9_.-", text: text)
        case .filename, .path, .md5, .sha1, .sha256, .certificateSHA256: return false
        }
    }

    public static func correlate(_ findings: [SecurityFinding]) -> [CorrelatedSecurityFinding] {
        Dictionary(grouping: findings, by: \SecurityFinding.correlationKey).sorted { $0.key < $1.key }.map { key, values in
            let severity = values.max(by: { $0.severity.rank < $1.severity.rank })?.severity ?? .informational
            let classification = values.max(by: { $0.classification.rank < $1.classification.rank })?.classification ?? .informational
            let first = values[0]
            let title = first.matchedIndicator.map { "\((first.indicatorType?.rawValue ?? "IOC").replacingOccurrences(of: "-", with: " ").capitalized): \($0)" } ?? first.category.replacingOccurrences(of: "-", with: " ").capitalized
            return CorrelatedSecurityFinding(
                correlationID: String(SecureFileIO.sha256(of: Data(key.utf8)).prefix(20)),
                title: title,
                severity: severity,
                classification: classification,
                matchedIndicator: first.matchedIndicator,
                indicatorType: first.indicatorType,
                scannerNames: unique(values.map(\.scanner)).sorted(),
                artifactPaths: unique(values.map(\.artifactPath)).sorted(),
                timestamps: unique(values.compactMap(\.timestamp)).sorted(),
                findingIDs: values.map(\.id),
                explanation: unique(values.map(\.explanation)).joined(separator: " "),
                falsePositiveNotes: unique(values.map(\.falsePositiveNotes))
            )
        }.sorted {
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank > $1.severity.rank }
            if $0.classification.rank != $1.classification.rank { return $0.classification.rank > $1.classification.rank }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func analyzeSynchronously(_ request: SecurityScanRequest) throws -> SecurityAnalysisReport {
        let startedAt = timestamp()
        let execution: SecurityScannerExecution
        do {
            execution = request.acquisitionMethod == .mvtResults ? try scanMVT(request) : try scanNative(request)
        } catch is CancellationError {
            let metadata = request.acquisitionMethod == .mvtResults ? mvtMetadata : nativeMetadata
            execution = SecurityScannerExecution(metadata: metadata, status: .cancelled, findings: [], warnings: [], errorMessage: "Security analysis was cancelled by the user.", startedAt: startedAt, finishedAt: timestamp(), filesExamined: 0, bytesExamined: 0)
        } catch {
            let metadata = request.acquisitionMethod == .mvtResults ? mvtMetadata : nativeMetadata
            execution = SecurityScannerExecution(metadata: metadata, status: .failed, findings: [], warnings: [], errorMessage: "\(type(of: error)): \((error as? ToolkitError)?.message ?? error.localizedDescription)", startedAt: startedAt, finishedAt: timestamp(), filesExamined: 0, bytesExamined: 0)
        }
        let finishedAt = timestamp()
        let findings = execution.findings
        let identity = "\(request.evidenceRoot.standardizedFileURL.path)\u{0}\(request.acquisitionMethod.rawValue)\u{0}\(startedAt)\u{0}\(finishedAt)"
        return SecurityAnalysisReport(
            schemaVersion: 1,
            analysisID: String(SecureFileIO.sha256(of: Data(identity.utf8)).prefix(20)),
            startedAt: startedAt,
            finishedAt: finishedAt,
            evidenceRoot: request.evidenceRoot.standardizedFileURL.path,
            acquisitionMethod: request.acquisitionMethod,
            intelligence: request.intelligence,
            scannerExecutions: [execution],
            findings: findings,
            correlatedFindings: correlate(findings),
            filesExamined: execution.filesExamined,
            bytesExamined: execution.bytesExamined,
            acquisitionWarnings: execution.warnings.filter { !$0.hasPrefix("ACQUISITION files=") },
            limitations: [
                "No result can guarantee that an iPhone or iPad is clean or uncompromised.",
                "IOC matches are investigative leads and require manual validation against context and independent evidence.",
                "The native scanner reads only supported, bounded artifacts available in the selected evidence source.",
                "Encrypted or unavailable artifacts, unsupported STIX semantics, and parser failures remain explicit coverage gaps.",
                "MVT results are normalized only from an independently generated output folder; MVT is not bundled or reimplemented.",
            ]
        )
    }

    private static func scanNative(_ request: SecurityScanRequest) throws -> SecurityScannerExecution {
        let startedAt = timestamp()
        let indicators = request.intelligence.flatMap(\.indicators)
        let acquisition = try SecurityEvidenceAcquisition.acquire(request, hashTypes: indicators.map(\.type))
        var findings: [SecurityFinding] = []
        var seen = Set<String>()
        for observation in acquisition.observations {
            try Task.checkCancellation()
            for indicator in indicators where matches(observation, indicator: indicator) {
                let key = "\(indicator.id)\u{0}\(observation.artifactPath)\u{0}\(observation.table ?? "")\u{0}\(observation.recordID ?? "")"
                guard seen.insert(key).inserted else { continue }
                findings.append(nativeFinding(observation, indicator: indicator))
            }
        }
        return SecurityScannerExecution(metadata: nativeMetadata, status: .completed, findings: findings, warnings: acquisition.warnings + ["ACQUISITION files=\(acquisition.filesExamined) bytes=\(acquisition.bytesExamined)"], errorMessage: nil, startedAt: startedAt, finishedAt: timestamp(), filesExamined: acquisition.filesExamined, bytesExamined: acquisition.bytesExamined)
    }

    private static func scanMVT(_ request: SecurityScanRequest) throws -> SecurityScannerExecution {
        let startedAt = timestamp()
        let root = request.evidenceRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ToolkitError.invalidInput("MVT results must be a folder.") }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else { throw ToolkitError.invalidInput("The MVT results folder must not be a symbolic link.") }
        let allCandidates = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter { $0.lastPathComponent.hasSuffix("_detected.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let candidates = Array(allCandidates.prefix(request.maximumFiles))
        var warnings: [String] = []
        if allCandidates.count > candidates.count {
            warnings.append("MVT result inventory stopped at the \(request.maximumFiles)-file safety limit.")
        }
        var files: [URL] = []
        for candidate in candidates {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { warnings.append("Skipped \(candidate.lastPathComponent): symbolic links are not accepted as MVT result evidence."); continue }
            guard values.isRegularFile == true, candidate.standardizedFileURL.path.hasPrefix(root.path + "/") else { warnings.append("Skipped \(candidate.lastPathComponent): path is not a safely contained regular file."); continue }
            files.append(candidate)
        }
        var findings: [SecurityFinding] = []
        var bytes: Int64 = 0
        var filesExamined = 0
        for file in files {
            try Task.checkCancellation()
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size <= request.maximumFileBytes else { warnings.append("Skipped \(file.lastPathComponent): file exceeds the \(request.maximumFileBytes)-byte per-file safety limit."); continue }
            guard bytes <= request.maximumTotalBytes - size else {
                warnings.append("MVT result import stopped at the \(request.maximumTotalBytes)-byte total safety limit.")
                break
            }
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            let payload = try JSONValue.parse(data)
            let records = payload.array ?? [payload]
            for (index, record) in records.enumerated() { findings.append(mvtFinding(file, record: record, index: index + 1)) }
            bytes += size
            filesExamined += 1
        }
        if files.isEmpty { warnings.append("No *_detected.json files were found. This means no MVT detection output was imported; it does not prove the device is clean.") }
        return SecurityScannerExecution(metadata: mvtMetadata, status: .completed, findings: findings, warnings: warnings, errorMessage: nil, startedAt: startedAt, finishedAt: timestamp(), filesExamined: filesExamined, bytesExamined: bytes)
    }

    private static func nativeFinding(_ observation: EvidenceObservation, indicator: SecurityIndicator) -> SecurityFinding {
        let highConfidence = (indicator.confidence ?? 0) >= 70
        let normalized = normalize(indicator.type, indicator.value)
        let identity = "native-ioc\u{0}\(indicator.id)\u{0}\(indicator.type.rawValue)\u{0}\(observation.artifactPath)\u{0}\(observation.table ?? "")\u{0}\(observation.recordID ?? "")"
        return SecurityFinding(
            id: String(SecureFileIO.sha256(of: Data(identity.utf8)).prefix(20)),
            scanner: nativeMetadata.name,
            scannerVersion: nativeMetadata.version,
            category: "known-indicator-match",
            severity: highConfidence ? .high : .medium,
            classification: highConfidence ? .highConfidenceIOCMatch : .iocMatch,
            artifactType: observation.artifactType,
            artifactPath: observation.artifactPath,
            database: observation.database,
            table: observation.table,
            recordID: observation.recordID,
            timestamp: observation.timestamp,
            observedValue: excerpt(observation.observedValue, needle: indicator.value),
            matchedIndicator: indicator.value,
            indicatorType: indicator.type,
            iocSource: indicator.provenance.sourceName,
            iocID: indicator.id,
            iocVersion: indicator.provenance.version ?? indicator.provenance.commit,
            explanation: "\(indicator.name) matched a published \(indicator.type.rawValue) indicator in \(observation.artifactPath). A match is an investigative lead, not standalone proof of compromise.",
            evidence: ["Source field: \(observation.recordID ?? "file content")", "Indicator provenance SHA-256: \(indicator.provenance.sha256)"],
            sourceFile: observation.sourceFile,
            acquisitionMethod: observation.acquisitionMethod,
            falsePositiveNotes: "Legitimate software, messages, browsing, testing, shared infrastructure, or stale intelligence can produce the same observable. Validate surrounding timestamps and independent artifacts.",
            detectionBasis: "Exact native comparison against an explicitly imported or updated indicator.",
            correlationKey: "\(indicator.type.rawValue):\(normalized)"
        )
    }

    private static func mvtFinding(_ resultFile: URL, record: JSONValue, index: Int) -> SecurityFinding {
        let fields = flattenJSON(record, prefix: "")
        let indicator = firstField(["matched_indicator", "indicator", "ioc", "matched_ioc", "detected_by"], fields: fields)
        let time = firstField(["timestamp", "time", "date"], fields: fields)
        let serialized = record.prettyString()
        let identity = "\(resultFile.lastPathComponent)\u{0}\(index)\u{0}\(serialized)"
        let findingID = String(SecureFileIO.sha256(of: Data(identity.utf8)).prefix(20))
        let module = resultFile.lastPathComponent.replacingOccurrences(of: "_detected.json", with: "")
        return SecurityFinding(
            id: findingID,
            scanner: mvtMetadata.name,
            scannerVersion: mvtMetadata.version,
            category: "mvt-detection",
            severity: indicator == nil ? .low : .medium,
            classification: indicator == nil ? .requiresManualReview : .iocMatch,
            artifactType: "mvt-json-result",
            artifactPath: resultFile.lastPathComponent,
            database: nil,
            table: module,
            recordID: String(index),
            timestamp: time,
            observedValue: String(serialized.prefix(1_000)),
            matchedIndicator: indicator,
            indicatorType: nil,
            iocSource: "MVT-provided IOC source",
            iocID: nil,
            iocVersion: nil,
            explanation: "MVT emitted a detection record from module \(module). Review the original MVT JSON, scanner version, and IOC files used for the external run before drawing a conclusion.",
            evidence: fields.prefix(20).map { "\($0.0): \(String($0.1.prefix(240)))" },
            sourceFile: resultFile.path,
            acquisitionMethod: .mvtResults,
            falsePositiveNotes: "MVT detections and heuristics can have legitimate explanations and require artifact-level validation.",
            detectionBasis: "Normalized from an external MVT *_detected.json result; the toolkit did not rerun MVT.",
            correlationKey: "mvt:\((indicator ?? "\(module):\(findingID)").lowercased())"
        )
    }

    private static var nativeMetadata: SecurityScannerMetadata {
        SecurityScannerMetadata(id: "native-ioc", name: "Native IOC Scanner", version: "1", capabilities: ["IOC matching", "STIX equality indicators", "backup/sysdiagnose/imported evidence"], supportedArtifacts: ["decrypted iOS backup", "unpacked sysdiagnose", "local files and folders"], licenseName: "MIT (this repository)", bundled: true)
    }

    private static var mvtMetadata: SecurityScannerMetadata {
        SecurityScannerMetadata(id: "mvt-output", name: "MVT Output Adapter", version: "1", capabilities: ["MVT JSON normalization", "external scanner provenance"], supportedArtifacts: ["MVT output folder"], licenseName: "Adapter: MIT; MVT: MVT License 1.1, independently installed", bundled: false)
    }

    private static func normalize(_ type: SecurityIndicatorType, _ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .domain, .url, .email, .process, .bundleID, .filename, .path: return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        case .phone:
            let prefix = trimmed.hasPrefix("+") ? "+" : ""
            return prefix + trimmed.filter(\.isNumber)
        case .md5, .sha1, .sha256, .certificateSHA256: return trimmed.lowercased().replacingOccurrences(of: ":", with: "")
        case .ipv4, .ipv6, .configurationProfileID: return trimmed.lowercased()
        }
    }

    private static func boundedMatch(_ value: String, characterClass: String, text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "(?<![\(characterClass)])\(NSRegularExpression.escapedPattern(for: value))(?![\(characterClass)])", options: [.caseInsensitive]) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func excerpt(_ value: String, needle: String) -> String {
        guard let range = value.range(of: needle, options: [.caseInsensitive]) else { return String(needle.prefix(240)) }
        let start = value.index(range.lowerBound, offsetBy: -min(80, value.distance(from: value.startIndex, to: range.lowerBound)))
        let remaining = value.distance(from: range.upperBound, to: value.endIndex)
        let end = value.index(range.upperBound, offsetBy: min(80, remaining))
        return String(value[start..<end].replacingOccurrences(of: "\n", with: " ").prefix(320))
    }

    private static func flattenJSON(_ value: JSONValue, prefix: String) -> [(String, String)] {
        switch value {
        case .object(let object): return object.keys.sorted().flatMap { key in flattenJSON(object[key]!, prefix: prefix.isEmpty ? key : "\(prefix).\(key)") }
        case .array(let array): return array.enumerated().flatMap { flattenJSON($0.element, prefix: "\(prefix)[\($0.offset)]") }
        case .null: return []
        default: return [(prefix, String((value.string ?? value.prettyString()).prefix(32_768)))]
        }
    }

    private static func firstField(_ names: [String], fields: [(String, String)]) -> String? {
        for name in names {
            if let value = fields.first(where: { $0.0.split(separator: ".").last?.lowercased() == name && !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.1 { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func validate(_ request: SecurityScanRequest) throws {
        guard request.maximumFiles > 0, request.maximumFileBytes > 0, request.maximumTotalBytes > 0, request.maximumSQLiteRows > 0 else {
            throw ToolkitError.invalidInput("Security-analysis limits must all be positive.")
        }
    }
}
