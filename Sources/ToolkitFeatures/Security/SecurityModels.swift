import Foundation

public enum SecurityIndicatorType: String, Codable, CaseIterable, Sendable {
    case domain
    case url
    case ipv4
    case ipv6
    case filename
    case path
    case process
    case bundleID = "bundle-id"
    case md5
    case sha1
    case sha256
    case certificateSHA256 = "certificate-sha256"
    case email
    case phone
    case configurationProfileID = "configuration-profile-id"
}

public enum SecurityFindingClassification: String, Codable, CaseIterable, Sendable {
    case informational
    case suspicious
    case iocMatch = "ioc-match"
    case highConfidenceIOCMatch = "high-confidence-ioc-match"
    case configurationConcern = "configuration-concern"
    case requiresManualReview = "requires-manual-review"

    public var label: String {
        rawValue.replacingOccurrences(of: "-", with: " ").capitalized
    }

    public var rank: Int {
        switch self {
        case .informational: return 0
        case .configurationConcern: return 1
        case .requiresManualReview: return 2
        case .suspicious: return 3
        case .iocMatch: return 4
        case .highConfidenceIOCMatch: return 5
        }
    }
}

public enum SecurityFindingSeverity: String, Codable, CaseIterable, Sendable {
    case informational
    case low
    case medium
    case high
    case critical

    public var rank: Int {
        switch self {
        case .informational: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }
}

public enum SecurityAcquisitionMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case backup
    case sysdiagnose
    case importedEvidence = "imported-evidence"
    case mvtResults = "mvt-results"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .backup: return "Decrypted iOS backup"
        case .sysdiagnose: return "Unpacked sysdiagnose"
        case .importedEvidence: return "Imported evidence file or folder"
        case .mvtResults: return "Existing MVT results"
        }
    }
}

public enum SecurityScannerStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

public struct IntelligenceProvenance: Codable, Hashable, Sendable {
    public let sourceName: String
    public let organization: String
    public let sourceURL: String?
    public let version: String?
    public let commit: String?
    public let publishedAt: String?
    public let importedAt: String
    public let sha256: String
    public let signatureStatus: String
    public let localPath: String

    public init(sourceName: String, organization: String, sourceURL: String?, version: String?, commit: String?, publishedAt: String?, importedAt: String, sha256: String, signatureStatus: String, localPath: String) {
        self.sourceName = sourceName
        self.organization = organization
        self.sourceURL = sourceURL
        self.version = version
        self.commit = commit
        self.publishedAt = publishedAt
        self.importedAt = importedAt
        self.sha256 = sha256
        self.signatureStatus = signatureStatus
        self.localPath = localPath
    }
}

public struct SecurityIndicator: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let type: SecurityIndicatorType
    public let value: String
    public let name: String
    public let description: String
    public let confidence: Int?
    public let validFrom: String?
    public let validUntil: String?
    public let provenance: IntelligenceProvenance

    public init(id: String, type: SecurityIndicatorType, value: String, name: String, description: String, confidence: Int?, validFrom: String?, validUntil: String?, provenance: IntelligenceProvenance) {
        self.id = id
        self.type = type
        self.value = value
        self.name = name
        self.description = description
        self.confidence = confidence
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.provenance = provenance
    }
}

public struct IntelligenceBundle: Codable, Hashable, Sendable, Identifiable {
    public var id: String { provenance.sha256 + provenance.sourceName }
    public let provenance: IntelligenceProvenance
    public let indicators: [SecurityIndicator]
    public let warnings: [String]

    public init(provenance: IntelligenceProvenance, indicators: [SecurityIndicator], warnings: [String]) {
        self.provenance = provenance
        self.indicators = indicators
        self.warnings = warnings
    }
}

public struct EvidenceObservation: Hashable, Sendable {
    public let artifactType: String
    public let artifactPath: String
    public let sourceFile: String
    public let observedType: String
    public let observedValue: String
    public let database: String?
    public let table: String?
    public let recordID: String?
    public let timestamp: String?
    public let acquisitionMethod: SecurityAcquisitionMethod

    public init(artifactType: String, artifactPath: String, sourceFile: String, observedType: String, observedValue: String, database: String?, table: String?, recordID: String?, timestamp: String?, acquisitionMethod: SecurityAcquisitionMethod) {
        self.artifactType = artifactType
        self.artifactPath = artifactPath
        self.sourceFile = sourceFile
        self.observedType = observedType
        self.observedValue = observedValue
        self.database = database
        self.table = table
        self.recordID = recordID
        self.timestamp = timestamp
        self.acquisitionMethod = acquisitionMethod
    }
}

public struct SecurityFinding: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let scanner: String
    public let scannerVersion: String
    public let category: String
    public let severity: SecurityFindingSeverity
    public let classification: SecurityFindingClassification
    public let artifactType: String
    public let artifactPath: String
    public let database: String?
    public let table: String?
    public let recordID: String?
    public let timestamp: String?
    public let observedValue: String
    public let matchedIndicator: String?
    public let indicatorType: SecurityIndicatorType?
    public let iocSource: String?
    public let iocID: String?
    public let iocVersion: String?
    public let explanation: String
    public let evidence: [String]
    public let sourceFile: String
    public let acquisitionMethod: SecurityAcquisitionMethod
    public let falsePositiveNotes: String
    public let detectionBasis: String
    public let correlationKey: String

    public init(id: String, scanner: String, scannerVersion: String, category: String, severity: SecurityFindingSeverity, classification: SecurityFindingClassification, artifactType: String, artifactPath: String, database: String?, table: String?, recordID: String?, timestamp: String?, observedValue: String, matchedIndicator: String?, indicatorType: SecurityIndicatorType?, iocSource: String?, iocID: String?, iocVersion: String?, explanation: String, evidence: [String], sourceFile: String, acquisitionMethod: SecurityAcquisitionMethod, falsePositiveNotes: String, detectionBasis: String, correlationKey: String) {
        self.id = id
        self.scanner = scanner
        self.scannerVersion = scannerVersion
        self.category = category
        self.severity = severity
        self.classification = classification
        self.artifactType = artifactType
        self.artifactPath = artifactPath
        self.database = database
        self.table = table
        self.recordID = recordID
        self.timestamp = timestamp
        self.observedValue = observedValue
        self.matchedIndicator = matchedIndicator
        self.indicatorType = indicatorType
        self.iocSource = iocSource
        self.iocID = iocID
        self.iocVersion = iocVersion
        self.explanation = explanation
        self.evidence = evidence
        self.sourceFile = sourceFile
        self.acquisitionMethod = acquisitionMethod
        self.falsePositiveNotes = falsePositiveNotes
        self.detectionBasis = detectionBasis
        self.correlationKey = correlationKey
    }
}

public struct SecurityScannerMetadata: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let capabilities: [String]
    public let supportedArtifacts: [String]
    public let licenseName: String
    public let bundled: Bool

    public init(id: String, name: String, version: String, capabilities: [String], supportedArtifacts: [String], licenseName: String, bundled: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.capabilities = capabilities
        self.supportedArtifacts = supportedArtifacts
        self.licenseName = licenseName
        self.bundled = bundled
    }
}

public struct SecurityScanRequest: Sendable {
    public let evidenceRoot: URL
    public let acquisitionMethod: SecurityAcquisitionMethod
    public let intelligence: [IntelligenceBundle]
    public let maximumFiles: Int
    public let maximumFileBytes: Int64
    public let maximumTotalBytes: Int64
    public let maximumSQLiteRows: Int

    public init(evidenceRoot: URL, acquisitionMethod: SecurityAcquisitionMethod, intelligence: [IntelligenceBundle], maximumFiles: Int, maximumFileBytes: Int64, maximumTotalBytes: Int64, maximumSQLiteRows: Int) {
        self.evidenceRoot = evidenceRoot
        self.acquisitionMethod = acquisitionMethod
        self.intelligence = intelligence
        self.maximumFiles = maximumFiles
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumSQLiteRows = maximumSQLiteRows
    }
}

public struct SecurityScannerExecution: Codable, Hashable, Sendable {
    public let metadata: SecurityScannerMetadata
    public let status: SecurityScannerStatus
    public let findings: [SecurityFinding]
    public let warnings: [String]
    public let errorMessage: String?
    public let startedAt: String
    public let finishedAt: String
    public let filesExamined: Int
    public let bytesExamined: Int64

    public init(metadata: SecurityScannerMetadata, status: SecurityScannerStatus, findings: [SecurityFinding], warnings: [String], errorMessage: String?, startedAt: String, finishedAt: String, filesExamined: Int, bytesExamined: Int64) {
        self.metadata = metadata
        self.status = status
        self.findings = findings
        self.warnings = warnings
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.filesExamined = filesExamined
        self.bytesExamined = bytesExamined
    }
}

public struct CorrelatedSecurityFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: String { correlationID }
    public let correlationID: String
    public let title: String
    public let severity: SecurityFindingSeverity
    public let classification: SecurityFindingClassification
    public let matchedIndicator: String?
    public let indicatorType: SecurityIndicatorType?
    public let scannerNames: [String]
    public let artifactPaths: [String]
    public let timestamps: [String]
    public let findingIDs: [String]
    public let explanation: String
    public let falsePositiveNotes: [String]

    public init(correlationID: String, title: String, severity: SecurityFindingSeverity, classification: SecurityFindingClassification, matchedIndicator: String?, indicatorType: SecurityIndicatorType?, scannerNames: [String], artifactPaths: [String], timestamps: [String], findingIDs: [String], explanation: String, falsePositiveNotes: [String]) {
        self.correlationID = correlationID
        self.title = title
        self.severity = severity
        self.classification = classification
        self.matchedIndicator = matchedIndicator
        self.indicatorType = indicatorType
        self.scannerNames = scannerNames
        self.artifactPaths = artifactPaths
        self.timestamps = timestamps
        self.findingIDs = findingIDs
        self.explanation = explanation
        self.falsePositiveNotes = falsePositiveNotes
    }
}

public struct SecurityAnalysisReport: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let analysisID: String
    public let startedAt: String
    public let finishedAt: String
    public let evidenceRoot: String
    public let acquisitionMethod: SecurityAcquisitionMethod
    public let intelligence: [IntelligenceBundle]
    public let scannerExecutions: [SecurityScannerExecution]
    public let findings: [SecurityFinding]
    public let correlatedFindings: [CorrelatedSecurityFinding]
    public let filesExamined: Int
    public let bytesExamined: Int64
    public let acquisitionWarnings: [String]
    public let limitations: [String]

    public init(schemaVersion: Int, analysisID: String, startedAt: String, finishedAt: String, evidenceRoot: String, acquisitionMethod: SecurityAcquisitionMethod, intelligence: [IntelligenceBundle], scannerExecutions: [SecurityScannerExecution], findings: [SecurityFinding], correlatedFindings: [CorrelatedSecurityFinding], filesExamined: Int, bytesExamined: Int64, acquisitionWarnings: [String], limitations: [String]) {
        self.schemaVersion = schemaVersion
        self.analysisID = analysisID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.evidenceRoot = evidenceRoot
        self.acquisitionMethod = acquisitionMethod
        self.intelligence = intelligence
        self.scannerExecutions = scannerExecutions
        self.findings = findings
        self.correlatedFindings = correlatedFindings
        self.filesExamined = filesExamined
        self.bytesExamined = bytesExamined
        self.acquisitionWarnings = acquisitionWarnings
        self.limitations = limitations
    }

    public var statusSummary: String {
        if correlatedFindings.contains(where: { $0.classification == .highConfidenceIOCMatch }) {
            return "High-confidence IOC match detected — manual forensic review is recommended."
        }
        if correlatedFindings.contains(where: { $0.classification == .iocMatch }) {
            return "Known IOC match detected — validate the evidence and surrounding context."
        }
        if !correlatedFindings.isEmpty { return "Suspicious or reviewable artifacts were detected." }
        if scannerExecutions.contains(where: { $0.status == .cancelled }) {
            return "Analysis was cancelled; coverage is incomplete and no clean-device conclusion can be drawn."
        }
        if scannerExecutions.contains(where: { $0.status == .failed }) {
            return "One or more scanners failed; coverage is incomplete and no clean-device conclusion can be drawn."
        }
        return "No known indicators were detected in the analyzed coverage; this is not proof that the device is clean."
    }
}
