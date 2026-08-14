import Foundation

/// Summary of one `~/.claude/projects/<dir>/<uuid>.jsonl` transcript, read without parsing all of it.
struct ClaudeTranscriptSummary: Equatable {
    /// The session ID, which is the transcript's filename stem.
    let sessionID: String

    /// The transcript file itself.
    let fileURL: URL

    /// Read from the records inside, never decoded from the directory name, whose mangling is lossy.
    let cwd: String

    /// Best title in the transcript; a live session's registry name is layered on at display time.
    let title: String?

    /// Last record's timestamp; mtime is unusable because Claude touches old transcripts at startup.
    let lastActivity: Date?
}

enum ClaudeTranscriptParser {
    /// Nil when the filename isn't a session UUID or no record names a working directory.
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

        // Title sources best first; ai-title is rewritten over a session's life and sits anywhere.
        let title = lastMatch(in: data, keyPattern: "\"aiTitle\"", where: { record in
            record["type"] as? String == "ai-title"
        }, extract: { $0["aiTitle"] as? String })
            ?? head.slug
            ?? lastMatch(in: data, keyPattern: "\"lastPrompt\"", where: { record in
                record["type"] as? String == "last-prompt"
            }, extract: { $0["lastPrompt"] as? String })
            ?? head.firstUserMessage

        // The literal last line can carry no timestamp, so take the last record that has one.
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

    /// Forward-scan caps; a file can open with records carrying none of the values we want.
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

    /// A user record's displayable text, skipping meta, sidechain, and command or system wrappers.
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

    /// Last validating record containing `keyPattern`; the byte search only locates candidate lines.
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

    /// Rows are one line, so collapse to the first line and bound the length.
    private static func cleanTitle(_ raw: String) -> String {
        let firstLine = raw
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        return String(firstLine.prefix(120))
    }
}
