import DeviceKit
import Foundation
import ToolkitCore

/// Log sources that are gathered over a time window instead of streamed, both through Apple's own
/// tools:
/// - **OSLog archive:** macOS's `log collect` copies the device's saved Unified Log history into a
///   `.logarchive` (Console.app opens it); `log show` reads it back for the viewer.
/// - **DVT logging:** Instruments' Logging template (`xctrace record`) records os_log through the
///   device's developer services (DVT); `xctrace export` reads the recording's os-log table. This
///   is Apple's supported route to DVT logging; a direct DVT connection would need Xcode's private
///   tunnel.
public enum CollectedLogs {
    /// Time windows offered in the app, in seconds.
    public static let windows = [30, 60, 300, 900]
    /// DVT recordings keep every event in memory while exporting, so they are kept short.
    public static let maximumDVTSeconds = 900
    /// How much saved history Evidence Capture's OSLog archive covers.
    public static let evidenceArchiveSeconds = 3600

    public static func osLogArchiveRequest(udid: String, windowSeconds: Int, output: URL) throws -> CommandRequest {
        guard (1...86_400).contains(windowSeconds) else { throw ToolkitError.invalidInput("Choose a window between 1 second and 24 hours.") }
        guard output.pathExtension == "logarchive" else { throw ToolkitError.invalidInput("Log archives are saved as .logarchive.") }
        return CommandRequest(
            executable: try AppleTool.log.locate(),
            arguments: ["collect", "--device-udid", udid, "--last", "\(windowSeconds)s", "--output", output.path],
            timeout: 900,
            displayName: "log collect (device)"
        )
    }

    public static func logShowRequest(archive: URL) throws -> CommandRequest {
        CommandRequest(
            executable: try AppleTool.log.locate(),
            arguments: ["show", "--archive", archive.path, "--style", "ndjson", "--info", "--debug"],
            timeout: 1800,
            displayName: "log show (archive)"
        )
    }

    public static func dvtRecordRequest(target: DeviceTarget, seconds: Int, output: URL) throws -> CommandRequest {
        guard (1...maximumDVTSeconds).contains(seconds) else {
            throw ToolkitError.invalidInput("DVT recordings can be up to \(maximumDVTSeconds / 60) minutes long.")
        }
        return try InstrumentsRecorder.request(template: "Logging", target: target, durationSeconds: seconds, output: output)
    }

    public static func dvtTableOfContentsRequest(trace: URL, output: URL) throws -> CommandRequest {
        try XcodeTool.xctrace.request(["export", "--input", trace.path, "--toc", "--output", output.path], timeout: 300, displayName: "xctrace export (contents)")
    }

    public static func dvtExportRequest(trace: URL, output: URL) throws -> CommandRequest {
        try XcodeTool.xctrace.request(
            ["export", "--input", trace.path, "--xpath", #"/trace-toc/run[@number="1"]/data/table[@schema="os-log"]"#, "--output", output.path],
            timeout: 1800,
            displayName: "xctrace export (os-log)"
        )
    }

    /// The recording's start time from `xctrace export --toc` (`<start-date>`).
    public static func startDate(tableOfContents: Data) -> Date? {
        let text = String(decoding: tableOfContents, as: UTF8.self)
        guard let open = text.range(of: "<start-date>"), let close = text.range(of: "</start-date>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = String(text[open.upperBound..<close.lowerBound])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// One line of newline-delimited JSON in the shape `log show --style ndjson` uses, so every
    /// structured spool reads the same way.
    public static func ndjson(_ line: LogLine) -> Data {
        var object: [String: Any] = ["eventMessage": line.message]
        if let timestamp = line.timestamp { object["timestamp"] = logShowTimestamp.string(from: timestamp) }
        if let process = line.process { object["processImagePath"] = process }
        if let pid = line.pid { object["processID"] = pid }
        if let level = line.level { object["messageType"] = level }
        if let subsystem = line.subsystem { object["subsystem"] = subsystem }
        if let category = line.category { object["category"] = category }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(line.message.utf8)
        data.append(0x0A)
        return data
    }

    /// The timestamp format `log show --style ndjson` uses (and `SimulatorLogParser` reads).
    static var logShowTimestamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }

    /// Gathers `kind` over `seconds` and yields its lines. The archive or recording is kept at
    /// `artifact`.
    public static func stream(_ kind: LogStreamKind, target: DeviceTarget, seconds: Int, artifact: URL, runner: CommandRunning) -> AsyncThrowingStream<LogChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch kind {
                    case .osLogArchive:
                        try await collectArchive(target: target, seconds: seconds, artifact: artifact, runner: runner, continuation: continuation)
                    case .dvt:
                        try await recordDVT(target: target, seconds: seconds, artifact: artifact, runner: runner, continuation: continuation)
                    default:
                        throw ToolkitError(.unsupported, message: "\(kind.title) is streamed, not collected.")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func note(_ message: String) -> LogChunk { LogChunk(spoolBytes: Data(), lines: [LogLine(level: "note", message: message)]) }

    private static func collectArchive(target: DeviceTarget, seconds: Int, artifact: URL, runner: CommandRunning, continuation: AsyncThrowingStream<LogChunk, Error>.Continuation) async throws {
        guard target.kind == .physical else { throw ToolkitError(.unsupported, message: "Log archives are collected from iPhones and iPads.") }
        continuation.yield(note("Collecting the device's saved logs from the last \(Self.describe(seconds)). This can take a few minutes."))
        let collected = try await runner.run(try osLogArchiveRequest(udid: target.udid, windowSeconds: seconds, output: artifact))
        guard collected.succeeded, FileManager.default.fileExists(atPath: artifact.path) else { throw archiveError(collected) }
        continuation.yield(note("Saved the log archive to \(artifact.path). Console.app can open it."))
        var splitter = LineSplitter()
        for try await event in runner.stream(try logShowRequest(archive: artifact)) {
            switch event {
            case .standardOutput(let data):
                let lines = splitter.consume(data).compactMap(SimulatorLogParser.parse(line:))
                continuation.yield(LogChunk(spoolBytes: data, lines: lines))
            case .standardError:
                break
            case .finished(let result):
                if !result.succeeded, !Task.isCancelled {
                    throw ToolkitError(.commandFailed, message: "The log archive was collected but could not be read.", recovery: "Open it in Console.app instead.", technicalDetail: result.technicalSummary)
                }
            }
        }
        let remainder = splitter.flush().compactMap(SimulatorLogParser.parse(line:))
        if !remainder.isEmpty { continuation.yield(LogChunk(spoolBytes: Data(), lines: remainder)) }
    }

    static func archiveError(_ result: CommandResult) -> ToolkitError {
        let text = (result.standardErrorText + result.standardOutputText).lowercased()
        if text.contains("root") || text.contains("permission") || text.contains("not permitted") {
            return ToolkitError(.permissionDenied, message: "macOS did not allow collecting the device's log archive.", recovery: "The toolkit never uses administrator rights. Use Unified Logs (live) instead, or run `log collect --device-udid` yourself.", technicalDetail: result.technicalSummary)
        }
        return ToolkitError(.commandFailed, message: "The device's log archive could not be collected.", recovery: "Unlock the device, keep it connected by USB, tap Trust if asked, and try again.", technicalDetail: result.technicalSummary)
    }

    private static func recordDVT(target: DeviceTarget, seconds: Int, artifact: URL, runner: CommandRunning, continuation: AsyncThrowingStream<LogChunk, Error>.Continuation) async throws {
        let seconds = min(seconds, maximumDVTSeconds)
        continuation.yield(note("Recording os_log through Instruments (DVT) for \(Self.describe(seconds)). The lines appear when the recording ends."))
        let recorded = try await runner.run(try dvtRecordRequest(target: target, seconds: seconds, output: artifact))
        guard recorded.succeeded, FileManager.default.fileExists(atPath: artifact.path) else {
            throw ToolkitError(.commandFailed, message: "Instruments could not record from \(target.name).", recovery: target.kind == .simulator ? "Make sure the simulator is running, then try again." : "Turn on Developer Mode, mount the developer image (Developer Image page), keep the device unlocked, and try again.", technicalDetail: recorded.technicalSummary)
        }
        continuation.yield(note("Saved the recording to \(artifact.path). Instruments can open it."))
        let work = try SecureFileIO.makeTemporaryDirectory(prefix: "dvt-export")
        defer { try? FileManager.default.removeItem(at: work) }
        let toc = work.appendingPathComponent("toc.xml")
        var start: Date?
        if (try? await runner.run(try dvtTableOfContentsRequest(trace: artifact, output: toc)))?.succeeded == true {
            start = startDate(tableOfContents: (try? Data(contentsOf: toc)) ?? Data())
        }
        let xml = work.appendingPathComponent("os-log.xml")
        let exported = try await runner.run(try dvtExportRequest(trace: artifact, output: xml))
        guard exported.succeeded, FileManager.default.fileExists(atPath: xml.path) else {
            throw ToolkitError(.commandFailed, message: "The recording was saved but its log could not be read.", recovery: "Open the .trace in Instruments instead.", technicalDetail: exported.technicalSummary)
        }
        try Task.checkCancellation()
        try XctraceOSLogReader.read(xml, start: start, batchSize: 2_000) { lines in
            continuation.yield(LogChunk(spoolBytes: lines.reduce(into: Data()) { $0.append(ndjson($1)) }, lines: lines))
        }
    }

    static func describe(_ seconds: Int) -> String {
        seconds % 3600 == 0 ? "\(seconds / 3600) h" : seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}

/// Reads the os-log table that `xctrace export` writes, without loading it into memory.
///
/// Each `<row>` lists one value per schema column, in column order. A value either carries
/// `id`/`fmt` attributes (its display text) or a `ref` to an earlier `id`; `<sentinel/>` means no
/// value. Nested elements (a thread's process, for example) define ids too.
public final class XctraceOSLogReader: NSObject, XMLParserDelegate {
    private var columns: [String] = []
    private var inMnemonic = false
    private var mnemonic = ""
    private var texts: [String: String] = [:]
    private var rowDepth: Int?
    private var depth = 0
    private var row: [String?] = []
    private var batch: [LogLine] = []
    private let start: Date?
    private let batchSize: Int
    private let deliver: ([LogLine]) -> Void

    init(start: Date?, batchSize: Int, deliver: @escaping ([LogLine]) -> Void) {
        self.start = start
        self.batchSize = batchSize
        self.deliver = deliver
    }

    /// Parses `url` and delivers lines in batches of up to `batchSize`.
    public static func read(_ url: URL, start: Date?, batchSize: Int = 2_000, deliver: @escaping ([LogLine]) -> Void) throws {
        guard let parser = XMLParser(contentsOf: url) else { throw ToolkitError.fileSystem("The exported log could not be opened.", path: url.path) }
        let reader = XctraceOSLogReader(start: start, batchSize: batchSize, deliver: deliver)
        parser.delegate = reader
        guard parser.parse() else {
            throw ToolkitError(.commandFailed, message: "The exported log could not be read.", technicalDetail: parser.parserError.map { String(describing: $0) })
        }
        if !reader.batch.isEmpty { deliver(reader.batch) }
    }

    /// Parses exported XML held in memory (tests).
    public static func lines(from data: Data, start: Date? = nil) throws -> [LogLine] {
        let parser = XMLParser(data: data)
        var all: [LogLine] = []
        let reader = XctraceOSLogReader(start: start, batchSize: .max) { all.append(contentsOf: $0) }
        parser.delegate = reader
        guard parser.parse() else { throw ToolkitError(.commandFailed, message: "The exported log could not be read.") }
        all.append(contentsOf: reader.batch)
        return all
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        switch name {
        case "mnemonic":
            inMnemonic = true; mnemonic = ""
            return
        case "row":
            rowDepth = depth; row = []
            return
        default:
            break
        }
        guard let rowDepth else { return }
        var value: String?
        if let id = attributes["id"], let fmt = attributes["fmt"] {
            texts[id] = fmt
            value = fmt
        } else if let ref = attributes["ref"] {
            value = texts[ref]
        }
        if depth == rowDepth + 1 { row.append(name == "sentinel" ? nil : value) }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inMnemonic { mnemonic += string }
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if name == "mnemonic" {
            inMnemonic = false
            if rowDepth == nil { columns.append(mnemonic) }
        } else if name == "row" {
            rowDepth = nil
            if let line = makeLine() { batch.append(line) }
            if batch.count >= batchSize { deliver(batch); batch.removeAll(keepingCapacity: true) }
        }
    }

    private func value(_ column: String) -> String? {
        guard let index = columns.firstIndex(of: column), index < row.count else { return nil }
        return row[index].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func makeLine() -> LogLine? {
        guard let message = value("message") ?? value("format-string") else { return nil }
        var process: String?, pid: Int?
        if let text = value("process") {
            // "Name (1234)"
            if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
                process = String(text[..<open]).trimmingCharacters(in: .whitespaces)
                pid = Int(text[text.index(after: open)..<text.index(before: text.endIndex)])
            } else {
                process = text
            }
        }
        let offset = value("time").flatMap(Self.seconds(fromFormattedTime:))
        return LogLine(
            timestamp: offset.flatMap { offset in start.map { $0.addingTimeInterval(offset) } },
            process: process,
            pid: pid,
            level: value("message-type"),
            subsystem: value("subsystem"),
            category: value("category"),
            message: message
        )
    }

    /// Seconds from xctrace's formatted event time, such as "00:00.547.843" or "1:02:03.004.005".
    static func seconds(fromFormattedTime text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard let last = parts.last else { return nil }
        let fraction = last.split(separator: ".")
        guard let wholeSeconds = Double(fraction.first ?? "") else { return nil }
        var total = wholeSeconds
        if fraction.count > 1, let milliseconds = Double(fraction[1]) { total += milliseconds / 1_000 }
        if fraction.count > 2, let microseconds = Double(fraction[2]) { total += microseconds / 1_000_000 }
        for (index, part) in parts.dropLast().reversed().enumerated() {
            guard let number = Double(part) else { return nil }
            total += number * pow(60, Double(index + 1))
        }
        return total
    }
}
