import Foundation

/// Turns `git config --get-regexp '^remote\..*\.url$'` output into the GitHub page for the checkout.
enum GitRemoteParser {
    struct Remote: Equatable {
        let name: String
        let url: String
    }

    /// Each line is `remote.<name>.url <url>`; order is the config's, which the fallback relies on.
    static func parseRemotes(_ data: Data) -> [Remote] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let key = line[..<space]
            let url = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard key.hasPrefix("remote."), key.hasSuffix(".url"), !url.isEmpty else { return nil }
            let name = key.dropFirst("remote.".count).dropLast(".url".count)
            guard !name.isEmpty else { return nil }
            return Remote(name: String(name), url: url)
        }
    }

    /// `origin` wins when it lives on GitHub; otherwise the first remote that does.
    static func githubWebURL(remotes: [Remote]) -> URL? {
        if let origin = remotes.first(where: { $0.name == "origin" }),
           let url = githubWebURL(from: origin.url) {
            return url
        }
        for remote in remotes {
            if let url = githubWebURL(from: remote.url) { return url }
        }
        return nil
    }

    /// The `https://github.com/owner/repo` page behind any of git's github.com address forms.
    static func githubWebURL(from remote: String) -> URL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (host, path) = splitHostAndPath(trimmed) else { return nil }
        guard host == "github.com" || host == "www.github.com" else { return nil }

        var segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        segments = Array(segments.prefix(2))
        if segments[1].lowercased().hasSuffix(".git") {
            segments[1] = String(segments[1].dropLast(".git".count))
        }
        guard !segments[0].isEmpty, !segments[1].isEmpty else { return nil }
        return URL(string: "https://github.com/\(segments[0])/\(segments[1])")
    }

    /// Handles `scheme://[user@]host[:port]/path` and the scp-like `[user@]host:path`.
    private static func splitHostAndPath(_ remote: String) -> (host: String, path: String)? {
        if let schemeEnd = remote.range(of: "://") {
            let rest = remote[schemeEnd.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[..<slash])
            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            if let colon = authority.firstIndex(of: ":") {
                authority = String(authority[..<colon])
            }
            return (authority.lowercased(), String(rest[rest.index(after: slash)...]))
        }

        // A colon before any slash marks the scp form; a leading slash would be a local path.
        guard let colon = remote.firstIndex(of: ":"), !remote.hasPrefix("/") else { return nil }
        let beforeColon = remote[..<colon]
        guard !beforeColon.contains("/") else { return nil }
        var host = String(beforeColon)
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        return (host.lowercased(), String(remote[remote.index(after: colon)...]))
    }
}
