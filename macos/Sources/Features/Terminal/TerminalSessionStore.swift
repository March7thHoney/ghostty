import AppKit
import OSLog

/// Persists the open terminal windows to disk so they can be brought back the
/// next time Ghostty launches.
///
/// AppKit already has a restoration mechanism, and we still use it: see
/// `TerminalWindowRestoration`. But it only restores when AppKit decides to,
/// which in practice means a clean quit while the system is configured to keep
/// windows. Quit after being force killed, or with the system setting off, and
/// there is nothing to restore. This store fills that gap by keeping our own
/// snapshot that we control the lifetime of.
///
/// The two paths don't fight: we only restore when AppKit produced no windows
/// of its own, so whichever mechanism ran first wins.
///
/// A snapshot describes the windows that were open at the time it was written.
/// Closing a tab removes it from the next snapshot, so closing tabs and then
/// quitting restores only what was still open, which is what people expect
/// from "restore my session".
@MainActor
final class TerminalSessionStore {
    static let shared = TerminalSessionStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: TerminalSessionStore.self)
    )

    /// How long we wait after a change before writing. Changes arrive in
    /// bursts (a split resize, a flurry of directory changes), and none of
    /// them are urgent.
    private static let debounceInterval: TimeInterval = 1

    /// How often we snapshot even when nothing told us to. This is what makes
    /// us survive a force kill or a panic: without it we'd only ever be as
    /// fresh as the last event we happened to hear about, and starting a
    /// long-running program doesn't raise any event we observe.
    private static let periodicInterval: TimeInterval = 30

    private var debounceTimer: Timer?
    private var periodicTimer: Timer?

    /// The bytes we last wrote, so a periodic tick that finds nothing new
    /// doesn't touch the disk.
    private var lastWritten: Data?

    /// Set while we're rebuilding windows, so restoring doesn't immediately
    /// overwrite the snapshot it is halfway through reading.
    private var isRestoring: Bool = false

    /// Set once we've written our final snapshot on quit. Windows closing as
    /// part of shutting down must not replace it with an empty one.
    private var savesSuspended: Bool = false

    /// Controllers whose windows are on their way out. `windowWillClose` fires
    /// while the window is still in `NSApplication.shared.windows`, so without
    /// this a snapshot taken during a close would still contain it.
    private let closing: NSHashTable<TerminalController> = .weakObjects()

    private init() {}

    // MARK: - Saving

    /// Note that something changed and a snapshot should be written soon.
    func setNeedsSave() {
        guard isEnabled, !isRestoring, !savesSuspended else { return }

        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }

        startPeriodicTimerIfNeeded()
    }

    /// Note that a controller is closing and must be left out of snapshots.
    func willClose(_ controller: TerminalController) {
        closing.add(controller)
        setNeedsSave()
    }

    /// Write a snapshot right now, skipping the debounce.
    ///
    /// Call this from the quit path: it has to happen while the windows are
    /// still up and, more importantly, while their child processes are still
    /// alive, since that's the only way to tell what they were running.
    func saveImmediately() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        save()
    }

    /// Stop writing snapshots. Used after the final save on quit so that
    /// windows closing during shutdown don't erase it.
    func suspendSaves() {
        savesSuspended = true
        debounceTimer?.invalidate()
        debounceTimer = nil
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    /// Resume writing snapshots after a quit was cancelled.
    func resumeSaves() {
        guard savesSuspended else { return }
        savesSuspended = false
        setNeedsSave()
    }

    private func startPeriodicTimerIfNeeded() {
        guard periodicTimer == nil else { return }
        periodicTimer = Timer.scheduledTimer(
            withTimeInterval: Self.periodicInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }
    }

    private func save() {
        guard !isRestoring, !savesSuspended else { return }
        guard let url = Self.snapshotURL else { return }

        guard isEnabled else {
            // The user turned restoration off, so stop leaving their working
            // directories lying around on disk.
            try? FileManager.default.removeItem(at: url)
            lastWritten = nil
            return
        }

        let windows = windowSnapshots()

        // Closing the last window must not erase the session. Someone who
        // closes their window and then quits still expects to find their
        // terminals when they come back, so the last non-empty snapshot is
        // kept rather than replaced with an empty one. Closing a tab while
        // others remain still drops that tab, because the snapshot written
        // then is non-empty and describes what's left.
        guard !windows.isEmpty else { return }

        let snapshot = Snapshot(windows: windows)
        let encoder = JSONEncoder()
        // Stable key order, so an unchanged session encodes to identical bytes
        // and the write below can be skipped.
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            Self.logger.warning("failed to encode session snapshot: \(error, privacy: .public)")
            return
        }

        guard data != lastWritten else { return }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            // The snapshot names every directory the user was working in and
            // every host they were connected to, so keep it to the owner.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastWritten = data
        } catch {
            Self.logger.warning("failed to write session snapshot: \(error, privacy: .public)")
        }
    }

    /// Snapshot every open terminal window, grouped so tabs come back as tabs.
    ///
    /// Everything here is derived from window identity rather than from
    /// iteration order or fresh UUIDs, so that a snapshot of an unchanged
    /// session encodes to identical bytes. That's what lets the periodic write
    /// notice there's nothing new and leave the disk alone.
    private func windowSnapshots() -> [Snapshot.Window] {
        // (group, tab, window) sort keys alongside the snapshot itself.
        // `NSApp.windows` is ordered front-to-back and so reshuffles every time
        // the user changes windows.
        var entries: [(group: Int, tab: Int, number: Int, snapshot: Snapshot.Window)] = []

        for controller in TerminalController.all {
            guard !closing.contains(controller) else { continue }
            guard let window = controller.window else { continue }
            guard controller.restorable else { continue }
            guard !controller.surfaceTree.isEmpty else { continue }

            // Only windows that are actually grouped need a group ID. A lone
            // window carrying one would just create an empty tab bar on restore.
            var groupID: String?
            var tabIndex: Int?
            var groupNumber = window.windowNumber
            if let tabGroup = window.tabGroup,
               tabGroup.windows.count > 1,
               let first = tabGroup.windows.first {
                groupNumber = first.windowNumber
                groupID = "group-\(groupNumber)"
                tabIndex = tabGroup.windows.firstIndex(of: window)
            }

            entries.append((
                group: groupNumber,
                tab: tabIndex ?? 0,
                number: window.windowNumber,
                snapshot: .init(
                    groupID: groupID,
                    tabIndex: tabIndex,
                    frame: .init(window.frame),
                    state: .init(from: controller))))
        }

        return entries
            .sorted { ($0.group, $0.tab, $0.number) < ($1.group, $1.tab, $1.number) }
            .map(\.snapshot)
    }

    // MARK: - Restoring

    /// Rebuild the windows from the last snapshot.
    ///
    /// Returns whether anything was restored, so the caller can fall back to
    /// opening a fresh window.
    @discardableResult
    func restore() -> Bool {
        guard isEnabled else { return false }
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return false }
        guard appDelegate.ghostty.app != nil else { return false }
        let ghostty = appDelegate.ghostty

        // Decoding creates live surfaces as a side effect, so this has to be
        // set before we read the file, not just before we build windows. It's
        // cleared explicitly at the end so the restored session can be tracked.
        isRestoring = true
        defer { isRestoring = false }

        guard let snapshot = loadSnapshot(), !snapshot.windows.isEmpty else { return false }

        var restored = false
        for group in snapshot.orderedGroups {
            var groupLeader: NSWindow?

            for window in group {
                guard let controller = restoreController(window, ghostty: ghostty) else { continue }
                guard let nsWindow = controller.window else { continue }
                restored = true

                if let groupLeader {
                    // AppKit sizes and places tabs from the group, so only the
                    // leader gets an explicit frame. Append to the end of the
                    // group so tabs keep the order they were saved in.
                    let target = groupLeader.tabGroup?.windows.last ?? groupLeader
                    target.addTabbedWindowSafely(nsWindow, ordered: .above)
                    controller.showWindowSafely(nil)
                } else {
                    controller.showWindowSafely(nil)
                    if let frame = window.frame.cgRect, Self.isOnScreen(frame) {
                        nsWindow.setFrame(frame, display: false)
                    }
                    groupLeader = nsWindow
                }

                applyRestoredState(window.state, to: controller, window: nsWindow)
            }
        }

        isRestoring = false

        // Deliberately no `NSApp.activate` here. Restoring is a consequence of
        // the app launching, and whoever launched it decides whether it should
        // come to the front; a background launch must stay in the background.
        if restored {
            // Start tracking again from here. Without this, a session that is
            // restored and then left alone never arms the periodic timer, so
            // the first thing that does change might not be captured.
            setNeedsSave()
        }

        return restored
    }

    private func restoreController(
        _ window: Snapshot.Window,
        ghostty: Ghostty.App
    ) -> TerminalController? {
        // Building the controller creates live surfaces as a side effect of
        // decoding, so a failure here can leave us with nothing to show.
        let controller = TerminalController(ghostty, withSurfaceTree: window.state.surfaceTree)
        guard controller.window != nil else {
            Self.logger.warning("restored controller has no window")
            return nil
        }
        return controller
    }

    private func applyRestoredState(
        _ state: TerminalRestorableState.InternalState<Ghostty.SurfaceView>,
        to controller: TerminalController,
        window: NSWindow
    ) {
        if let tabColor = state.tabColor {
            (window as? TerminalWindow)?.tabColor = tabColor
        }
        controller.titleOverride = state.titleOverride

        if let focused = state.focusedSurface,
           let view = controller.surfaceTree.first(where: { $0.id.uuidString == focused }) {
            controller.focusedSurface = view
            TerminalWindowRestoration.restoreFocus(to: view, inWindow: window)
        }

        // Native fullscreen is AppKit's to manage, and forcing it here fights
        // with its own restoration.
        if let mode = state.effectiveFullscreenMode, mode != .native {
            controller.toggleFullscreen(mode: mode)
        }
    }

    private func loadSnapshot() -> Snapshot? {
        guard let url = Self.snapshotURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version >= Snapshot.minimumVersion else {
                Self.logger.warning(
                    "ignoring session snapshot: version not supported: \(snapshot.version, privacy: .public)")
                return nil
            }
            return snapshot
        } catch {
            Self.logger.warning("failed to decode session snapshot: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    /// Restoration follows `window-save-state`, matching the AppKit path.
    private var isEnabled: Bool {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return false }
        return appDelegate.ghostty.config.windowSaveState != "never"
    }

    /// Whether a saved frame still lands somewhere the user can see. Monitors
    /// come and go, and a window restored onto a display that isn't there
    /// anymore is a window the user can't reach.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private static var snapshotURL: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("session-state.json", isDirectory: false)
    }
}

// MARK: - Snapshot

/// The on-disk form of a session.
///
/// Declared outside `TerminalSessionStore` so it doesn't pick up that type's
/// main-actor isolation: `Codable` requirements are nonisolated, and a nested
/// type would inherit the isolation and fight them.
extension TerminalSessionStore {
    typealias Snapshot = TerminalSessionSnapshot
}

struct TerminalSessionSnapshot: Codable {
    static let currentVersion = 1

    /// Oldest snapshot we know how to read. Bump alongside `currentVersion`
    /// when a change can't be understood by the code that reads it.
    static let minimumVersion = 1

    let version: Int
    let windows: [Window]

    enum CodingKeys: String, CodingKey {
        case version
        case windows
    }

    init(windows: [Window]) {
        self.version = Self.currentVersion
        self.windows = windows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        // One unreadable window shouldn't cost the user every other one,
        // so windows are decoded individually and failures dropped.
        self.windows = try container
            .decode([FailableWindow].self, forKey: .windows)
            .compactMap(\.value)
    }

    private struct FailableWindow: Decodable {
        let value: Window?

        init(from decoder: Decoder) throws {
            value = try? Window(from: decoder)
        }
    }

    /// Windows bucketed into tab groups, each group in tab order.
    ///
    /// Ungrouped windows are their own single-element group so callers can
    /// treat everything uniformly.
    var orderedGroups: [[Window]] {
        var groups: [String: [Window]] = [:]
        var order: [String] = []
        var standalone: [[Window]] = []

        for window in windows {
            guard let groupID = window.groupID else {
                standalone.append([window])
                continue
            }

            if groups[groupID] == nil { order.append(groupID) }
            groups[groupID, default: []].append(window)
        }

        let tabbed = order.map { id in
            groups[id, default: []].sorted { lhs, rhs in
                (lhs.tabIndex ?? .max) < (rhs.tabIndex ?? .max)
            }
        }

        return standalone + tabbed
    }

    struct Window: Codable {
        /// Shared by every window that was in the same tab group. Nil for
        /// a window that stood alone.
        let groupID: String?
        let tabIndex: Int?
        let frame: Frame
        let state: TerminalRestorableState.InternalState<Ghostty.SurfaceView>
    }

    /// A window frame. Stored as plain numbers rather than leaning on
    /// `CGRect`'s own encoding so the file stays readable and stable.
    struct Frame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: NSRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }

        /// Nil for a degenerate frame, which we'd rather ignore than
        /// restore a zero-sized window from.
        var cgRect: NSRect? {
            guard width > 0, height > 0 else { return nil }
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }
}
