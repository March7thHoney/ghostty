import SwiftUI

/// The git tab: one branch summary and grouped changed files per repository, read-only.
struct WorkspaceGitView: View {
    @ObservedObject var model: WorkspaceModel

    let dividerColor: Color

    /// How far the file rows sit inside a repository header when several repos are listed.
    private static let groupIndent: CGFloat = 10

    var body: some View {
        switch model.git {
        case .loading:
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .noRepos:
            message("Not a git repository")
        case .ready(let statuses):
            repoList(statuses)
        }
    }

    private func message(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func repoList(_ statuses: [RepoStatus]) -> some View {
        // A lone repository keeps the original single-repo layout, with no group chrome.
        let isSingle = statuses.count == 1

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(statuses.enumerated()), id: \.element.id) { offset, status in
                    if offset > 0 { divider }
                    repoHeader(status, isSingle: isSingle)
                    repoBody(status, isSingle: isSingle)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 1)
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
    }

    /// One repository's summary row: name, branch, tracking counts, and line totals.
    private func repoHeader(_ status: RepoStatus, isSingle: Bool) -> some View {
        let isCollapsed = model.collapsedRepos.contains(status.repo.root)
        let canCollapse = !isSingle && !status.isClean && status.snapshot != nil
        let snapshot = status.snapshot

        return Button {
            guard canCollapse else { return }
            model.toggleRepoCollapsed(status.repo.root)
        } label: {
            HStack(spacing: 6) {
                if !isSingle {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .opacity(canCollapse ? 1 : 0)
                        .frame(width: 10)

                    Text(status.repo.relativePath)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                        .help(status.repo.root)
                }

                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if let snapshot {
                    Text(snapshot.branch ?? "(detached)")
                        .font(.system(size: isSingle ? 12 : 11, weight: isSingle ? .semibold : .regular))
                        .foregroundStyle(isSingle ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(snapshot.upstream.map { "Upstream: \($0)" } ?? "No upstream")

                    if let ahead = snapshot.ahead, ahead > 0 {
                        Text("↑\(ahead)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let behind = snapshot.behind, behind > 0 {
                        Text("↓\(behind)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                trailingSummary(status, isSingle: isSingle)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The right edge of a header: line totals when there are changes, otherwise a clean marker.
    @ViewBuilder
    private func trailingSummary(_ status: RepoStatus, isSingle: Bool) -> some View {
        if let snapshot = status.snapshot, !snapshot.lineStats.isZero {
            HStack(spacing: 5) {
                Text("+\(snapshot.lineStats.added)")
                    .foregroundStyle(.green)
                Text("−\(snapshot.lineStats.removed)")
                    .foregroundStyle(.red)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .help("Lines added and removed against HEAD, untracked files excluded")
        } else if !isSingle, status.isClean {
            Text("clean")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func repoBody(_ status: RepoStatus, isSingle: Bool) -> some View {
        switch status.state {
        case .gitUnavailable(let reason):
            detail("Git is unavailable", reason: reason)
        case .failed(let reason):
            detail("git status failed", reason: reason)
        case .ready(let snapshot):
            // The lone-repo layout keeps its rule between the branch row and the file list.
            if isSingle { divider }

            if snapshot.isClean {
                if isSingle {
                    Text("No changes")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            } else if !model.collapsedRepos.contains(status.repo.root) {
                let indent = isSingle ? 0 : Self.groupIndent
                section(
                    "Staged", repo: status.repo, files: snapshot.stagedFiles,
                    section: .staged, indent: indent)
                section(
                    "Changes", repo: status.repo, files: snapshot.unstagedFiles,
                    section: .unstaged, indent: indent)
                section(
                    "Untracked", repo: status.repo, files: snapshot.untrackedFiles,
                    section: .untracked, indent: indent)
            }
        }
    }

    private func detail(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func section(
        _ title: String,
        repo: GitRepo,
        files: [GitFileStatus],
        section: GitDiffEntry.Section,
        indent: CGFloat
    ) -> some View {
        if !files.isEmpty {
            Text("\(title) (\(files.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4 + indent)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(files) { file in
                WorkspaceGitFileRow(
                    model: model, repoRoot: repo.root, file: file,
                    section: section, indent: indent)
            }
        }
    }
}

/// One changed-file row: name, dimmed parent directory, and a trailing status glyph.
private struct WorkspaceGitFileRow: View {
    @ObservedObject var model: WorkspaceModel
    let repoRoot: String
    let file: GitFileStatus
    let section: GitDiffEntry.Section
    let indent: CGFloat

    @State private var isHovering = false

    private var entry: GitDiffEntry {
        GitDiffEntry(
            repoRoot: repoRoot, section: section, path: file.path, origPath: file.origPath)
    }

    private var isSelected: Bool { model.selectedGitEntry == entry }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(isHovering ? 0.20 : 0.14) }
        return isHovering ? Color.primary.opacity(0.08) : Color.clear
    }

    /// The badge this row reports, taking the change from the section it sits in.
    private var badge: GitBadge? {
        if file.isUnmerged { return .conflicted }
        if file.isUntracked { return .untracked }
        switch section {
        case .staged: return file.staged.map(GitBadge.change)
        case .unstaged: return file.unstaged.map(GitBadge.change)
        case .untracked: return nil
        }
    }

    private var fileName: String { (file.path as NSString).lastPathComponent }

    private var parentDir: String {
        let dir = (file.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    var body: some View {
        Button {
            model.selectGitEntry(isSelected ? nil : entry)
        } label: {
            HStack(spacing: 6) {
                Text(fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if !parentDir.isEmpty {
                    Text(parentDir)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Text(badge?.glyph ?? "")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(badge.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
            }
            .padding(.leading, 10 + indent)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowFill))
        .onHover { isHovering = $0 }
        .help(file.origPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: entry.absolutePath)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.absolutePath, forType: .string)
            }
        }
    }
}
