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

        /// Claude Code. Restored with `--continue`, which resumes the most
        /// recent conversation in the working directory we're restoring into.
        case claude
    }

    let kind: Kind
    let argv: [String]

    // MARK: - Detection

    /// Detect a restorable command from the foreground process of a surface.
    static func detect(foregroundPID pid: pid_t) -> SessionRestoreCommand? {
        guard let argv = ProcessCommandLine.argv(pid: pid) else { return nil }
        return detect(argv: argv, executablePath: ProcessCommandLine.executablePath(pid: pid))
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
    func shellCommandLine(remotePwd: Ghostty.RemotePwd? = nil) -> String? {
        switch kind {
        case .claude:
            // We're already being restored into the saved working directory,
            // and `--continue` resumes the most recent conversation there.
            // Note that two Claude tabs in the same directory will therefore
            // both resume the same conversation.
            return "claude --continue"

        case .ssh:
            return sshCommandLine(remotePwd: remotePwd)
        }
    }

    private func sshCommandLine(remotePwd: Ghostty.RemotePwd?) -> String? {
        guard let program = argv.first else { return nil }
        let args = Array(argv.dropFirst())

        let plain = ([program] + args).map { Ghostty.Shell.quote($0) }.joined(separator: " ")

        // Only worth doing anything clever if we know where the remote session
        // was, and only if the user's own invocation didn't already carry a
        // remote command: appending to that would change what they asked for.
        guard let remotePwd, !remotePwd.path.isEmpty else { return plain }
        guard !Self.hasRemoteCommand(args: args) else { return plain }
        guard let remoteCommand = Self.remoteChdirCommand(path: remotePwd.path) else { return plain }

        // `-t` goes up front, where it's unambiguously an ssh option, and the
        // remote command goes last, after the destination.
        //
        // `RemoteCommand=none` is required, not cosmetic: if the user's ssh
        // config sets a RemoteCommand for this host, ssh refuses to also take
        // one on the command line ("Cannot execute command-line and remote
        // command") and the reconnect fails outright. Overriding it is safe
        // for the shape of RemoteCommand people actually configure — a shell
        // to log into — because that is exactly what we launch below, just
        // pointed at the directory they left off in.
        let parts = [program, "-t", "-o", "RemoteCommand=none"] + args + [remoteCommand]
        return parts.map { Ghostty.Shell.quote($0) }.joined(separator: " ")
    }

    /// ssh options that consume the following argument.
    private static let sshOptionsWithArgument: Set<Character> = [
        "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
        "m", "O", "o", "P", "p", "Q", "R", "S", "W", "w",
    ]

    /// Whether an ssh argument list already specifies a command to run on the
    /// remote host (i.e. there's a non-option argument after the destination).
    static func hasRemoteCommand(args: [String]) -> Bool {
        var sawDestination = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            index += 1

            guard arg.hasPrefix("-"), arg != "-" else {
                // The first non-option is the destination; anything after it
                // is the remote command. Note ssh keeps parsing options after
                // the destination, so we can't stop at the first one.
                if sawDestination { return true }
                sawDestination = true
                continue
            }

            // Short options cluster ("-tv"), and the first one that takes an
            // argument swallows the rest of the cluster or the next argument.
            let chars = Array(arg.dropFirst())
            var position = 0
            while position < chars.count {
                let flag = chars[position]
                position += 1
                guard sshOptionsWithArgument.contains(flag) else { continue }
                // If the flag ends the cluster its value is the next argument,
                // otherwise the rest of the cluster is the value.
                if position == chars.count { index += 1 }
                break
            }
        }

        return false
    }

    /// Build the remote command that puts a reconnected session back in the
    /// directory it was in. Returns nil if we can't tell what shape the path is.
    ///
    /// This is best effort by nature: we only ever know the remote directory if
    /// the remote shell reports it (OSC 7), which most don't do out of the box.
    static func remoteChdirCommand(path: String) -> String? {
        guard !path.isEmpty else { return nil }

        if let windowsPath = windowsPath(from: path) {
            // Windows remotes land in PowerShell, where `cd && exec` is
            // meaningless. Re-launch PowerShell so the session stays interactive.
            let escaped = windowsPath.replacingOccurrences(of: "'", with: "''")
            return "powershell -NoExit -Command \"Set-Location -LiteralPath '\(escaped)'\""
        }

        guard path.hasPrefix("/") else { return nil }
        // `exec` so the login shell replaces us rather than nesting, and the
        // `${SHELL:-/bin/sh}` fallback covers accounts with no SHELL set.
        return "cd \(Ghostty.Shell.quote(path)) && exec \"${SHELL:-/bin/sh}\" -l"
    }

    /// Recognize a Windows path as reported over OSC 7, which arrives with a
    /// leading slash from the URL: `/C:/Users/someone`.
    static func windowsPath(from path: String) -> String? {
        var candidate = Substring(path)
        if candidate.hasPrefix("/") { candidate = candidate.dropFirst() }

        // A drive letter followed by a colon is the only reliable signal.
        var iterator = candidate.makeIterator()
        guard let drive = iterator.next(), drive.isLetter else { return nil }
        guard iterator.next() == ":" else { return nil }

        return String(candidate)
    }
}
