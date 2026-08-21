import SwiftUI

/// The bottom pane: a read-only file preview on the files tab, a read-only diff on the git tab.
struct WorkspacePreviewView: View {
    @ObservedObject var model: WorkspaceModel
    let tab: WorkspacePanelTab

    /// Which half of the git tab is showing, since the two feed the pane different things.
    let gitMode: WorkspaceGitMode

    let dividerColor: Color

    private var title: String {
        switch tab {
        case .files:
            return ((model.selectedFilePath ?? "") as NSString).lastPathComponent
        case .git:
            switch gitMode {
            case .changes:
                return ((model.selectedGitEntry?.path ?? "") as NSString).lastPathComponent
            case .history:
                return model.selectedCommitSha.map { String($0.prefix(9)) } ?? ""
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            switch (tab, gitMode) {
            case (.files, _):
                filePreview
            case (.git, .changes):
                diffPane(model.diff)
            case (.git, .history):
                historyPreview
            }
        }
    }

    /// The files tab only offers the diff when the selected file actually has changes.
    private var hasFileChanges: Bool {
        guard tab == .files, let path = model.selectedFilePath else { return false }
        return model.gitIndex.badge(for: path) != nil
    }

    /// A whole commit can be read as metadata or as a diff; one file inside it can only be a diff.
    private var hasCommitModes: Bool {
        guard tab == .git, gitMode == .history else { return false }
        return model.selectedCommitSha != nil
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

            if hasCommitModes {
                Button {
                    model.setCommitPreviewMode(.details)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(WorkspacePanelIconButtonStyle(
                    size: 10, frame: 18, isActive: model.commitPreviewMode == .details))
                .help("Details")

                Button {
                    model.setCommitPreviewMode(.changes)
                } label: {
                    Image(systemName: "plusminus")
                }
                .buttonStyle(WorkspacePanelIconButtonStyle(
                    size: 10, frame: 18, isActive: model.commitPreviewMode == .changes))
                .help("Changes")
            }

            Button {
                switch (tab, gitMode) {
                case (.files, _): model.selectFile(nil)
                case (.git, .changes): model.selectGitEntry(nil)
                case (.git, .history): model.clearHistorySelection()
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

    // MARK: - History

    @ViewBuilder
    private var historyPreview: some View {
        if let sha = model.selectedCommitSha {
            switch model.commitPreviewMode {
            case .details: commitDetails(sha)
            case .changes: commitChanges
            }
        } else {
            centered("")
        }
    }

    @ViewBuilder
    private func commitDetails(_ sha: String) -> some View {
        if let commit = loadedCommit(sha) {
            WorkspaceGitCommitDetailView(commit: commit, fallbackFileCount: loadedDiffFileCount)
        } else {
            centered("Commit is no longer loaded")
        }
    }

    /// Stands in when the stats pass never landed, which happens on repositories too slow for it.
    private var loadedDiffFileCount: Int? {
        guard case .ready(let diff) = model.commitDiff, !diff.files.isEmpty else { return nil }
        return diff.files.count
    }

    /// The whole commit as one scroll of per-file sections, rather than a single flat diff.
    @ViewBuilder
    private var commitChanges: some View {
        switch model.commitDiff {
        case .none:
            centered("")
        case .loading:
            centered { ProgressView().controlSize(.small) }
        case .failed(let reason):
            centered(reason)
        case .ready(let diff):
            if diff.files.isEmpty {
                centered("No changes")
            } else {
                WorkspaceCommitChangesView(diff: diff, dividerColor: dividerColor)
                    // Collapsed sections are per-commit state, so a new commit gets a fresh view.
                    .id(model.selectedCommitSha ?? "")
            }
        }
    }

    private func loadedCommit(_ sha: String) -> GitCommit? {
        guard case .ready(let page) = model.history else { return nil }
        return page.commits.first { $0.sha == sha }
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
                    width: max(geo.size.width, WorkspaceDiffMetrics.contentWidth(diff)),
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

/// Sizing shared by the single-file diff pane and the multi-file commit view.
enum WorkspaceDiffMetrics {
    /// One character's advance in the diff font, scaling columns to points.
    static let charWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    /// Gutters plus padding plus a safety margin on top of the estimated text width.
    static func contentWidth(_ diff: ParsedDiff) -> CGFloat {
        CGFloat(diff.maxColumns + 4) * charWidth + 60 + 12
    }
}

/// One diff row: old/new line-number gutters plus the classified, tinted line text.
struct WorkspaceDiffLineRow: View {
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
