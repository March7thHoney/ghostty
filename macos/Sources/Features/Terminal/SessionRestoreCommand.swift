import Foundation

/// A long-running program that was in the foreground of a surface when we saved
/// our session state, and that we know how to bring back on restore.
///
/// We deliberately recognize only a small set of programs. Replaying an
/// arbitrary saved command line would re-run whatever the user happened to be
/// in the middle of, which is fine for `ssh` and disastrous for `rm`. Anything
/// we don't recognize restores as a plain shell in the saved working directory,
/// which is what Ghostty has always done.
struct SessionRestoreCommand: Codable, Equatable {
    enum Kind: String, Codable {
        /// An SSH session. Restored by re-running the same invocation.
        case ssh

        /// Claude Code. Restored with `--resume <session>` when we know which
        /// conversation the process had open, falling back to `--continue`
        /// (most recent conversation in the working directory) when we don't.
        case claude
    }

    let kind: Kind
    let argv: [String]

    /// The Claude Code session the process had open, from the live-session
    /// registry. The session ID appears nowhere in the process's argv or
    /// environment, so the registry is the only place to learn it.
    var sessionID: String? = nil

    // MARK: - Detection

    /// Detect a restorable command from the foreground process of a surface.
    static func detect(foregroundPID pid: pid_t) -> SessionRestoreCommand? {
        guard let argv = ProcessCommandLine.argv(pid: pid) else { return nil }
        var command = detect(argv: argv, executablePath: ProcessCommandLine.executablePath(pid: pid))
        if command?.kind == .claude {
            command?.sessionID = ClaudeLiveSessionMonitor.sessionID(forPID: pid)
        }
        return command
    }

    /// The detection itself, split out from process inspection so it can be
    /// tested against every install layout we care about.
    static func detect(argv: [String], executablePath: String?) -> SessionRestoreCommand? {
        guard let first = argv.first, !first.isEmpty else { return nil }

        // A login shell is exec'd as "-zsh", so strip the leading dash before
        // treating this as a path. Without it we'd read the dash as part of
        // the program name and never match anything.
        let name = URL(fileURLWithPath: first.hasPrefix("-") ? String(first.dropFirst()) : first)
            .lastPathComponent

        if name == "ssh" {
            return .init(kind: .ssh, argv: argv)
        }

        if isClaude(name: name, argv: argv, executablePath: executablePath) {
            return .init(kind: .claude, argv: argv)
        }

        return nil
    }

    /// Programs that run Claude Code as a script rather than being it.
    private static let scriptRunners: Set<String> = ["node", "bun", "deno"]

    /// Whether this process is Claude Code.
    ///
    /// IMPORTANT: none of these checks may depend on a Claude version. Claude
    /// Code installs itself at `<data dir>/claude/versions/<version>` and
    /// symlinks a stable `claude` into the user's bin directory, so the
    /// *resolved* executable's own name is a version number that changes on
    /// every update. Matching on it would silently stop working the next time
    /// Claude updates. We match the name the user invoked and the surrounding
    /// directory layout instead, both of which are version independent.
    private static func isClaude(
        name: String,
        argv: [String],
        executablePath: String?
    ) -> Bool {
        // The common case: `claude` found on PATH, so argv[0] is the stable
        // name regardless of which version it resolves to.
        if name == "claude" { return true }

        if let executablePath {
            let components = URL(fileURLWithPath: executablePath).pathComponents

            // Invoked by absolute path to a stable entry point, e.g. a
            // Homebrew or system install.
            if components.last == "claude" { return true }

            // The versioned install layout. We only look for the
            // `claude/versions` directory pair, never at the version itself.
            for (i, component) in components.enumerated()
            where component == "claude" && i + 1 < components.count {
                if components[i + 1] == "versions" { return true }
            }
        }

        // The npm-style install, where Claude Code is a script handed to a
        // JavaScript runtime: `node .../claude/cli.js`.
        if scriptRunners.contains(name) {
            for arg in argv.dropFirst() where !arg.hasPrefix("-") {
                let url = URL(fileURLWithPath: arg)
                if url.lastPathComponent == "claude" { return true }
                if url.lastPathComponent == "cli.js",
                   url.deletingLastPathComponent().lastPathComponent == "claude" {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Replay

    /// The line to feed to the restored surface's shell to bring this back.
    ///
    /// This is written into the shell rather than run as the surface's command
    /// so that the surface is still a normal shell session: shell integration
    /// is injected, the working directory keeps being reported, and the tab
    /// survives the program exiting.
    func shellCommandLine() -> String? {
        switch kind {
        case .claude:
            // Resume the exact conversation when we know it; this is what
            // keeps two Claude tabs in the same directory from both resuming
            // the same conversation. Without a session ID, `--continue`
            // resumes the most recent conversation in the working directory
            // we're already being restored into.
            if let sessionID {
                return "claude --resume \(Ghostty.Shell.quote(sessionID))"
            }
            return "claude --continue"

        case .ssh:
            // Re-run the invocation as written; where it had got to on the remote is remote state we're never told about.
            guard !argv.isEmpty else { return nil }
            return argv.map { Ghostty.Shell.quote($0) }.joined(separator: " ")
        }
    }

    // MARK: - Transcripts

    /// Where Claude Code keeps the transcript for a session that ran in the
    /// given directory: `~/.claude/projects/<dir>/<sessionID>.jsonl`, where
    /// `<dir>` is the working directory with every non-alphanumeric character
    /// replaced by "-". Used to notice that a saved session was garbage
    /// collected while Ghostty wasn't running.
    static func transcriptURL(sessionID: String, cwd: String) -> URL {
        let mangled = String(cwd.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": return Character(scalar)
            default: return "-"
            }
        })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(mangled)
            .appendingPathComponent("\(sessionID).jsonl")
    }
}
