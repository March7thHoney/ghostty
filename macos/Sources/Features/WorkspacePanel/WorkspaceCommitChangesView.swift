import SwiftUI

/// A commit's whole patch as one scroll: a collapsible section per file, VS Code's multi-diff shape.
struct WorkspaceCommitChangesView: View {
    let diff: ParsedDiff

    /// The repository the paths are relative to, so a row can name a file absolutely.
    let repoRoot: String

    let dividerColor: Color

    /// Reset with the commit, because a path collapsed in one commit means nothing in the next.
    @State private var collapsed: Set<String> = []

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.files) { file in
                        section(file)
                    }

                    if diff.truncated {
                        Text("Truncated")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                // Explicit width: a lazy stack only measures visible rows, so its own ideal drifts.
                .frame(
                    width: max(geo.size.width, WorkspaceDiffMetrics.contentWidth(diff)),
                    alignment: .leading)
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func section(_ file: ParsedDiffFile) -> some View {
        // A section git gave no header for has no name to show, so it renders as bare lines.
        if !file.path.isEmpty {
            WorkspaceCommitFileHeader(
            file: file,
            repoRoot: repoRoot,
            isCollapsed: collapsed.contains(file.path),
            dividerColor: dividerColor) {
                if collapsed.contains(file.path) {
                    collapsed.remove(file.path)
                } else {
                    collapsed.insert(file.path)
                }
            }
        }

        if !collapsed.contains(file.path) {
            if file.isBinary {
                note("Binary file")
            } else if file.lines.isEmpty {
                // A pure rename carries no hunks at all, which is information rather than an error.
                note(file.change == .renamed ? "Renamed without changes" : "No changes")
            } else {
                ForEach(file.lines) { line in
                    WorkspaceDiffLineRow(line: line)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.vertical, 4)
    }
}

/// One file's header bar inside the multi-file diff.
private struct WorkspaceCommitFileHeader: View {
    let file: ParsedDiffFile
    let repoRoot: String
    let isCollapsed: Bool
    let dividerColor: Color
    let onToggle: () -> Void

    @State private var isHovering = false

    private var fileName: String { (file.path as NSString).lastPathComponent }

    private var parentDir: String { (file.path as NSString).deletingLastPathComponent }

    private var badge: GitBadge? { file.change.map(GitBadge.change) }

    private var absolutePath: String { (repoRoot as NSString).appendingPathComponent(file.path) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 10)

                    Text(fileName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .layoutPriority(1)

                    if !parentDir.isEmpty {
                        Text(parentDir)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if let badge {
                        Text(badge.glyph)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(badge.color)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color.primary.opacity(isHovering ? 0.10 : 0.06))
        .onHover { isHovering = $0 }
        .nativeTooltip(absolutePath)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(absolutePath, forType: .string)
            }
        }
    }
}
