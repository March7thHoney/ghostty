import AppKit

/// The actions behind the sidebar: opening a session, focusing one that's
/// already open, and starting new conversations.
@MainActor
enum ClaudeSidebarCoordinator {
    /// Bring a session to the front: focus the tab already running it if
    /// there is one anywhere, otherwise open a new tab that resumes it.
    static func openOrFocus(session: ClaudeTranscriptSummary, from window: NSWindow?) {
        // A tab we spawned for this session that Claude hasn't registered
        // yet. Focusing it (rather than spawning again) is the double-click
        // protection.
        if let pending = ClaudeSidebarState.shared.pendingSpawnController(for: session.sessionID) {
            focus(controller: pending)
            return
        }

        // The session ID never appears in a process's argv, but the live
        // registry maps it to a pid, and a surface whose foreground process
        // is that pid is the tab running it. This finds tabs the user
        // started by hand just as well as ones we spawned.
        if let live = ClaudeLiveSessionMonitor.shared.bySessionID[session.sessionID],
           let (controller, surface) = surfaceRunning(pid: live.pid) {
            controller.focusSurface(surface)
            return
        }

        // `claude --resume` looks sessions up per working directory, so the
        // resume must happen in the session's own cwd or it won't be found.
        guard directoryExists(session.cwd) else {
            alertMissingDirectory(session.cwd, in: window)
            return
        }
        guard let controller = spawnTab(
            cwd: session.cwd,
            input: "claude --resume \(Ghostty.Shell.quote(session.sessionID))",
            from: window)
        else { return }
        ClaudeSidebarState.shared.notePendingSpawn(
            sessionID: session.sessionID, controller: controller)
    }

    /// Open a new tab running a fresh Claude conversation in a directory.
    static func newConversation(cwd: String?, from window: NSWindow?) {
        let cwd = cwd ?? NSHomeDirectory()
        guard directoryExists(cwd) else {
            alertMissingDirectory(cwd, in: window)
            return
        }
        _ = spawnTab(cwd: cwd, input: "claude", from: window)
    }

    // MARK: - Helpers

    /// The surface (and its controller) whose foreground process is `pid`,
    /// searched across every terminal window.
    private static func surfaceRunning(
        pid: pid_t
    ) -> (BaseTerminalController, Ghostty.SurfaceView)? {
        for controller in TerminalController.all {
            for surface in controller.surfaceTree
            where surface.surfaceModel?.foregroundPID == Int(pid) {
                return (controller, surface)
            }
        }
        return nil
    }

    private static func focus(controller: TerminalController) {
        controller.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }

    private static func spawnTab(
        cwd: String,
        input: String,
        from window: NSWindow?
    ) -> TerminalController? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return nil }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        // Typed into the shell rather than run as the surface's command so
        // the surface stays a normal shell session (and stays restorable;
        // setting `command` marks the window unrestorable).
        config.initialInput = "\(input)\n"
        return TerminalController.newTab(
            appDelegate.ghostty, from: window, withBaseConfig: config)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func alertMissingDirectory(_ path: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Project Folder Missing"
        alert.informativeText = "The directory for this session no longer exists:\n\(path)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
