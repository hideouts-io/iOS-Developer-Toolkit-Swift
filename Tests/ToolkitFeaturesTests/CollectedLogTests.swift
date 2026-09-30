import Foundation
import Testing
@testable import DeviceKit
@testable import ToolkitFeatures
import ToolkitCore

@Suite("Collected logs: OSLog archive and DVT")
struct CollectedLogTests {
    /// The structure `xctrace export` writes for the os-log table (abridged from a real recording):
    /// values carry id/fmt or ref an earlier id, nested elements define ids too, and <sentinel/>
    /// marks an empty column.
    static let exportedXML = #"""
    <?xml version="1.0"?>
    <trace-query-result>
    <node xpath='//trace-toc[1]/run[1]/data[1]/table[1]'><schema name="os-log"><col><mnemonic>time</mnemonic></col><col><mnemonic>thread</mnemonic></col><col><mnemonic>process</mnemonic></col><col><mnemonic>message-type</mnemonic></col><col><mnemonic>format-string</mnemonic></col><col><mnemonic>backtrace</mnemonic></col><col><mnemonic>subsystem</mnemonic></col><col><mnemonic>category</mnemonic></col><col><mnemonic>message</mnemonic></col><col><mnemonic>emit-location</mnemonic></col></schema>
    <row><event-time id="1" fmt="00:00.547.843">547843125</event-time><thread id="2" fmt="Main Thread"><tid id="3" fmt="0xc9c83">826499</tid><process id="4" fmt="SpringBoard (49207)"><pid id="5" fmt="49207">49207</pid></process></thread><process ref="4"/><event-type id="7" fmt="Default">Default</event-type><format-string id="8" fmt="Launched %{public}s">Launched %{public}s</format-string><sentinel/><subsystem id="9" fmt="com.apple.extensionkit">com.apple.extensionkit</subsystem><category id="10" fmt="default">default</category><os-log-metadata id="11" fmt="Launched Weather"><narrative-text id="12" fmt="Launched ">Launched </narrative-text></os-log-metadata><sentinel/></row>
    <row><event-time id="22" fmt="01:02.000.500">62000500000</event-time><thread id="23" fmt="0x0"><tid id="24" fmt="0x0">0</tid><process id="25" fmt="diagnosticd (48775)"><pid id="26" fmt="48775">48775</pid></process></thread><process ref="25"/><event-type id="27" fmt="Info">Info</event-type><sentinel/><sentinel/><subsystem id="28" fmt="com.apple.diagnosticd">com.apple.diagnosticd</subsystem><category id="29" fmt=""></category><sentinel/><sentinel/></row>
    <row><event-time id="30" fmt="01:02.100.000">62100000000</event-time><thread ref="2"/><process ref="4"/><event-type ref="27"/><format-string ref="8"/><sentinel/><subsystem ref="9"/><category ref="10"/><os-log-metadata id="31" fmt="Launched Maps"/><sentinel/></row>
    </node></trace-query-result>
    """#

    @Test func readsTheOSLogTableFromXctraceExport() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = try XctraceOSLogReader.lines(from: Data(Self.exportedXML.utf8), start: start)
        // The second row has neither a message nor a format string, so it is skipped.
        #expect(lines.count == 2)
        #expect(lines[0].message == "Launched Weather")
        #expect(lines[0].process == "SpringBoard" && lines[0].pid == 49207)
        #expect(lines[0].level == "Default")
        #expect(lines[0].subsystem == "com.apple.extensionkit" && lines[0].category == "default")
        #expect(lines[0].timestamp == start.addingTimeInterval(0.547843))
        // Values given by reference resolve to the earlier definitions, including nested ones.
        #expect(lines[1].message == "Launched Maps" && lines[1].process == "SpringBoard" && lines[1].level == "Info")
        #expect(lines[1].timestamp == start.addingTimeInterval(62.1))
        #expect(try XctraceOSLogReader.lines(from: Data(Self.exportedXML.utf8)).allSatisfy { $0.timestamp == nil })
    }

    @Test func parsesXctraceTimes() {
        func close(_ text: String, _ expected: Double) -> Bool { XctraceOSLogReader.seconds(fromFormattedTime: text).map { abs($0 - expected) < 0.000001 } ?? false }
        #expect(close("00:00.547.843", 0.547843))
        #expect(close("01:02.000.500", 62.0005))
        #expect(close("1:02:03.004.005", 3723.004005))
        #expect(XctraceOSLogReader.seconds(fromFormattedTime: "later") == nil)
    }

    @Test func spooledLinesReadBackLikeLogShowOutput() {
        let line = LogLine(timestamp: Date(timeIntervalSince1970: 1_800_000_000.25), process: "SpringBoard", pid: 42, level: "Error", subsystem: "com.example", category: "net", message: "boom \"quoted\"")
        let back = SimulatorLogParser.parse(line: Substring(String(decoding: CollectedLogs.ndjson(line).dropLast(), as: UTF8.self)))
        #expect(back?.message == line.message && back?.process == "SpringBoard" && back?.pid == 42)
        #expect(back?.level == "Error" && back?.subsystem == "com.example" && back?.category == "net")
        #expect(back?.timestamp.map { abs($0.timeIntervalSince(line.timestamp!)) < 0.001 } == true)
    }

    @Test func buildsAppleToolCommands() throws {
        let archive = URL(fileURLWithPath: "/tmp/x/device.logarchive")
        let collect = try CollectedLogs.osLogArchiveRequest(udid: "00008150-000B33334444002E", windowSeconds: 300, output: archive)
        #expect(collect.executable.path == "/usr/bin/log")
        #expect(collect.arguments == ["collect", "--device-udid", "00008150-000B33334444002E", "--last", "300s", "--output", archive.path])
        #expect(try CollectedLogs.logShowRequest(archive: archive).arguments == ["show", "--archive", archive.path, "--style", "ndjson", "--info", "--debug"])
        #expect(throws: ToolkitError.self) { try CollectedLogs.osLogArchiveRequest(udid: "u", windowSeconds: 300, output: URL(fileURLWithPath: "/tmp/x/out.zip")) }
        #expect(throws: ToolkitError.self) { try CollectedLogs.osLogArchiveRequest(udid: "u", windowSeconds: 0, output: archive) }
        if xcodeAvailable {
            let target = DeviceTarget(kind: .simulator, udid: "SIM", name: "iPhone", osVersion: "26.0", usbmuxDeviceID: nil, coreDeviceIdentifier: nil, transport: nil)
            let trace = FileManager.default.temporaryDirectory.appendingPathComponent("never-\(UUID().uuidString).trace")
            let record = try CollectedLogs.dvtRecordRequest(target: target, seconds: 30, output: trace)
            #expect(record.arguments.contains("Logging") && record.arguments.contains("30s") && record.arguments.contains("SIM"))
            #expect(throws: ToolkitError.self) { try CollectedLogs.dvtRecordRequest(target: target, seconds: 3600, output: trace) }
            let export = try CollectedLogs.dvtExportRequest(trace: trace, output: URL(fileURLWithPath: "/tmp/x/os-log.xml"))
            #expect(export.arguments.contains(#"/trace-toc/run[@number="1"]/data/table[@schema="os-log"]"#))
        }
    }

    @Test func explainsARefusedArchive() {
        let request = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/log"), arguments: [], displayName: "log collect")
        let refused = CommandResult(request: request, termination: .exited(1), standardOutput: Data(), standardError: Data("log: Must be run as root to collect logs".utf8), startedAt: Date(), finishedAt: Date())
        #expect(CollectedLogs.archiveError(refused).kind == .permissionDenied)
        #expect(CollectedLogs.archiveError(refused).recovery?.contains("never uses administrator rights") == true)
        let other = CommandResult(request: request, termination: .exited(1), standardOutput: Data(), standardError: Data("device not found".utf8), startedAt: Date(), finishedAt: Date())
        #expect(CollectedLogs.archiveError(other).message == "The device's log archive could not be collected.")
    }

    @Test func sourcesAreOfferedPerDeviceKind() {
        #expect(LogStreamKind.available(for: .physical) == [.unified, .classic, .osLogArchive, .dvt])
        #expect(LogStreamKind.available(for: .simulator) == [.simulator, .dvt])
        #expect(LogStreamKind.osLogArchive.isCollected && LogStreamKind.dvt.isCollected && !LogStreamKind.unified.isCollected)
        #expect(LogStreamKind.osLogArchive.artifactExtension == "logarchive" && LogStreamKind.dvt.artifactExtension == "trace")
    }

    /// Plays both collected sources end to end with a runner that stands in for the Apple tools.
    @Test func collectedSourcesYieldLinesAndKeepTheirFiles() async throws {
        let folder = try SecureFileIO.makeTemporaryDirectory(prefix: "collected")
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = FakeToolRunner(exportedXML: Data(Self.exportedXML.utf8))
        let phone = DeviceTarget(kind: .physical, udid: "00008150-000B33334444002E", name: "Phone", osVersion: "26.3", usbmuxDeviceID: 1, coreDeviceIdentifier: nil, transport: .usb)

        let archive = folder.appendingPathComponent("a.logarchive")
        var archiveLines: [LogLine] = []
        var archiveBytes = 0
        for try await chunk in CollectedLogs.stream(.osLogArchive, target: phone, seconds: 60, artifact: archive, runner: runner) {
            archiveLines += chunk.lines; archiveBytes += chunk.spoolBytes.count
        }
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(archiveLines.contains { $0.message == "from the archive" && $0.process == "backboardd" })
        #expect(archiveLines.first?.level == "note" && archiveBytes > 0)

        if xcodeAvailable {
            let trace = folder.appendingPathComponent("d.trace")
            var dvtLines: [LogLine] = []
            for try await chunk in CollectedLogs.stream(.dvt, target: phone, seconds: 30, artifact: trace, runner: runner) { dvtLines += chunk.lines }
            #expect(FileManager.default.fileExists(atPath: trace.path))
            #expect(dvtLines.contains { $0.message == "Launched Maps" && $0.timestamp != nil })

            // Instruments may report run issues (exit 2) yet keep a usable trace: it is read, with a note.
            runner.recordWithRunIssues = true
            var withIssues: [LogLine] = []
            for try await chunk in CollectedLogs.stream(.dvt, target: phone, seconds: 30, artifact: folder.appendingPathComponent("e.trace"), runner: runner) { withIssues += chunk.lines }
            #expect(withIssues.contains { $0.message == "Launched Maps" })
            #expect(withIssues.contains { $0.level == "note" && $0.message.contains("Run issues were detected") })
            runner.recordWithRunIssues = false
        }

        // A refusal from `log collect` surfaces as a plain-language error.
        runner.refuseCollect = true
        await #expect(throws: ToolkitError.self) {
            for try await _ in CollectedLogs.stream(.osLogArchive, target: phone, seconds: 60, artifact: folder.appendingPathComponent("b.logarchive"), runner: runner) {}
        }
    }
}

/// Stands in for `log` and `xctrace`: creates the files they would write and streams output.
final class FakeToolRunner: CommandRunning, @unchecked Sendable {
    let exportedXML: Data
    var refuseCollect = false
    var recordWithRunIssues = false
    let requests = LockedValue<[CommandRequest]>([])
    init(exportedXML: Data) { self.exportedXML = exportedXML }

    private func output(_ request: CommandRequest) -> URL? {
        request.arguments.firstIndex(of: "--output").map { URL(fileURLWithPath: request.arguments[$0 + 1]) }
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.withLock { $0.append(request) }
        let args = request.arguments
        var code: Int32 = 0, stderr = ""
        if args.first == "collect" {
            if refuseCollect { code = 1; stderr = "log: Must be run as root" } else if let out = output(request) { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        } else if args.contains("record"), let out = output(request) {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if recordWithRunIssues { code = 2; stderr = "Run issues were detected (trace is still ready to be viewed):\n* [Error] Target failed to run" }
        } else if args.contains("--toc"), let out = output(request) {
            try Data("<trace-toc><run number=\"1\"><info><summary><start-date>2027-01-15T08:00:00.000Z</start-date></summary></info></run></trace-toc>".utf8).write(to: out)
        } else if args.contains("--xpath"), let out = output(request) {
            try exportedXML.write(to: out)
        }
        return CommandResult(request: request, termination: .exited(code), standardOutput: Data(), standardError: Data(stderr.utf8), startedAt: Date(), finishedAt: Date())
    }

    func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // `log show --style ndjson`
            continuation.yield(.standardOutput(Data(#"{"timestamp":"2027-01-15 08:00:01.000000+0000","processImagePath":"/usr/libexec/backboardd","processID":61,"messageType":"Default","eventMessage":"from the archive"}"#.utf8 + [0x0A])))
            continuation.yield(.finished(CommandResult(request: request, termination: .exited(0), standardOutput: Data(), standardError: Data(), startedAt: Date(), finishedAt: Date())))
            continuation.finish()
        }
    }
}
