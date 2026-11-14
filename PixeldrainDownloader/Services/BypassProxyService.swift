import Foundation

actor BypassProxyService {
    static let shared = BypassProxyService()

    static let proxyJSONURL = URL(string: "https://pixeldrain-bypass.cybar.to/api/proxy.json")!
    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheListKey = "pd_proxy_list_v3"
    private static let cacheTimestampKey = "pd_proxy_list_ts_v3"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func cachedProxies() -> [URL] {
        let raw = UserDefaults.standard.stringArray(forKey: Self.cacheListKey) ?? []
        return raw.compactMap { URL(string: $0) }
    }

    func loadProxies(forceRefresh: Bool = false) async -> [URL] {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let cachedTs = defaults.double(forKey: Self.cacheTimestampKey)
        let cached = cachedProxies()

        if !forceRefresh, !cached.isEmpty, (now - cachedTs) < Self.cacheTTL {
            return cached
        }

        do {
            var request = URLRequest(url: Self.proxyJSONURL)
            request.setValue("PixeldrainDownloader/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return cached
            }

            let parsed = Self.parseProxyJSON(data: data)
            if !parsed.isEmpty {
                defaults.set(parsed.map(\.absoluteString), forKey: Self.cacheListKey)
                defaults.set(now, forKey: Self.cacheTimestampKey)
                return parsed
            }
            return cached
        } catch {
            return cached
        }
    }

    static func parseProxyJSON(data: Data) -> [URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        var rawEntries: [String] = []
        if let dict = object as? [String: Any] {
            if let list = dict["proxies"] as? [String] {
                rawEntries = list
            } else if let single = dict["proxy"] as? String {
                rawEntries = [single]
            }
        } else if let list = object as? [String] {
            rawEntries = list
        }

        var seen = Set<String>()
        var result: [URL] = []
        for entry in rawEntries {
            if let normalized = normalizeProxyEntry(entry), seen.insert(normalized.absoluteString).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    static func normalizeProxyEntry(_ entry: String) -> URL? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        if trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }

        let withSlash = withScheme.hasSuffix("/") ? withScheme : "\(withScheme)/"
        return URL(string: withSlash)
    }

    static func buildProxyURL(proxyBase: URL, target: DownloadTargetKind) -> URL? {
        let baseString = proxyBase.absoluteString.hasSuffix("/")
            ? proxyBase.absoluteString
            : proxyBase.absoluteString + "/"

        switch target {
        case .file(let id):
            return URL(string: "\(baseString)\(id)")
        case .directorySingle(let dirID):
            return URL(string: "\(baseString)ds/\(dirID)")
        case .directoryFile(let dirID, let relativePath):
            let encoded = encodePathPreservingSlashes(relativePath)
            return URL(string: "\(baseString)d/\(dirID)/\(encoded)")
        case .listZip(let listID):
            return URL(string: "\(baseString)zip/\(listID)")
        case .directoryZip(let dirID):
            return URL(string: "\(baseString)dzip/\(dirID)")
        }
    }

    /// Encodes each path segment like JS `encodeURIComponent(name).replace(/%2F/g, '/')`.
    static func encodePathPreservingSlashes(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    static func candidateURLs(
        for target: DownloadTargetKind,
        proxies: [URL],
        includeBypassProxies: Bool,
        maxCDNMirrors: Int
    ) -> [DownloadCandidate] {
        var candidates: [DownloadCandidate] = []

        if includeBypassProxies && !proxies.isEmpty {
            let shuffledProxies = proxies.shuffled()
            for proxy in shuffledProxies {
                if let url = buildProxyURL(proxyBase: proxy, target: target) {
                    let host = proxy.host ?? "bypass"
                    candidates.append(DownloadCandidate(url: url, label: host, isBypassProxy: true))
                }
            }
        }

        if case .file(let id) = target {
            for index in 1...max(1, maxCDNMirrors) {
                let formatted = String(format: "https://cdn%02d.pixeldrain.eu.cc/api/file/%@", index, id)
                if let url = URL(string: formatted) {
                    let label = String(format: "cdn%02d", index)
                    candidates.append(DownloadCandidate(url: url, label: label, isBypassProxy: false))
                }
            }
        }

        return candidates
    }
}
