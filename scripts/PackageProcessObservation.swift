import Darwin
import Foundation
import ToolkitCore

/// Observes only this helper and its direct xcrun/simctl child. Sampling perturbs execution;
/// PID identity checks bracket attachment but cannot make the external sample attach atomic.
struct PackageProcessObservation: Sendable {
    let runner: ProcessCommandRunner

    enum Target: String, Encodable, Sendable { case helper, xcrun, simctl }
    enum Stage: String, Encodable, Sendable { case identity, children, sample, read, parse, cleanup }
    enum Code: String, Encodable, Sendable {
        case unavailable, invalidMetadata, capacityReached, ambiguous, changedIdentity
        case commandFailed, unreadable, oversized, missingCallGraph, cleanupFailed
    }
    enum SampleStatus: String, Encodable, Sendable { case captured, cancelled, unavailable }

    struct Failure: Encodable, Sendable {
        let stage: Stage
        let code: Code
        let systemCode: Int32?
        let toolkitKind: String?
    }
    struct ChildState: Encodable, Sendable {
        let pid: Int32
        let parent: Int32
        let uid: UInt32
        let birthSeconds: UInt64
        let birthMicroseconds: UInt64
        let state: UInt32
        let target: Target
    }
    struct Snapshot: Encodable, Sendable {
        let elapsedMilliseconds: Int64
        let helperState: UInt32
        let matchingChildren: Int
        let child: ChildState?
    }
    struct Counts: Encodable, Sendable {
        var frameLines = 0
        var machMessage = 0
        var xpc = 0
        var coreSimulator = 0
        var read = 0
        var write = 0
        var fileHandle = 0
        var consume = 0
        var finish = 0
        var lock = 0
        var semaphore = 0
        var dispatch = 0
        var processWait = 0
    }
    struct Sample: Encodable, Sendable {
        let target: Target
        let elapsedMilliseconds: Int64
        let status: SampleStatus
        let counts: Counts?
    }
    struct Report: Encodable, Sendable {
        let helperPID: Int32
        let elapsedMilliseconds: Int64
        let snapshots: [Snapshot]
        let samples: [Sample]
        let failures: [Failure]
        let omittedFailures: Int
        let observerCancelled: Bool
        let iterationLimitReached: Bool
    }
    private struct Identity: Equatable, Sendable {
        let pid: Int32
        let parent: Int32
        let uid: UInt32
        let birthSeconds: UInt64
        let birthMicroseconds: UInt64
        let name: String
        let path: String

        var queryTarget: Target? {
            guard URL(fileURLWithPath: path).lastPathComponent == name else { return nil }
            if name == "xcrun" { return .xcrun }
            if name == "simctl" { return .simctl }
            return nil
        }
    }
    private struct ProcessState {
        let identity: Identity
        let state: UInt32
    }
    private struct Fault: Error {
        let failure: Failure
        let closeFailure: Failure?
    }

    func collect() async -> Report {
        let clock = ContinuousClock()
        let started = clock.now
        let helperPID = getpid()
        var snapshots: [Snapshot] = []
        var samples: [Sample] = []
        var failures: [Failure] = []
        var iterations = 0
        var sampled = false
        var cancelled = false
        for _ in 0..<70 {
            if Task.isCancelled { cancelled = true; break }
            iterations += 1
            do {
                let helper = try Self.identity(helperPID)
                guard helper.identity.uid == geteuid() else { throw Self.fault(.identity, .invalidMetadata, nil) }
                let children = try Self.children(helperPID).compactMap { pid -> ProcessState? in
                    let child = try Self.identity(pid)
                    guard child.identity.parent == helperPID, child.identity.uid == geteuid(),
                          child.identity.queryTarget != nil else { return nil }
                    return child
                }
                let elapsed = Self.milliseconds(started.duration(to: clock.now))
                let child = children.count == 1 ? children[0] : nil
                snapshots.append(Snapshot(elapsedMilliseconds: elapsed, helperState: helper.state,
                                          matchingChildren: children.count, child: child.flatMap(Self.childState)))
                if children.count > 1 { throw Self.fault(.children, .ambiguous, nil) }
                if !sampled, elapsed >= 20_000, let child, let target = child.identity.queryTarget {
                    sampled = true
                    let childResult = await sample(child.identity, target: target, started: started, clock: clock)
                    samples.append(childResult.sample)
                    failures.append(contentsOf: childResult.failures)
                    if !Task.isCancelled {
                        let helperResult = await sample(helper.identity, target: .helper, started: started, clock: clock)
                        samples.append(helperResult.sample)
                        failures.append(contentsOf: helperResult.failures)
                    }
                }
            } catch let error as Fault {
                failures.append(error.failure)
            } catch {
                failures.append(Failure(stage: .identity, code: .unavailable, systemCode: nil, toolkitKind: nil))
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { cancelled = true; break }
        }
        return Report(helperPID: helperPID, elapsedMilliseconds: Self.milliseconds(started.duration(to: clock.now)),
                      snapshots: snapshots, samples: samples, failures: Array(failures.prefix(16)), omittedFailures: max(0, failures.count - 16),
                      observerCancelled: cancelled || Task.isCancelled, iterationLimitReached: !cancelled && !Task.isCancelled && iterations == 70)
    }

    static func write(_ report: Report) throws {
        let encoded = try JSONEncoder().encode(report)
        guard encoded.count <= 32_768 else {
            throw ToolkitError(.internalInconsistency, message: "Post-boot process diagnostics exceeded their output bound.", recovery: "Inspect the bounded observation schema.", technicalDetail: nil)
        }
        var line = Data("[package fixtures] postboot-process ".utf8)
        line.append(encoded)
        line.append(10)
        try FileHandle.standardError.write(contentsOf: line)
    }

    private static func childState(_ process: ProcessState) -> ChildState? {
        let id = process.identity
        guard let target = id.queryTarget else { return nil }
        return ChildState(pid: id.pid, parent: id.parent, uid: id.uid, birthSeconds: id.birthSeconds,
                          birthMicroseconds: id.birthMicroseconds, state: process.state, target: target)
    }

    private static func children(_ parent: Int32) throws -> [Int32] {
        var pids = [pid_t](repeating: 0, count: 32)
        errno = 0
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        let code = errno
        guard count >= 0, count < pids.count else { throw fault(.children, .capacityReached, code) }
        guard count != 0 || code == 0 else { throw fault(.children, .unavailable, code) }
        let selected = Array(pids.prefix(Int(count)))
        guard selected.allSatisfy({ $0 > 0 }) else { throw fault(.children, .invalidMetadata, nil) }
        return selected
    }

    private static func identity(_ pid: Int32) throws -> ProcessState {
        var info = proc_bsdinfo()
        errno = 0
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { throw fault(.identity, .unavailable, errno) }
        let nameBytes = withUnsafeBytes(of: info.pbi_comm) { Array($0.prefix { $0 != 0 }) }
        // proc_info.h defines the maximum as 4 * MAXPATHLEN; Swift cannot import that macro.
        var pathBytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        errno = 0
        let length = pathBytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0, length < pathBytes.count, let end = pathBytes.firstIndex(of: 0), end > 0,
              let path = String(bytes: pathBytes.prefix(end).map { UInt8(bitPattern: $0) }, encoding: .utf8),
              let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty,
              path.hasPrefix("/"), info.pbi_pid == UInt32(pid), info.pbi_ppid <= UInt32(Int32.max),
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { throw fault(.identity, .invalidMetadata, nil) }
        return ProcessState(identity: Identity(pid: pid, parent: Int32(info.pbi_ppid), uid: info.pbi_uid,
                                               birthSeconds: info.pbi_start_tvsec, birthMicroseconds: info.pbi_start_tvusec,
                                               name: name, path: path), state: info.pbi_status)
    }

    private func sample(_ expected: Identity, target: Target, started: ContinuousClock.Instant, clock: ContinuousClock) async -> (sample: Sample, failures: [Failure]) {
        let elapsed = Self.milliseconds(started.duration(to: clock.now))
        var directory: URL?
        var counts: Counts?
        var status = SampleStatus.unavailable
        var failures: [Failure] = []
        do {
            guard try Self.identity(expected.pid).identity == expected else { throw Self.fault(.sample, .changedIdentity, nil) }
            try Task.checkCancellation()
            let root = try SecureFileIO.makeTemporaryDirectory(prefix: "idt-postboot-sample")
            directory = root
            let file = root.appendingPathComponent("sample.txt")
            try SecureFileIO.writeNewFile(Data(), to: file, mode: 0o600)
            let request = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/sample"),
                                         arguments: [String(expected.pid), "1", "10", "-mayDie", "-file", file.path],
                                         environment: CommandEnvironment.minimal(adding: [:]), workingDirectory: root, standardInput: nil,
                                         timeout: 8, outputLimit: 8192, displayName: "postboot process sample", terminationGracePeriod: 1)
            let result = try await runSample(request)
            try Task.checkCancellation()
            guard result.succeeded else { throw Self.fault(.sample, .commandFailed, result.exitCode) }
            guard try Self.identity(expected.pid).identity == expected else { throw Self.fault(.sample, .changedIdentity, nil) }
            counts = try Self.parse(Self.read(file))
            status = .captured
        } catch is CancellationError {
            status = .cancelled
        } catch let error as Fault {
            failures.append(error.failure)
            if let close = error.closeFailure { failures.append(close) }
        } catch let error as ToolkitError {
            if Task.isCancelled { status = .cancelled }
            else { failures.append(Failure(stage: .sample, code: .commandFailed, systemCode: nil, toolkitKind: error.kind.rawValue)) }
        } catch {
            failures.append(Failure(stage: .sample, code: .unavailable, systemCode: nil, toolkitKind: nil))
        }
        if let directory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { failures.append(Failure(stage: .cleanup, code: .cleanupFailed, systemCode: nil, toolkitKind: nil)) }
        }
        return (Sample(target: target, elapsedMilliseconds: elapsed, status: status, counts: counts), failures)
    }

    /// Cancellation signals the sampler while its independent consumer retains ownership
    /// through actual exit. The caller can then remove the report without a live writer.
    private func runSample(_ request: CommandRequest) async throws -> CommandResult {
        let cancellation = CommandCancellation()
        let consumer = Task.detached(priority: .utility) {
            var final: CommandResult?
            for try await event in runner.stream(request, cancellation: cancellation) {
                if case .finished(let result) = event { final = result }
            }
            guard let final else {
                throw ToolkitError(.internalInconsistency, message: "The process sampler ended without a result.", recovery: "Inspect the sampler's lifecycle.", technicalDetail: nil)
            }
            return final
        }
        return try await withTaskCancellationHandler {
            try await consumer.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func read(_ file: URL) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw fault(.read, .unreadable, errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var outcome: Result<Data, Fault>
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw fault(.read, .unreadable, errno) }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
                  metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
                  metadata.st_size > 0, metadata.st_size <= 2_097_152 else { throw fault(.read, .invalidMetadata, nil) }
            guard let data = try handle.read(upToCount: 2_097_153) else { throw fault(.read, .unreadable, nil) }
            guard !data.isEmpty, data.count <= 2_097_152 else { throw fault(.read, .oversized, nil) }
            outcome = .success(data)
        } catch let error as Fault { outcome = .failure(error) }
        catch { outcome = .failure(fault(.read, .unreadable, nil)) }
        do { try handle.close() }
        catch {
            let close = Failure(stage: .read, code: .unreadable, systemCode: nil, toolkitKind: nil)
            switch outcome {
            case .success: throw Fault(failure: close, closeFailure: nil)
            case .failure(let primary): throw Fault(failure: primary.failure, closeFailure: close)
            }
        }
        return try outcome.get()
    }

    private static func parse(_ data: Data) throws -> Counts {
        guard let text = String(data: data, encoding: .utf8) else { throw fault(.parse, .invalidMetadata, nil) }
        var active = false
        var ended = false
        var counts = Counts()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Call graph:" { active = true; continue }
            if active, trimmed.hasPrefix("Total number in stack") || trimmed.hasPrefix("Binary Images:") || trimmed.hasPrefix("Sort by top of stack") { ended = true; break }
            guard active, line.contains("(in ") else { continue }
            counts.frameLines += 1
            if line.contains("mach_msg") { counts.machMessage += 1 }
            if line.contains("xpc_") || line.contains("XPC") { counts.xpc += 1 }
            if line.contains("CoreSimulator") || line.contains("SimService") { counts.coreSimulator += 1 }
            if line.contains("__read") || line.contains(" read +") { counts.read += 1 }
            if line.contains("__write") || line.contains(" write +") { counts.write += 1 }
            if line.contains("FileHandle") { counts.fileHandle += 1 }
            if line.contains("consume(") || line.contains("consume_") { counts.consume += 1 }
            if line.contains("ProcessExecution.finish") { counts.finish += 1 }
            if ["NSLock", "NSRecursiveLock", "pthread_mutex", "pthread_rwlock", "os_unfair_lock", "__ulock_wait", "__psynch_mutexwait", "__psynch_rw"].contains(where: line.contains) { counts.lock += 1 }
            if line.contains("semaphore") { counts.semaphore += 1 }
            if line.contains("dispatch_") { counts.dispatch += 1 }
            if line.contains("wait4") || line.contains("waitpid") { counts.processWait += 1 }
        }
        guard active, ended, counts.frameLines > 0 else { throw fault(.parse, .missingCallGraph, nil) }
        return counts
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

    private static func fault(_ stage: Stage, _ code: Code, _ systemCode: Int32?) -> Fault {
        Fault(failure: Failure(stage: stage, code: code, systemCode: systemCode, toolkitKind: nil), closeFailure: nil)
    }
}
