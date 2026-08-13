import Testing
@testable import Ghostty

@Suite
struct SessionRestoreCommandTests {
    // MARK: - Claude detection
    //
    // Claude Code installs itself at `<data dir>/claude/versions/<version>`
    // and symlinks a stable `claude` onto PATH, so the resolved executable's
    // own name is a version number. Every case below must keep passing when
    // that number changes, which is what the future-version cases are for.

    @Test func claudeFromPathName() {
        let cmd = SessionRestoreCommand.detect(
            argv: ["claude"],
            executablePath: "/Users/someone/.local/share/claude/versions/2.1.229")
        #expect(cmd?.kind == .claude)
    }

    @Test func claudeFromFutureVersionPathName() {
        let cmd = SessionRestoreCommand.detect(
            argv: ["claude", "--continue"],
            executablePath: "/Users/someone/.local/share/claude/versions/99.0.0-beta.1")
        #expect(cmd?.kind == .claude)
    }

    /// Even with argv[0] giving us nothing useful, the versioned install
    /// layout alone has to be enough.
    @Test func claudeFromVersionedLayoutAlone() {
        #expect(SessionRestoreCommand.detect(
            argv: ["2.1.229"],
            executablePath: "/Users/someone/.local/share/claude/versions/2.1.229")?.kind == .claude)

        #expect(SessionRestoreCommand.detect(
            argv: ["99.0.0-beta.1"],
            executablePath: "/opt/claude/versions/99.0.0-beta.1")?.kind == .claude)
    }

    @Test func claudeFromAbsolutePath() {
        let cmd = SessionRestoreCommand.detect(
            argv: ["/opt/homebrew/bin/claude"],
            executablePath: "/opt/homebrew/bin/claude")
        #expect(cmd?.kind == .claude)
    }

    @Test func claudeFromScriptRunner() {
        #expect(SessionRestoreCommand.detect(
            argv: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/claude/cli.js"],
            executablePath: "/usr/local/bin/node")?.kind == .claude)

        #expect(SessionRestoreCommand.detect(
            argv: ["bun", "/Users/someone/.bun/bin/claude"],
            executablePath: "/Users/someone/.bun/bin/bun")?.kind == .claude)
    }

    /// A directory that merely happens to be called "claude" is not Claude.
    @Test func claudeDirectoryNameAloneIsNotEnough() {
        #expect(SessionRestoreCommand.detect(
            argv: ["vim"],
            executablePath: "/Users/claude/bin/vim") == nil)
    }

    // MARK: - ssh detection

    @Test func sshDetection() {
        let cmd = SessionRestoreCommand.detect(argv: ["ssh", "example-host"], executablePath: "/usr/bin/ssh")
        #expect(cmd?.kind == .ssh)
        #expect(cmd?.argv == ["ssh", "example-host"])
    }

    // MARK: - Negatives

    @Test func shellsAndOtherProgramsAreNotRestored() {
        // A login shell arrives as "-zsh".
        #expect(SessionRestoreCommand.detect(argv: ["-zsh"], executablePath: "/bin/zsh") == nil)
        #expect(SessionRestoreCommand.detect(argv: ["/bin/bash"], executablePath: "/bin/bash") == nil)
        #expect(SessionRestoreCommand.detect(argv: ["vim", "a.txt"], executablePath: "/usr/bin/vim") == nil)
        #expect(SessionRestoreCommand.detect(argv: ["rm", "-rf", "build"], executablePath: "/bin/rm") == nil)
        #expect(SessionRestoreCommand.detect(argv: [], executablePath: nil) == nil)
        #expect(SessionRestoreCommand.detect(argv: [""], executablePath: nil) == nil)
    }

    // MARK: - Replay

    @Test func claudeReplaysWithContinue() {
        let cmd = SessionRestoreCommand(kind: .claude, argv: ["claude", "--verbose"])
        #expect(cmd.shellCommandLine() == "claude --continue")
    }

    @Test func sshReplaysVerbatimWithoutRemotePwd() {
        let cmd = SessionRestoreCommand(kind: .ssh, argv: ["ssh", "example-host"])
        #expect(cmd.shellCommandLine() == "ssh example-host")
    }

    // MARK: - Process argv parsing

    @Test func parsesProcArgs2Blob() throws {
        var blob: [UInt8] = []
        withUnsafeBytes(of: CInt(2).littleEndian) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: Array("/usr/bin/ssh".utf8) + [0])
        blob.append(contentsOf: [0, 0, 0])  // alignment padding
        blob.append(contentsOf: Array("ssh".utf8) + [0])
        blob.append(contentsOf: Array("example-host".utf8) + [0])
        blob.append(contentsOf: Array("SHELL=/bin/zsh".utf8) + [0])

        #expect(ProcessCommandLine.parse(procArgs2: blob) == ["ssh", "example-host"])
    }

    /// A blob cut short must produce nothing rather than a truncated command.
    @Test func rejectsTruncatedProcArgs2Blob() {
        var blob: [UInt8] = []
        withUnsafeBytes(of: CInt(3).littleEndian) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: Array("/usr/bin/ssh".utf8) + [0, 0])
        blob.append(contentsOf: Array("ssh".utf8) + [0])
        blob.append(contentsOf: Array("example-host".utf8) + [0])

        #expect(ProcessCommandLine.parse(procArgs2: blob) == nil)
    }
}
