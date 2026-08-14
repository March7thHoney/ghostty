import AppKit

/// The actions behind the sidebar: opening, focusing, and starting sessions.
@MainActor
enum ClaudeSidebarCoordinator {
    /// Focus the tab already running this session anywhere, otherwise open a new tab resuming it.
    static func openOrFocus(session: ClaudeTranscriptSummary, from window: NSWindow?) {
        // A tab we spawned whose Claude hasn't registered yet; focusing it is the double-click guard.
        if let pending = ClaudeSidebarState.shared.pendingSpawnController(for: session.sessionID) {
            focus(controller: pending)
            return
        }

        // Session IDs never appear in argv, but the registry maps one to a pid we can match.
        if let live = ClaudeLiveSessionMonitor.shared.bySessionID[session.sessionID],
           let (controller, surface) = surfaceRunning(pid: live.pid) {
            controller.focusSurface(surface)
            return
        }

        // `claude --resume` looks sessions up per directory, so it must run in the session's own cwd.
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
        ClaudeSidebarState.shared.pinProject(session.cwd)
    }

    /// Open a new tab running a fresh Claude conversation in a directory.
    static func newConversation(cwd: String?, from window: NSWindow?) {
        let cwd = cwd ?? NSHomeDirectory()
        guard directoryExists(cwd) else {
            alertMissingDirectory(cwd, in: window)
            return
        }
        guard spawnTab(cwd: cwd, input: "claude", from: window) != nil else { return }
        ClaudeSidebarState.shared.pinProject(cwd)
    }

    /// Ask for a directory and add it to the sidebar.
    static func addProject(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? url.hasDirectoryPath
            let dir = isDirectory ? url : url.deletingLastPathComponent()
            ClaudeSidebarState.shared.pinProject(dir.path(percentEncoded: false))
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    /// Show the project directory in Finder.
    static func revealInFinder(cwd: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    /// VS Code's location, nil when it isn't installed.
    static var vsCodeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
    }

    /// Open the project directory in VS Code.
    static func openInVSCode(cwd: String) {
        guard let appURL = vsCodeURL else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: cwd, isDirectory: true)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Helpers

    /// The surface and controller whose foreground process is `pid`, across every terminal window.
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
        // Typed into the shell, not run as the surface's command, which would mark the window unrestorable.
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
