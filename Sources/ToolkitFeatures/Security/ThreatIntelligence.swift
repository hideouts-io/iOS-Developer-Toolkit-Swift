import Foundation
import ToolkitCore

public enum ThreatIntelligence {
    public static let maximumImportBytes = 50 * 1024 * 1024

    private static let fieldTypes: [String: SecurityIndicatorType] = [
        "domain-name:value": .domain,
        "url:value": .url,
        "ipv4-addr:value": .ipv4,
        "ipv6-addr:value": .ipv6,
        "file:name": .filename,
        "file:path": .path,
        "process:name": .process,
        "app:id": .bundleID,
        "email-addr:value": .email,
        "phone-number:value": .phone,
        "configuration-profile:id": .configurationProfileID,
        "file:hashes.md5": .md5,
        "file:hashes.sha1": .sha1,
        "file:hashes.sha256": .sha256,
        "x509-certificate:hashes.sha256": .certificateSHA256,
    ]

    public static func loadLocalFile(_ url: URL, sourceName: String, organization: String, sourceURL: String?, version: String?, commit: String?, publishedAt: String?, signatureStatus: String, importedAt: String, maximumBytes: Int) throws -> IntelligenceBundle {
        guard maximumBytes > 0 else { throw ToolkitError.invalidInput("The threat-intelligence byte limit must be positive.") }
        guard url.path.hasPrefix("/") else { throw ToolkitError.invalidInput("Choose an absolute threat-intelligence file path.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ToolkitError.invalidInput("Threat intelligence must be a regular local file, not a symbolic link.")
        }
        guard ["json", "stix", "stix2"].contains(url.pathExtension.lowercased()) else {
            throw ToolkitError.invalidInput("Threat intelligence must use .json, .stix, or .stix2.")
        }
        let fileSize = values.fileSize ?? 0
        guard fileSize <= maximumBytes else {
            throw ToolkitError.invalidInput("The threat-intelligence file is \(fileSize) bytes, over the \(maximumBytes)-byte safety limit.")
        }
        let content: Data
        do { content = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { throw ToolkitError.fileSystem("Could not read the threat-intelligence file.", path: url.path, underlying: error) }
        let payload: JSONValue
        do { payload = try JSONValue.parse(content) }
        catch { throw ToolkitError(.invalidInput, message: "The threat-intelligence file is not valid JSON.", technicalDetail: String(describing: error)) }
        guard let object = payload.object else { throw ToolkitError.invalidInput("The threat-intelligence root must be a JSON object.") }
        let provenance = IntelligenceProvenance(
            sourceName: sourceName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? url.lastPathComponent,
            organization: organization.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Local import",
            sourceURL: sourceURL,
            version: version,
            commit: commit,
            publishedAt: publishedAt,
            importedAt: importedAt,
            sha256: SecureFileIO.sha256(of: content),
            signatureStatus: signatureStatus.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "not-provided",
            localPath: url.path
        )
        let parsed = object["type"]?.string == "bundle"
            ? try parseSTIX(object, provenance: provenance)
            : try parseGeneric(object, provenance: provenance)
        var seen = Set<String>()
        let indicators = parsed.indicators.filter { seen.insert("\($0.type.rawValue)\u{0}\($0.value.lowercased())\u{0}\($0.id)").inserted }
        return IntelligenceBundle(provenance: provenance, indicators: indicators, warnings: parsed.warnings)
    }

    public static func isStale(_ bundle: IntelligenceBundle, referenceDate: Date, maximumAgeDays: Int) throws -> Bool {
        guard maximumAgeDays > 0 else { throw ToolkitError.invalidInput("The intelligence age limit must be positive.") }
        let timestamp = bundle.provenance.publishedAt ?? bundle.provenance.importedAt
        guard let date = parseISO8601(timestamp) else {
            throw ToolkitError.invalidInput("Threat-intelligence timestamp is invalid: \(timestamp)")
        }
        return referenceDate.timeIntervalSince(date) > Double(maximumAgeDays) * 86_400
    }

    private static func parseSTIX(_ payload: [String: JSONValue], provenance: IntelligenceProvenance) throws -> (indicators: [SecurityIndicator], warnings: [String]) {
        guard payload["type"]?.string == "bundle", let objects = payload["objects"]?.array else {
            throw ToolkitError.invalidInput("STIX input must be a bundle containing an objects array.")
        }
        var indicators: [SecurityIndicator] = []
        var warnings: [String] = []
        for (position, value) in objects.enumerated() {
            guard let object = value.object else { throw ToolkitError.invalidInput("STIX object \(position) must be a JSON object.") }
            guard object["type"]?.string == "indicator" else { continue }
            let identifier = try requiredString(object, key: "id", context: "STIX indicator \(position)")
            if let patternType = object["pattern_type"]?.nonEmptyString, patternType.lowercased() != "stix" {
                warnings.append("Skipped \(identifier): unsupported pattern_type \(patternType).")
                continue
            }
            let pattern = try requiredString(object, key: "pattern", context: identifier)
            let comparisons: [(SecurityIndicatorType, String)]
            do { comparisons = try parsePattern(pattern, identifier: identifier) }
            catch { warnings.append((error as? ToolkitError)?.message ?? error.localizedDescription); continue }
            let name = object["name"]?.nonEmptyString ?? identifier
            let description = object["description"]?.nonEmptyString ?? "Published threat-intelligence indicator."
            let confidence = try optionalConfidence(object)
            for (index, comparison) in comparisons.enumerated() {
                indicators.append(SecurityIndicator(
                    id: comparisons.count == 1 ? identifier : "\(identifier)#\(index + 1)",
                    type: comparison.0,
                    value: comparison.1,
                    name: name,
                    description: description,
                    confidence: confidence,
                    validFrom: object["valid_from"]?.nonEmptyString,
                    validUntil: object["valid_until"]?.nonEmptyString,
                    provenance: provenance
                ))
            }
        }
        guard !indicators.isEmpty else {
            let suffix = warnings.isEmpty ? "" : " \(warnings.count) unsupported patterns were skipped."
            throw ToolkitError.invalidInput("The STIX bundle contained no supported indicators.\(suffix)")
        }
        return (indicators, warnings)
    }

    private static func parseGeneric(_ payload: [String: JSONValue], provenance: IntelligenceProvenance) throws -> (indicators: [SecurityIndicator], warnings: [String]) {
        guard let values = payload["indicators"]?.array else { throw ToolkitError.invalidInput("JSON IOC input must contain an indicators array.") }
        let indicators = try values.enumerated().map { position, value -> SecurityIndicator in
            guard let entry = value.object else { throw ToolkitError.invalidInput("JSON IOC entry \(position) must be an object.") }
            let identifier = try requiredString(entry, key: "id", context: "JSON IOC entry \(position)")
            let typeText = try requiredString(entry, key: "type", context: identifier)
            guard let type = SecurityIndicatorType(rawValue: typeText) else { throw ToolkitError.invalidInput("JSON IOC \(identifier) uses unsupported type \(typeText).") }
            return SecurityIndicator(
                id: identifier,
                type: type,
                value: try requiredString(entry, key: "value", context: identifier),
                name: entry["name"]?.nonEmptyString ?? identifier,
                description: entry["description"]?.nonEmptyString ?? "Imported threat-intelligence indicator.",
                confidence: try optionalConfidence(entry),
                validFrom: entry["valid_from"]?.nonEmptyString,
                validUntil: entry["valid_until"]?.nonEmptyString,
                provenance: provenance
            )
        }
        guard !indicators.isEmpty else { throw ToolkitError.invalidInput("JSON IOC input contains no indicators.") }
        return (indicators, [])
    }

    private static func parsePattern(_ pattern: String, identifier: String) throws -> [(SecurityIndicatorType, String)] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { throw ToolkitError.invalidInput("STIX indicator \(identifier) has an unsupported pattern envelope.") }
        let body = String(trimmed.dropFirst().dropLast())
        let banned = try NSRegularExpression(pattern: #"\b(?:AND|FOLLOWEDBY|LIKE|MATCHES|IN|NOT)\b"#, options: [.caseInsensitive])
        guard banned.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) == nil else {
            throw ToolkitError.invalidInput("STIX indicator \(identifier) uses semantics outside the safe equality/OR subset.")
        }
        let splitter = try NSRegularExpression(pattern: #"\s+OR\s+"#, options: [.caseInsensitive])
        let marked = splitter.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "\u{0}")
        return try marked.split(separator: "\u{0}").map { rawComparison in
            let comparison = String(rawComparison)
            let expression = try NSRegularExpression(pattern: #"^\s*([A-Za-z0-9_-]+:[A-Za-z0-9_.\-'\[\]]+)\s*=\s*'((?:\\.|[^'])*)'\s*$"#)
            let range = NSRange(comparison.startIndex..., in: comparison)
            guard let match = expression.firstMatch(in: comparison, range: range), match.range == range,
                  let fieldRange = Range(match.range(at: 1), in: comparison),
                  let valueRange = Range(match.range(at: 2), in: comparison) else {
                throw ToolkitError.invalidInput("STIX indicator \(identifier) contains an unsupported comparison: \(comparison)")
            }
            let field = canonicalField(String(comparison[fieldRange]))
            guard let type = fieldTypes[field] else { throw ToolkitError.invalidInput("STIX indicator \(identifier) uses unsupported field \(field).") }
            let value = String(comparison[valueRange]).replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: "\\\\", with: "\\").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw ToolkitError.invalidInput("STIX indicator \(identifier) contains an empty value.") }
            return (type, value)
        }
    }

    private static func canonicalField(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "['", with: ".")
            .replacingOccurrences(of: "']", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "sha-256", with: "sha256")
            .replacingOccurrences(of: "sha-1", with: "sha1")
    }

    private static func requiredString(_ object: [String: JSONValue], key: String, context: String) throws -> String {
        guard let value = object[key]?.nonEmptyString else { throw ToolkitError.invalidInput("\(context) requires a non-empty string field \(key).") }
        return value
    }

    private static func optionalConfidence(_ object: [String: JSONValue]) throws -> Int? {
        guard let value = object["confidence"] else { return nil }
        guard let confidence = value.int, (0...100).contains(confidence) else { throw ToolkitError.invalidInput("Indicator confidence must be an integer from 0 through 100.") }
        return confidence
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
