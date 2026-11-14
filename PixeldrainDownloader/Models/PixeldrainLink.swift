import Foundation

enum PixeldrainLinkError: LocalizedError, Equatable {
    case empty
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste a Pixeldrain link to begin."
        case .invalidURL:
            return "Couldn't find a Pixeldrain link. Supported: /u/ID, /api/file/ID, /l/ID, or /d/ID."
        }
    }
}

enum PixeldrainLinkKind: Equatable, Sendable {
    case file(id: String)
    case list(id: String)
    case directory(id: String)

    var id: String {
        switch self {
        case .file(let id), .list(let id), .directory(let id):
            return id
        }
    }

    var typeLabel: String {
        switch self {
        case .file: return "File"
        case .list: return "Album / List"
        case .directory: return "Directory"
        }
    }
}

struct PixeldrainLink: Equatable, Sendable {
    let kind: PixeldrainLinkKind
    let originHost: String
    let originalURL: String

    var fileID: String { kind.id }

    static let supportedHosts: [String] = [
        "pixeldrain.com",
        "pixeldrain.net",
        "pixeldrain.dev",
        "pixeldra.in",
    ]

    /// Parses normal Pixeldrain links across pixeldrain.com/.net/.dev/pixeldra.in and CDN mirrors:
    /// - /u/<id>
    /// - /api/file/<id>
    /// - /l/<id>
    /// - /d/<id>
    static func parse(_ input: String) -> Result<PixeldrainLink, PixeldrainLinkError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.empty)
        }

        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let host = URL(string: normalized)?.host?.lowercased() ?? "pixeldrain.com"
        let originHost = supportedHosts.contains(host) ? host : "pixeldrain.com"

        let patterns: [(String, (String) -> PixeldrainLinkKind)] = [
            (#"/(?:api/file|u)/([a-zA-Z0-9_-]+)"#, { .file(id: $0) }),
            (#"/l/([a-zA-Z0-9_-]+)"#, { .list(id: $0) }),
            (#"/d/([a-zA-Z0-9_-]+)"#, { .directory(id: $0) }),
        ]

        for (pattern, builder) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               match.numberOfRanges >= 2,
               let idRange = Range(match.range(at: 1), in: trimmed) {
                let id = String(trimmed[idRange])
                return .success(PixeldrainLink(kind: builder(id), originHost: originHost, originalURL: trimmed))
            }
        }

        return .failure(.invalidURL)
    }

    /// Strict check used for automatic clipboard detection so non-Pixeldrain URLs (e.g. reddit.com/u/...) are ignored.
    static func parseClipboardCandidate(_ input: String) -> PixeldrainLink? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }

        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized),
              let host = url.host?.lowercased(),
              supportedHosts.contains(host) || host.hasSuffix(".pixeldrain.eu.cc") || host.contains("pixeldrain.") else {
            return nil
        }

        if case .success(let link) = parse(trimmed) {
            return link
        }
        return nil
    }

    func cdnMirrorURL(mirrorIndex: Int, fileID: String) -> URL {
        let clamped = max(1, min(48, mirrorIndex))
        let formatted = String(format: "https://cdn%02d.pixeldrain.eu.cc/api/file/%@", clamped, fileID)
        return URL(string: formatted)!
    }
}

enum DownloadTargetKind: Equatable, Sendable {
    case file(id: String)
    case directorySingle(dirID: String)
    case directoryFile(dirID: String, relativePath: String)
    case listZip(listID: String)
    case directoryZip(dirID: String)
}

struct DownloadCandidate: Equatable, Sendable {
    let url: URL
    let label: String
    let isBypassProxy: Bool
}

struct PixeldrainFileInfo: Decodable, Sendable {
    let id: String
    let name: String
    let size: Int64
    let mimeType: String?
    let success: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case size
        case mimeType = "mime_type"
        case success
    }
}

struct ResolvedPixeldrainEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let target: DownloadTargetKind
    let filename: String
    let size: Int64?
    let subfolder: String?
}

struct ResolvedPixeldrainPackage: Equatable, Sendable {
    let title: String
    let entries: [ResolvedPixeldrainEntry]
    let zipEntry: ResolvedPixeldrainEntry?
}
