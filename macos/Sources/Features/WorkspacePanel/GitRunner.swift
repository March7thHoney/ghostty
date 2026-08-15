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
        timeoutSeconds: TimeInterval = 15
    ) async throws -> Output {
        if let reason = await unavailableReason.value { throw RunError.gitUnavailable(reason) }
        return try await spawn(
            ["-C", root.path, "--no-optional-locks"] + args,
            in: root,
            timeoutSeconds: timeoutSeconds)
    }

    /// Spawn git once, racing completion against a timeout that terminates the process.
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

        return try await withThrowingTaskGroup(of: Output?.self) { group in
            group.addTask { try await execute(process, stdout: stdoutPipe, stderr: stderrPipe) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            guard let winner = try await group.next(), let output = winner else {
                if process.isRunning { process.terminate() }
                group.cancelAll()
                throw RunError.timedOut
            }
            group.cancelAll()
            return output
        }
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

    private static func drain(_ handle: FileHandle) async -> Data {
        await Task.detached(priority: .utility) {
            (try? handle.readToEnd()) ?? Data()
        }.value
    }
}
