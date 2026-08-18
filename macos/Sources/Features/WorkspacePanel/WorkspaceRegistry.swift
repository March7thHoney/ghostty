import Foundation

/// Maps working directories to shared per-root workspace models, so same-repo windows share one.
@MainActor
final class WorkspaceRegistry {
    static let shared = WorkspaceRegistry()

    /// Live models keyed by root path, bounded so abandoned roots stop their watchers.
    private var models: [String: WorkspaceModel] = [:]

    /// Root paths from least to most recently used.
    private var order: [String] = []

    /// Memoized pwd-to-root resolutions; only repo hits are cached so a later `git init` is seen.
    private var rootCache: [String: (root: String, isGitRepo: Bool)] = [:]

    private static let maxLiveModels = 4

    /// The shared model for the workspace containing pwd, created and started on first use.
    func model(forPwd pwd: String?) async -> WorkspaceModel? {
        guard let pwd, !pwd.isEmpty else { return nil }
        let normalized = Self.normalize(pwd)

        let resolved: (root: String, isGitRepo: Bool)
        if let cached = rootCache[normalized] {
            resolved = cached
        } else {
            // The walk stats every ancestor, which takes seconds on a network mount.
            resolved = await Task.detached(priority: .userInitiated) {
                Self.resolveRoot(forPwd: normalized)
            }.value
            if resolved.isGitRepo { rootCache[normalized] = resolved }
        }

        if let model = models[resolved.root] {
            touch(resolved.root)
            return model
        }

        let model = WorkspaceModel(
            root: URL(fileURLWithPath: resolved.root), isGitRepo: resolved.isGitRepo)
        models[resolved.root] = model
        touch(resolved.root)
        evictIfNeeded()
        // Started here so a model recreated after eviction never sits idle waiting for onAppear.
        model.start()
        return model
    }

    /// Walk pwd's ancestors for a `.git` entry; a file also counts, which covers worktrees.
    nonisolated static func resolveRoot(forPwd pwd: String) -> (root: String, isGitRepo: Bool) {
        var dir = URL(fileURLWithPath: pwd).standardizedFileURL
        while true {
            let gitPath = dir.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: gitPath) {
                return (dir.path, true)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return (Self.normalize(pwd), false) }
            dir = parent
        }
    }

    private func touch(_ root: String) {
        order.removeAll { $0 == root }
        order.append(root)
    }

    private func evictIfNeeded() {
        while order.count > Self.maxLiveModels {
            let evicted = order.removeFirst()
            models.removeValue(forKey: evicted)?.stop()
        }
    }

    nonisolated private static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
