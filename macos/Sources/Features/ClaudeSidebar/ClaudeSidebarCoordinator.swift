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

    /// `--fork-session` gives the resume a fresh ID, so the copy lands under the target cwd untouched.
    nonisolated static func forkCommand(sessionID: String) -> String {
        "claude --resume \(Ghostty.Shell.quote(sessionID)) --fork-session"
    }

    /// Open a new tab forking a copied conversation into a project.
    static func pasteConversation(sessionID: String, into cwd: String, from window: NSWindow?) {
        guard directoryExists(cwd) else {
            alertMissingDirectory(cwd, in: window)
            return
        }
        // No pending-spawn guard: it dedupes by session ID, and a second paste should fork again.
        guard spawnTab(cwd: cwd, input: forkCommand(sessionID: sessionID), from: window) != nil
        else { return }
        ClaudeSidebarState.shared.pinProject(cwd)
    }

    /// Confirm, then move a conversation's transcript to the Trash.
    static func deleteConversation(session: ClaudeTranscriptSummary, from window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Delete Conversation?"
        alert.informativeText =
            "\u{201C}\(session.title ?? "Untitled session")\u{201D} will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            trashConversation(session, in: window)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// The Trash rather than a straight unlink, so a slip of the mouse stays recoverable.
    private static func trashConversation(_ session: ClaudeTranscriptSummary, in window: NSWindow?) {
        let fileManager = FileManager.default
        do {
            try fileManager.trashItem(at: session.fileURL, resultingItemURL: nil)
        } catch {
            alertDeleteFailed(error, in: window)
            return
        }

        // Transcripts can have a same-named sidecar directory; orphaning it would just leak.
        let sidecar = session.fileURL.deletingPathExtension()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: sidecar.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            try? fileManager.trashItem(at: sidecar, resultingItemURL: nil)
        }

        ClaudeSidebarState.shared.forgetCopiedConversation(sessionID: session.sessionID)
        // FSEvents would notice within a second; an explicit rescan drops the row immediately.
        ClaudeSessionIndex.shared.scheduleRescan()
    }

    private static func alertDeleteFailed(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Delete Conversation"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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
