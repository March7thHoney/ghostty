import SwiftUI

/// The git tab's history mode: a lane graph of local commits, read-only like the rest of the panel.
struct WorkspaceGitHistoryView: View {
    @ObservedObject var model: WorkspaceModel

    let dividerColor: Color

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            content
        }
        // Entering the view is a reload point, because refs can move without HEAD moving.
        .task { model.activateHistory() }
        .onDisappear { model.deactivateHistory() }
    }

    // MARK: - Toolbar

    private var selectedRepo: GitHistoryRepo? {
        model.historyRepos.first { $0.root == model.historyRepoRoot }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if model.historyRepos.count > 1 {
                Menu {
                    ForEach(model.historyRepos) { repo in
                        Button(repoLabel(repo)) { model.selectHistoryRepo(repo.root) }
                    }
                } label: {
                    repoSummary
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                repoSummary
            }

            Spacer(minLength: 4)

            Button {
                model.reloadHistory()
            } label: {
                if model.historyLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(WorkspacePanelIconButtonStyle(size: 10, frame: 18))
            .disabled(model.historyLoading)
            .help("Reload history")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
    }

    private var repoSummary: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(selectedRepo.map(repoLabel) ?? "—")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func repoLabel(_ repo: GitHistoryRepo) -> String {
        guard let branch = repo.branch else { return repo.name }
        return "\(repo.name) · \(branch)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.history {
        case .idle:
            message("Not a git repository")
        case .loading:
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .noCommits:
            message("No commits yet")
        case .failed(let reason):
            message("Could not read history", detail: reason)
        case .ready(let page):
            commitList(page)
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

    private func commitList(_ page: GitHistoryPage) -> some View {
        // Sampled once per render so every row on screen agrees about what "now" is.
        let now = Date()

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(page.commits.enumerated()), id: \.element.sha) { index, commit in
                    WorkspaceCommitRow(
                        model: model, commit: commit,
                        row: index < page.graph.rows.count ? page.graph.rows[index] : nil,
                        laneCount: page.graph.laneCount, now: now)
                }

                if page.hasMore {
                    loadMoreRow(openLanes: page.graph.rows.last?.openLanes ?? [],
                                laneCount: page.graph.laneCount)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }

    /// A child-height row that keeps the lanes running through whatever it holds.
    private func childRow<Content: View>(
        openLanes: [Int],
        laneCount: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            WorkspaceGraphLaneStrip(lanes: openLanes, laneCount: laneCount)
            content()
                .padding(.leading, 6)
                .padding(.trailing, 8)
        }
        .frame(height: GitGraphStyle.childRowHeight)
    }

    private func loadMoreRow(openLanes: [Int], laneCount: Int) -> some View {
        childRow(openLanes: openLanes, laneCount: laneCount) {
            Button {
                model.loadMoreHistory()
            } label: {
                Text(model.historyLoading ? "Loading…" : "Load more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.historyLoading)

            Spacer(minLength: 0)
        }
    }
}

/// One commit: the graph gutter, ref badges, the subject, and a dimmed author-and-age line.
private struct WorkspaceCommitRow: View {
    @ObservedObject var model: WorkspaceModel

    let commit: GitCommit
    let row: GitGraphRow?
    let laneCount: Int
    let now: Date

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedCommitSha == commit.sha }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(isHovering ? 0.20 : 0.14) }
        return isHovering ? Color.primary.opacity(0.08) : Color.clear
    }

    private var visibleRefs: [GitRef] { GitLogParser.displayRefs(commit.refs) }

    private var hiddenRefCount: Int {
        GitLogParser.displayRefs(commit.refs, limit: .max).count - visibleRefs.count
    }

    var body: some View {
        Button {
            model.selectCommit(commit.sha)
        } label: {
            HStack(spacing: 0) {
                if let row {
                    WorkspaceGraphCanvas(
                        row: row, laneCount: laneCount,
                        isHead: commit.isHead, isMerge: commit.isMerge)
                }

                VStack(alignment: .leading, spacing: 2) {
                    subjectLine
                    metaLine
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
            }
            .frame(height: GitGraphStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowFill))
        .onHover { isHovering = $0 }
        .help("\(commit.shortSha)  \(commit.subject)")
        .contextMenu {
            Button("Copy Commit ID") { copy(commit.sha) }
            Button("Copy Short ID") { copy(commit.shortSha) }
            Button("Copy Commit Message") { copy(commit.body.isEmpty ? commit.subject : commit.body) }
        }
    }

    private var subjectLine: some View {
        HStack(spacing: 3) {
            ForEach(visibleRefs) { ref in
                WorkspaceRefBadge(ref: ref)
            }
            if hiddenRefCount > 0 {
                WorkspaceRefChip(text: "+\(hiddenRefCount)", isHead: false)
            }

            Text(commit.subject)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(commit.author)
                .lineLimit(1)
                .truncationMode(.tail)

            if let date = commit.date {
                Text("·")
                Text(RelativeTime.compact(date, now: now))
                    .fixedSize()
            }

            Spacer(minLength: 4)

            if let stats = commit.stats, !stats.isZero {
                Text("+\(stats.added)")
                    .foregroundStyle(.green)
                Text("−\(stats.removed)")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A branch, tag or remote label beside a commit subject.
struct WorkspaceRefBadge: View {
    let ref: GitRef

    private var icon: String {
        if case .tag = ref { return "tag" }
        return "arrow.triangle.branch"
    }

    var body: some View {
        WorkspaceRefChip(text: ref.label, isHead: ref.isHead, icon: icon)
    }
}

/// The chip shape both real refs and the overflow counter use.
struct WorkspaceRefChip: View {
    let text: String
    let isHead: Bool
    var icon: String?

    var body: some View {
        HStack(spacing: 2) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 7, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(isHead ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isHead ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08)))
        // Without this the chip competes with the subject for the row's width and loses badly.
        .fixedSize()
    }
}
