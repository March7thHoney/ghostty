import AppKit
import Combine

/// The tab strip's view of one window's tab group, rebuilt from AppKit state on every relevant event.
@MainActor
final class TabStripModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let isSelected: Bool
        let tabColor: TerminalTabColor
        let claudeActivity: ClaudeLiveSession.Activity?
        let keyEquivalent: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isZoomed = false

    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?

    init(window: NSWindow?) {
        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: TerminalWindow.tabStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let changed = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard self.isSameGroup(changed) else { return }
                self.refresh()
            }
        }
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The windows this strip lists, in tab order; a lone window still gets one tab.
    private var windows: [NSWindow] {
        guard let window else { return [] }
        return window.tabGroup?.windows ?? [window]
    }

    private func isSameGroup(_ other: NSWindow) -> Bool {
        guard let window else { return false }
        if other === window { return true }
        guard let group = window.tabGroup else { return false }
        return group.windows.contains(other)
    }

    private func terminalWindow(for id: Item.ID) -> TerminalWindow? {
        windows.first { ObjectIdentifier($0) == id } as? TerminalWindow
    }

    private func controller(for id: Item.ID) -> TerminalController? {
        terminalWindow(for: id)?.terminalController
    }

    /// Rebuilds the items; publishing only on change keeps AppKit round trips from re-rendering the strip.
    func refresh() {
        guard let window else { return }
        let selected = window.tabGroup?.selectedWindow ?? window
        let next = windows.map { w -> Item in
            let terminal = w as? TerminalWindow
            return Item(
                id: ObjectIdentifier(w),
                title: w.title,
                isSelected: w === selected,
                tabColor: terminal?.tabColor ?? .none,
                claudeActivity: terminal?.claudeActivity,
                keyEquivalent: terminal?.keyEquivalent.flatMap { $0.isEmpty ? nil : $0 })
        }
        if next != items { items = next }
        let zoomed = (selected as? TerminalWindow)?.surfaceIsZoomed ?? false
        if zoomed != isZoomed { isZoomed = zoomed }
    }

    // MARK: Actions

    func select(_ id: Item.ID) {
        guard let target = terminalWindow(for: id) else { return }
        if let group = window?.tabGroup, group.selectedWindow !== target {
            group.selectedWindow = target
        }
        target.makeKeyAndOrderFront(nil)
    }

    func close(_ id: Item.ID) {
        controller(for: id)?.closeTab(nil)
    }

    func closeOthers(_ id: Item.ID) {
        controller(for: id)?.closeOtherTabs(nil)
    }

    func closeToTheRight(_ id: Item.ID) {
        controller(for: id)?.closeTabsOnTheRight(nil)
    }

    func newTab() {
        (window as? TerminalWindow)?.terminalController?.newTab(nil)
    }

    func rename(_ id: Item.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        controller(for: id)?.titleOverride = trimmed.isEmpty ? nil : trimmed
    }

    func currentTitle(_ id: Item.ID) -> String {
        guard let controller = controller(for: id) else { return "" }
        return controller.titleOverride ?? controller.window?.title ?? ""
    }

    func setColor(_ id: Item.ID, _ color: TerminalTabColor) {
        terminalWindow(for: id)?.tabColor = color
    }

    func moveToNewWindow(_ id: Item.ID) {
        terminalWindow(for: id)?.moveTabToNewWindow(nil)
    }

    func resetZoom() {
        guard let selected = window?.tabGroup?.selectedWindow ?? window,
              let controller = (selected as? TerminalWindow)?.terminalController else { return }
        controller.splitZoom(controller)
    }

    /// Reorders a tab by removing it from the group and re-adding it beside the tab now at `index`.
    func move(_ id: Item.ID, to index: Int) {
        guard let group = window?.tabGroup,
              let moving = terminalWindow(for: id),
              let from = group.windows.firstIndex(of: moving) else { return }
        let reordered = Self.reorder(group.windows, moving: from, to: index)
        guard reordered != group.windows, let to = reordered.firstIndex(of: moving) else { return }
        let ordered: NSWindow.OrderingMode = to < from ? .below : .above
        let neighbor = group.windows[to < from ? to : to]

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        group.removeWindow(moving)
        neighbor.addTabbedWindowSafely(moving, ordered: ordered)
        moving.makeKey()
        NSAnimationContext.endGrouping()
        refresh()
    }

    /// Pure reorder helper: moves the element at `from` so it lands at `to` in the result.
    nonisolated static func reorder<T>(_ items: [T], moving from: Int, to: Int) -> [T] {
        guard items.indices.contains(from) else { return items }
        let clamped = min(max(to, 0), items.count - 1)
        guard clamped != from else { return items }
        var result = items
        let element = result.remove(at: from)
        result.insert(element, at: clamped)
        return result
    }
}
