import SwiftUI

/// The files tab: a lazily scanned, hand-rolled outline of the workspace root.
struct WorkspaceFileTreeView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        let rows = FileTreeScanner.flatten(
            rootDir: model.root.path,
            childrenByDir: model.childrenByDir,
            expanded: model.expandedDirs,
            denied: model.deniedDirs)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if rows.isEmpty {
                    Text("Empty directory")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }

                ForEach(rows) { row in
                    switch row.content {
                    case .node(let node):
                        WorkspaceFileTreeRow(model: model, node: node, depth: row.depth)
                    case .noAccess:
                        Text("No access")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(row.depth) * 12 + 26)
                            .padding(.vertical, 3)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }
}

/// One tree row: disclosure chevron for directories, icon, name, git badge, and selection/hover washes.
private struct WorkspaceFileTreeRow: View {
    @ObservedObject var model: WorkspaceModel
    let node: FileTreeNode
    let depth: Int

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedFilePath == node.path }
    private var isExpanded: Bool { model.expandedDirs.contains(node.path) }

    /// The file's own git state, or for a directory the strongest state among its descendants.
    private var badge: GitBadge? { model.gitIndex.badge(for: node.path) }

    /// Ignored rows stay readable but recede, the way VS Code dims them.
    private var isIgnored: Bool { model.ignoreIndex.isIgnored(node.path) }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(isHovering ? 0.20 : 0.14) }
        return isHovering ? Color.primary.opacity(0.08) : Color.clear
    }

    private var iconName: String {
        if node.isSymlink { return "link" }
        return node.isDirectory ? "folder" : "doc"
    }

    /// Files carry the status letter; directories carry a dot, so folded folders still read as changed.
    @ViewBuilder
    private var gitBadge: some View {
        if let badge {
            Group {
                if node.isDirectory {
                    Circle()
                        .fill(badge.color)
                        .frame(width: 6, height: 6)
                } else {
                    Text(badge.glyph)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(badge.color)
                }
            }
            .frame(width: 12)
        }
    }

    var body: some View {
        Button {
            if node.isDirectory {
                model.toggleExpanded(node.path)
            } else {
                model.selectFile(isSelected ? nil : node.path)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(node.isDirectory ? 1 : 0)
                    .frame(width: 10)

                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(badge.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                gitBadge
            }
            .padding(.leading, CGFloat(depth) * 12 + 6)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .opacity(isIgnored ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowFill))
        .onHover { isHovering = $0 }
        .nativeTooltip(node.path)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
        }
    }
}
