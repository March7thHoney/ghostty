import Foundation

/// Summary of one Claude Code transcript file, extracted without parsing the
/// whole file. Transcripts live at `~/.claude/projects/<dir>/<uuid>.jsonl`
/// where `<dir>` is the working directory with every non-alphanumeric
/// character replaced by "-". That mangling is lossy ("/a/b_c" and "/a/b-c"
/// collide), so the working directory is always read from the records inside
/// the file, never decoded from the directory name.
struct ClaudeTranscriptSummary: Equatable {
    /// The session ID, which is the transcript's filename stem.
    let sessionID: String

    /// The transcript file itself.
    let fileURL: URL

    /// The working directory the session ran in, from the records inside the
    /// file. `claude --resume` looks sessions up per directory, so resuming
    /// must happen here.
    let cwd: String

    /// Best available title. Live sessions may have a fresher name in the
    /// session registry; that is layered on at display time, not here.
    let title: String?

    /// Timestamp of the last record that carries one. File mtime is not
    /// usable for this: Claude Code touches old transcripts at startup,
    /// skewing mtimes by up to days.
    let lastActivity: Date?
}

enum ClaudeTranscriptParser {
    /// Parse a transcript file. Returns nil when the filename is not a
    /// session UUID or no record in the file names a working directory.
    static func parse(fileURL: URL) -> ClaudeTranscriptSummary? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: stem) != nil else { return nil }
        // Transcripts reach 8MB+; mapping keeps the head/tail scans cheap.
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return parse(data: data, sessionID: stem, fileURL: fileURL)
    }

    /// The parse itself, split from file access so tests can feed it fixtures.
    static func parse(data: Data, sessionID: String, fileURL: URL) -> ClaudeTranscriptSummary? {
        let head = scanHead(data)
        guard let cwd = head.cwd else { return nil }

        // The title sources, best first. ai-title records are rewritten over
        // the session's life and can sit anywhere in the file, so they are
        // found by searching backward for the last one rather than scanning
        // every line.
        let title = lastMatch(in: data, keyPattern: "\"aiTitle\"", where: { record in
            record["type"] as? String == "ai-title"
        }, extract: { $0["aiTitle"] as? String })
            ?? head.slug
            ?? lastMatch(in: data, keyPattern: "\"lastPrompt\"", where: { record in
                record["type"] as? String == "last-prompt"
            }, extract: { $0["lastPrompt"] as? String })
            ?? head.firstUserMessage

        // The literal last line can be a record with no timestamp (e.g.
        // last-prompt), so take the last record that has one.
        let lastActivity = lastMatch(in: data, keyPattern: "\"timestamp\"", where: { _ in true }) {
            ($0["timestamp"] as? String).flatMap(parseTimestamp)
        }

        return .init(
            sessionID: sessionID,
            fileURL: fileURL,
            cwd: cwd,
            title: title.map(cleanTitle),
            lastActivity: lastActivity)
    }

    // MARK: - Head scan

    private struct Head {
        var cwd: String?
        var slug: String?
        var firstUserMessage: String?
    }

    /// Caps on the forward scan. The values a head scan wants are normally in
    /// the first handful of records, but the file can open with records that
    /// carry none of them (queue operations), so we keep going a while.
    private static let headMaxLines = 100
    private static let headMaxBytes = 256 * 1024

    private static func scanHead(_ data: Data) -> Head {
        var head = Head()
        var lineStart = data.startIndex
        var linesSeen = 0

        while lineStart < data.endIndex,
              linesSeen < headMaxLines,
              lineStart - data.startIndex < headMaxBytes,
              head.cwd == nil || head.slug == nil || head.firstUserMessage == nil {
            let lineEnd = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            defer {
                lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
                linesSeen += 1
            }

            guard lineEnd > lineStart,
                  let record = try? JSONSerialization.jsonObject(
                    with: data[lineStart..<lineEnd]) as? [String: Any]
            else { continue }

            if head.cwd == nil, let cwd = record["cwd"] as? String, !cwd.isEmpty {
                head.cwd = cwd
            }
            if head.slug == nil, let slug = record["slug"] as? String, !slug.isEmpty {
                head.slug = slug
            }
            if head.firstUserMessage == nil, let text = userMessageText(record) {
                head.firstUserMessage = text
            }
        }

        return head
    }

    /// The displayable text of a user record, or nil for records that make
    /// poor titles: meta records, sidechain (subagent) records, and slash
    /// command or system wrappers.
    private static func userMessageText(_ record: [String: Any]) -> String? {
        guard record["type"] as? String == "user",
              record["isMeta"] as? Bool != true,
              record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any]
        else { return nil }

        let text: String?
        switch message["content"] {
        case let string as String:
            text = string
        case let blocks as [[String: Any]]:
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        default:
            text = nil
        }

        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("<command-name>"),
              !trimmed.hasPrefix("<local-command"),
              !trimmed.hasPrefix("<system-reminder>")
        else { return nil }
        return trimmed
    }

    // MARK: - Backward search

    /// Find the last record in the file containing `keyPattern` that both
    /// satisfies `where` and yields a value from `extract`. The byte search
    /// only locates candidate lines; values always come from parsing the
    /// full line as JSON, so a pattern that merely appears inside some
    /// message's text fails validation and the search continues backward.
    private static func lastMatch<T>(
        in data: Data,
        keyPattern: String,
        where validate: ([String: Any]) -> Bool,
        extract: ([String: Any]) -> T?
    ) -> T? {
        let pattern = Data(keyPattern.utf8)
        var searchRange = data.startIndex..<data.endIndex

        while let found = data.range(of: pattern, options: .backwards, in: searchRange) {
            let lineStart = data[data.startIndex..<found.lowerBound]
                .lastIndex(of: UInt8(ascii: "\n"))
                .map { data.index(after: $0) } ?? data.startIndex
            let lineEnd = data[found.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex

            if let record = try? JSONSerialization.jsonObject(
                with: data[lineStart..<lineEnd]) as? [String: Any],
               validate(record),
               let value = extract(record) {
                return value
            }

            guard lineStart > data.startIndex else { return nil }
            searchRange = data.startIndex..<data.index(before: lineStart)
        }

        return nil
    }

    // MARK: - Values

    /// Record timestamps are ISO8601, usually with fractional seconds.
    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter = ISO8601DateFormatter()

    /// Titles render on a single sidebar row; collapse to the first line and
    /// bound the length so a pasted wall of text can't be one.
    private static func cleanTitle(_ raw: String) -> String {
        let firstLine = raw
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        return String(firstLine.prefix(120))
    }
}
