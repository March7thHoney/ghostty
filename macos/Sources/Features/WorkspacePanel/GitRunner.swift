import Foundation

/// Async wrapper around the git CLI; the app is unsandboxed so `/usr/bin/git` is directly runnable.
enum GitRunner {
    struct Output: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: String
    }

    enum RunError: Error {
        case gitUnavailable(String)
        case timedOut
    }

    private static let gitPath = "/usr/bin/git"

    /// A local checkout answers in milliseconds; a network mount needs tens of seconds per command.
    private static let localTimeout: TimeInterval = 15
    private static let networkTimeout: TimeInterval = 60

    /// How long a terminated git gets to wind down before it is killed outright.
    private static let killGrace: TimeInterval = 2

    /// One probe per launch; `/usr/bin/git` is a CLT shim that fails with a hint when tools are missing.
    private static let unavailableReason: Task<String?, Never> = Task {
        guard let output = try? await spawn(["--version"], in: nil, timeoutSeconds: 10) else {
            return "git could not be started"
        }
        guard output.exitCode == 0 else {
            return output.stderr.isEmpty ? "git is not available" : output.stderr
        }
        return nil
    }

    /// Run git against a repository with prompt-free, lock-free defaults.
    static func run(
        _ args: [String],
        in root: URL,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> Output {
        if let reason = await unavailableReason.value { throw RunError.gitUnavailable(reason) }
        let isLocal = await VolumeIndex.shared.isLocal(root.path)
        return try await spawn(
            statTuning(isLocal: isLocal) + ["-C", root.path, "--no-optional-locks"] + args,
            in: root,
            timeoutSeconds: timeoutSeconds ?? (isLocal ? localTimeout : networkTimeout))
    }

    /// A network mount invents its own inodes and ctimes, so every index entry looks dirty to git.
    private static func statTuning(isLocal: Bool) -> [String] {
        // Comparing size and mtime alone keeps a re-hash of the whole worktree off the wire.
        guard !isLocal else { return [] }
        return ["-c", "core.checkStat=minimal", "-c", "core.trustctime=false"]
    }

    /// Spawn git once, with a watchdog that terminates and then kills a run that overruns its timeout.
    private static func spawn(
        _ args: [String],
        in cwd: URL?,
        timeoutSeconds: TimeInterval
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.qualityOfService = .utility
        if let cwd { process.currentDirectoryURL = cwd }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let expired = Flag()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            expired.set()
            await stop(process)
        }
        defer { watchdog.cancel() }

        let output = try await execute(process, stdout: stdoutPipe, stderr: stderrPipe)
        if expired.isSet { throw RunError.timedOut }
        return output
    }

    /// SIGTERM first, then SIGKILL: git wedged on a stalled mount can outlive the polite signal.
    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(nanoseconds: UInt64(killGrace * 1_000_000_000))
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    /// Drain both pipes concurrently with exit; sequential reads deadlock once a pipe buffer fills.
    private static func execute(
        _ process: Process,
        stdout: Pipe,
        stderr: Pipe
    ) async throws -> Output {
        async let stdoutData = drain(stdout.fileHandleForReading)
        async let stderrData = drain(stderr.fileHandleForReading)

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                // Nothing ever spawned, so EOF the drains ourselves or they'd block forever.
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }

        return Output(
            exitCode: exitCode,
            stdout: await stdoutData,
            stderr: String(decoding: await stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Event-driven reads; a blocking readToEnd holds a cooperative-pool thread until git exits.
    private static func drain(_ handle: FileHandle) async -> Data {
        let buffer = ByteBuffer()
        return await withCheckedContinuation { continuation in
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    buffer.append(chunk)
                    return
                }
                // An empty read is EOF, which is the only place this continuation resumes.
                handle.readabilityHandler = nil
                continuation.resume(returning: buffer.contents)
            }
        }
    }

    /// Accumulator for the reader callback, which Foundation serializes on a queue of its own.
    private final class ByteBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        var contents: Data { lock.withLock { data } }

        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    }

    /// One-way flag the watchdog raises and the spawning task reads.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool { lock.withLock { value } }

        func set() { lock.withLock { value = true } }
    }
}

/// Remembers which roots sit on a network mount, where git costs orders of magnitude more.
private actor VolumeIndex {
    static let shared = VolumeIndex()

    private var cache: [String: Bool] = [:]

    func isLocal(_ path: String) -> Bool {
        if let cached = cache[path] { return cached }
        let local = Self.probe(path)
        cache[path] = local
        return local
    }

    /// MNT_LOCAL covers APFS and HFS but not sshfs, NFS or SMB, which is the split that matters here.
    private static func probe(_ path: String) -> Bool {
        var info: statfs = .init()
        // An unreadable mount is treated as local, so a failure here can't slacken the timeouts.
        guard statfs(path, &info) == 0 else { return true }
        return info.f_flags & UInt32(MNT_LOCAL) != 0
    }
}
