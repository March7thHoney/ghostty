import SwiftUI

/// The git tab: branch summary plus grouped changed files, read-only.
struct WorkspaceGitView: View {
    @ObservedObject var model: WorkspaceModel

    let dividerColor: Color

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
        case .notARepo:
            message("Not a git repository")
        case .gitUnavailable(let reason):
            message("Git is unavailable", detail: reason)
        case .failed(let reason):
            message("git status failed", detail: reason)
        case .ready(let snapshot):
            statusList(snapshot)
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

    private func statusList(_ snapshot: GitStatusSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                branchRow(snapshot)

                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 1)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)

                if snapshot.isClean {
                    Text("No changes")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                } else {
                    section("Staged", files: snapshot.stagedFiles, section: .staged)
                    section("Changes", files: snapshot.unstagedFiles, section: .unstaged)
                    section("Untracked", files: snapshot.untrackedFiles, section: .untracked)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private func branchRow(_ snapshot: GitStatusSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(snapshot.branch ?? "(detached)")
                .font(.system(size: 12, weight: .semibold))
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

            Spacer(minLength: 4)

            if !snapshot.lineStats.isZero {
                HStack(spacing: 5) {
                    Text("+\(snapshot.lineStats.added)")
                        .foregroundStyle(.green)
                    Text("−\(snapshot.lineStats.removed)")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .help("Lines added and removed against HEAD, untracked files excluded")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func section(
        _ title: String,
        files: [GitFileStatus],
        section: GitDiffEntry.Section
    ) -> some View {
        if !files.isEmpty {
            Text("\(title) (\(files.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(files) { file in
                WorkspaceGitFileRow(model: model, file: file, section: section)
            }
        }
    }
}

/// One changed-file row: name, dimmed parent directory, and a trailing status glyph.
private struct WorkspaceGitFileRow: View {
    @ObservedObject var model: WorkspaceModel
    let file: GitFileStatus
    let section: GitDiffEntry.Section

    @State private var isHovering = false

    private var entry: GitDiffEntry {
        GitDiffEntry(section: section, path: file.path, origPath: file.origPath)
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
            .padding(.leading, 10)
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
                    [model.root.appendingPathComponent(file.path)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    model.root.appendingPathComponent(file.path).path, forType: .string)
            }
        }
    }
}
