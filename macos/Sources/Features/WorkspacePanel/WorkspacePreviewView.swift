import SwiftUI

/// The bottom pane: a read-only file preview on the files tab, a read-only diff on the git tab.
struct WorkspacePreviewView: View {
    @ObservedObject var model: WorkspaceModel
    let tab: WorkspacePanelTab
    let dividerColor: Color

    private var title: String {
        switch tab {
        case .files:
            return ((model.selectedFilePath ?? "") as NSString).lastPathComponent
        case .git:
            return ((model.selectedGitEntry?.path ?? "") as NSString).lastPathComponent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            switch tab {
            case .files:
                filePreview
            case .git:
                diffPane(model.diff)
            }
        }
    }

    /// The files tab only offers the diff when the selected file actually has changes.
    private var hasFileChanges: Bool {
        guard tab == .files, let path = model.selectedFilePath else { return false }
        return model.gitIndex.badge(for: path) != nil
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if hasFileChanges {
                Button {
                    model.setPreviewMode(.content)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(WorkspacePanelIconButtonStyle(
                    size: 10, frame: 18, isActive: model.previewMode == .content))
                .help("Content")

                Button {
                    model.setPreviewMode(.changes)
                } label: {
                    Image(systemName: "plusminus")
                }
                .buttonStyle(WorkspacePanelIconButtonStyle(
                    size: 10, frame: 18, isActive: model.previewMode == .changes))
                .help("Changes")
            }

            Button {
                switch tab {
                case .files: model.selectFile(nil)
                case .git: model.selectGitEntry(nil)
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(WorkspacePanelIconButtonStyle(size: 9, frame: 18))
            .help("Close preview")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
    }

    // MARK: - File preview

    @ViewBuilder
    private var filePreview: some View {
        switch model.previewMode {
        case .content: fileContent
        case .changes: diffPane(model.fileDiff)
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        if let preview = model.filePreview {
            if preview.isBinary {
                centered("Binary file")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(preview.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if preview.truncated {
                        truncationNote
                    }
                }
            }
        } else {
            centered { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Diff

    @ViewBuilder
    private func diffPane(_ state: DiffState) -> some View {
        switch state {
        case .none:
            centered("")
        case .loading:
            centered { ProgressView().controlSize(.small) }
        case .failed(let reason):
            centered(reason)
        case .ready(let diff):
            if diff.isBinary {
                centered("Binary files differ")
            } else if diff.isEmpty {
                centered("No changes")
            } else {
                diffLines(diff)
            }
        }
    }

    /// One character's advance in the diff font, scaling columns to points.
    private static let diffCharWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    /// Gutters plus padding plus a safety margin on top of the estimated text width.
    private func diffContentWidth(_ diff: ParsedDiff) -> CGFloat {
        CGFloat(diff.maxColumns + 4) * Self.diffCharWidth + 60 + 12
    }

    private func diffLines(_ diff: ParsedDiff) -> some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        WorkspaceDiffLineRow(line: line)
                    }

                    if diff.truncated {
                        truncationNote
                    }
                }
                // Explicit width: a lazy stack only measures visible rows, so its own ideal drifts.
                .frame(
                    width: max(geo.size.width, diffContentWidth(diff)),
                    alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var truncationNote: some View {
        Text("Truncated")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(8)
    }

    private func centered(_ text: String) -> some View {
        centered {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 12)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One diff row: old/new line-number gutters plus the classified, tinted line text.
private struct WorkspaceDiffLineRow: View {
    let line: DiffLine

    private var rowBackground: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.14)
        case .deletion: return Color.red.opacity(0.14)
        case .hunkHeader: return Color.primary.opacity(0.05)
        case .context, .meta: return Color.clear
        }
    }

    private var textColor: AnyShapeStyle {
        switch line.kind {
        case .hunkHeader, .meta: return AnyShapeStyle(.secondary)
        case .addition, .deletion, .context: return AnyShapeStyle(.primary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if line.kind != .hunkHeader {
                gutter(line.oldLine)
                gutter(line.newLine)
            }

            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 6)

            Spacer(minLength: 0)
        }
        .background(rowBackground)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 30, alignment: .trailing)
    }
}
