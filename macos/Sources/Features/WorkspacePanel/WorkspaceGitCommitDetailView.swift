import SwiftUI

/// The bottom pane for a selected commit: everything the 320pt row had to leave out.
struct WorkspaceGitCommitDetailView: View {
    let commit: GitCommit

    /// Used when the stats pass produced nothing, so the count still comes from the loaded patch.
    let fallbackFileCount: Int?

    private var fileSummary: String? {
        guard let count = commit.filesChanged ?? fallbackFileCount else { return nil }
        return count == 1 ? "1 file changed" : "\(count) files changed"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(commit.subject)
                    .font(.system(size: 12, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !commit.trailingBody.isEmpty {
                    Text(commit.trailingBody)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    field("Commit", commit.sha, monospaced: true)
                    field("Author", "\(commit.author) <\(commit.authorEmail)>")
                    if let date = commit.date {
                        field("Date", RelativeTime.absolute(date))
                    }
                    if !commit.parents.isEmpty {
                        field(
                            commit.isMerge ? "Parents" : "Parent",
                            commit.parents.map { String($0.prefix(9)) }.joined(separator: ", "),
                            monospaced: true)
                    }
                    if let fileSummary {
                        field("Files", fileSummary)
                    }
                }
                .padding(.top, 2)

                if let stats = commit.stats, !stats.isZero {
                    HStack(spacing: 6) {
                        Text("+\(stats.added)")
                            .foregroundStyle(.green)
                        Text("−\(stats.removed)")
                            .foregroundStyle(.red)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                // A fixed gutter keeps the values in one column instead of a ragged left edge.
                .frame(width: 46, alignment: .leading)

            Text(value)
                .font(.system(size: 10, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
