import AppKit

/// The workspace panel's tabs: the file tree and the git status view.
enum WorkspacePanelTab: String {
    case files, git
}

/// App-wide panel chrome state; every window renders from it, so tabs look like one shared panel.
@MainActor
final class WorkspacePanelState: ObservableObject {
    static let shared = WorkspacePanelState()

    private static let visibleKey = "WorkspacePanelVisible"
    private static let tabKey = "WorkspacePanelTab"

    /// Whether the panel is expanded. Defaults to visible.
    @Published var isVisible: Bool {
        didSet { UserDefaults.ghostty.set(isVisible, forKey: Self.visibleKey) }
    }

    @Published var selectedTab: WorkspacePanelTab {
        didSet { UserDefaults.ghostty.set(selectedTab.rawValue, forKey: Self.tabKey) }
    }

    /// List-versus-preview fraction of the in-panel vertical split; session-only.
    @Published var previewSplit: CGFloat = 0.5

    private init() {
        isVisible = UserDefaults.ghostty.object(forKey: Self.visibleKey) as? Bool ?? true
        selectedTab = UserDefaults.ghostty.string(forKey: Self.tabKey)
            .flatMap(WorkspacePanelTab.init(rawValue:)) ?? .files
    }
}
