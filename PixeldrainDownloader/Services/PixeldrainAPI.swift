import Foundation

enum PixeldrainAPI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    static func resolve(link: PixeldrainLink) async -> ResolvedPixeldrainPackage? {
        switch link.kind {
        case .file(let id):
            if let info = await fetchFileInfo(fileID: id, preferredHost: link.originHost) {
                let cleanName = sanitizeFilename(info.name)
                let entry = ResolvedPixeldrainEntry(
                    target: .file(id: id),
                    filename: cleanName,
                    size: info.size > 0 ? info.size : nil,
                    subfolder: nil
                )
                return ResolvedPixeldrainPackage(title: cleanName, entries: [entry], zipEntry: nil)
            }
            if let headerMeta = await probeFilenameFromHeaders(fileID: id) {
                let cleanName = sanitizeFilename(headerMeta.filename)
                let entry = ResolvedPixeldrainEntry(
                    target: .file(id: id),
                    filename: cleanName,
                    size: headerMeta.size,
                    subfolder: nil
                )
                return ResolvedPixeldrainPackage(title: cleanName, entries: [entry], zipEntry: nil)
            }
            return nil

        case .list(let id):
            return await resolveList(listID: id, preferredHost: link.originHost)

        case .directory(let id):
            return await resolveDirectory(dirID: id, preferredHost: link.originHost)
        }
    }

    /// Queries Pixeldrain metadata API for filename and size, falling back across mirrors.
    static func fetchFileInfo(fileID: String, preferredHost: String = "pixeldrain.com") async -> PixeldrainFileInfo? {
        let hosts = orderedHosts(preferred: preferredHost, includeCDN: true)
        for host in hosts {
            guard let url = URL(string: "https://\(host)/api/file/\(fileID)/info") else { continue }
            var request = URLRequest(url: url)
            request.setValue("PixeldrainDownloader/1.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }
                let info = try JSONDecoder().decode(PixeldrainFileInfo.self, from: data)
                if info.success != false, !info.name.isEmpty {
                    return info
                }
            } catch {
                continue
            }
        }
        return nil
    }

    static func probeFilenameFromHeaders(fileID: String) async -> (filename: String, size: Int64?)? {
        let proxies = await BypassProxyService.shared.loadProxies()
        var probeURLs: [URL] = proxies.prefix(2).compactMap {
            BypassProxyService.buildProxyURL(proxyBase: $0, target: .file(id: fileID))
        }
        if let cdn = URL(string: "https://cdn01.pixeldrain.eu.cc/api/file/\(fileID)") {
            probeURLs.append(cdn)
        }

        for url in probeURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.setValue("PixeldrainDownloader/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                    continue
                }
                if let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
                   let filename = parseContentDispositionFilename(disposition) {
                    let size = http.expectedContentLength > 0 ? http.expectedContentLength : nil
                    return (filename, size)
                }
            } catch {
                continue
            }
        }
        return nil
    }

    static func resolveList(listID: String, preferredHost: String = "pixeldrain.com") async -> ResolvedPixeldrainPackage? {
        let hosts = orderedHosts(preferred: preferredHost, includeCDN: false)

        // 1. Try Pixeldrain JSON API (/api/list/{id})
        for host in hosts {
            guard let url = URL(string: "https://\(host)/api/list/\(listID)") else { continue }
            var request = URLRequest(url: url)
            request.setValue("PixeldrainDownloader/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continue
                }
                if let pkg = parseListJSON(data: data, listID: listID) {
                    return pkg
                }
            } catch {
                continue
            }
        }

        // 2. Fallback: scrape /l/{id} HTML like the userscript
        for host in hosts {
            guard let url = URL(string: "https://\(host)/l/\(listID)") else { continue }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let html = String(data: data, encoding: .utf8) else {
                    continue
                }
                if let pkg = parseListHTML(html, listID: listID) {
                    return pkg
                }
            } catch {
                continue
            }
        }

        let fallbackTitle = listID
        let zipOnly = ResolvedPixeldrainEntry(
            target: .listZip(listID: listID),
            filename: "\(fallbackTitle).zip",
            size: nil,
            subfolder: nil
        )
        return ResolvedPixeldrainPackage(title: fallbackTitle, entries: [], zipEntry: zipOnly)
    }

    static func resolveDirectory(dirID: String, preferredHost: String = "pixeldrain.com") async -> ResolvedPixeldrainPackage? {
        let hosts = orderedHosts(preferred: preferredHost, includeCDN: false)
        for host in hosts {
            guard let url = URL(string: "https://\(host)/d/\(dirID)") else { continue }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let html = String(data: data, encoding: .utf8) else {
                    continue
                }
                if let pkg = parseDirectoryHTML(html, fallbackDirID: dirID) {
                    return pkg
                }
            } catch {
                continue
            }
        }

        let fallbackZip = ResolvedPixeldrainEntry(
            target: .directoryZip(dirID: dirID),
            filename: "\(dirID).zip",
            size: nil,
            subfolder: nil
        )
        return ResolvedPixeldrainPackage(title: dirID, entries: [], zipEntry: fallbackZip)
    }

    // MARK: - Pure Parsers (also unit-tested)

    struct ListAPIResponse: Decodable {
        let id: String?
        let title: String?
        let success: Bool?
        let files: [ListFile]?

        struct ListFile: Decodable {
            let id: String
            let name: String
            let size: Int64?
        }
    }

    static func parseListJSON(data: Data, listID: String) -> ResolvedPixeldrainPackage? {
        guard let decoded = try? JSONDecoder().decode(ListAPIResponse.self, from: data),
              decoded.success != false,
              let files = decoded.files, !files.isEmpty else {
            return nil
        }

        let title = sanitizeFilename((decoded.title?.isEmpty == false ? decoded.title! : listID))
        let entries = files.map { file in
            ResolvedPixeldrainEntry(
                target: .file(id: file.id),
                filename: sanitizeFilename(file.name),
                size: file.size,
                subfolder: files.count > 1 ? title : nil
            )
        }
        let zipEntry = ResolvedPixeldrainEntry(
            target: .listZip(listID: listID),
            filename: "\(title).zip",
            size: nil,
            subfolder: nil
        )
        return ResolvedPixeldrainPackage(title: title, entries: entries, zipEntry: zipEntry)
    }

    static func parseListHTML(_ html: String, listID: String) -> ResolvedPixeldrainPackage? {
        // Matches `<a ... class="...file..." ...><div style="...background-image: url('/api/file/<id>/thumbnail')..."></div>...Name...</a>`
        let anchorPattern = #"<a[^>]*class="[^"]*\bfile\b[^"]*"[^>]*>([\s\S]*?)</a>"#
        let idPattern = #"/api/file/([a-zA-Z0-9_-]+)/"#
        guard let anchorRegex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive]),
              let idRegex = try? NSRegularExpression(pattern: idPattern) else {
            return nil
        }

        let matches = anchorRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var entries: [ResolvedPixeldrainEntry] = []
        var seenIDs = Set<String>()

        for match in matches {
            guard let innerRange = Range(match.range(at: 1), in: html) else { continue }
            let inner = String(html[innerRange])
            guard let idMatch = idRegex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)),
                  let idRange = Range(idMatch.range(at: 1), in: inner) else {
                continue
            }
            let fileID = String(inner[idRange])
            guard seenIDs.insert(fileID).inserted else { continue }

            let strippedName = inner
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = strippedName.isEmpty ? fileID : sanitizeFilename(strippedName)
            entries.append(
                ResolvedPixeldrainEntry(
                    target: .file(id: fileID),
                    filename: name,
                    size: nil,
                    subfolder: listID
                )
            )
        }

        guard !entries.isEmpty else { return nil }
        let zipEntry = ResolvedPixeldrainEntry(
            target: .listZip(listID: listID),
            filename: "\(listID).zip",
            size: nil,
            subfolder: nil
        )
        return ResolvedPixeldrainPackage(title: listID, entries: entries, zipEntry: zipEntry)
    }

    struct InitialNode: Decodable {
        let path: [NodeItem]?
        let children: [NodeItem]?

        struct NodeItem: Decodable {
            let id: String?
            let name: String?
            let type: String?
            let size: Int64?
        }
    }

    static func parseDirectoryHTML(_ html: String, fallbackDirID: String) -> ResolvedPixeldrainPackage? {
        guard let jsonString = extractWindowInitialNodeJSON(from: html),
              let data = jsonString.data(using: .utf8),
              let node = try? JSONDecoder().decode(InitialNode.self, from: data) else {
            return nil
        }

        let resolvedDirID = node.path?.first?.id?.isEmpty == false ? node.path!.first!.id! : fallbackDirID
        let rawTitle = node.path?.last?.name ?? node.path?.first?.name ?? resolvedDirID
        let title = sanitizeFilename(rawTitle)

        // Single-file directory root (when path[0].type == "file" and children is empty)
        if let first = node.path?.first, first.type == "file", (node.children ?? []).isEmpty {
            let fileName = sanitizeFilename(first.name ?? title)
            let single = ResolvedPixeldrainEntry(
                target: .directorySingle(dirID: resolvedDirID),
                filename: fileName,
                size: first.size,
                subfolder: nil
            )
            return ResolvedPixeldrainPackage(title: fileName, entries: [single], zipEntry: nil)
        }

        let validFiles = (node.children ?? []).filter { item in
            item.type == "file" && !shouldIgnoreDirectoryFile(item.name)
        }

        if validFiles.count == 1, let only = validFiles.first {
            let fileName = sanitizeFilename(only.name ?? title)
            let single = ResolvedPixeldrainEntry(
                target: .directorySingle(dirID: resolvedDirID),
                filename: fileName,
                size: only.size,
                subfolder: nil
            )
            return ResolvedPixeldrainPackage(title: fileName, entries: [single], zipEntry: nil)
        }

        guard !validFiles.isEmpty else { return nil }

        let entries: [ResolvedPixeldrainEntry] = validFiles.compactMap { child in
            guard let rawName = child.name, !rawName.isEmpty else { return nil }
            let leafName = sanitizeFilename((rawName as NSString).lastPathComponent)
            return ResolvedPixeldrainEntry(
                target: .directoryFile(dirID: resolvedDirID, relativePath: rawName),
                filename: leafName,
                size: child.size,
                subfolder: title
            )
        }

        let zipEntry = ResolvedPixeldrainEntry(
            target: .directoryZip(dirID: resolvedDirID),
            filename: "\(title).zip",
            size: nil,
            subfolder: nil
        )
        return ResolvedPixeldrainPackage(title: title, entries: entries, zipEntry: zipEntry)
    }

    static func extractWindowInitialNodeJSON(from html: String) -> String? {
        guard let markerRange = html.range(of: "window.initial_node") else { return nil }
        guard let braceStart = html[markerRange.upperBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        var idx = braceStart
        while idx < html.endIndex {
            let ch = html[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(html[braceStart...idx])
                    }
                }
            }
            idx = html.index(after: idx)
        }
        return nil
    }

    static func shouldIgnoreDirectoryFile(_ filename: String?) -> Bool {
        guard let filename, !filename.isEmpty else { return false }
        return filename == ".search_index.gz" || filename.hasSuffix(".search_index.gz")
    }

    static func parseContentDispositionFilename(_ header: String) -> String? {
        // RFC 5987: filename*=UTF-8''example%20file.zip
        if let starRegex = try? NSRegularExpression(pattern: #"filename\*\s*=\s*(?:UTF-8''|utf-8'')([^;\r\n]+)"#),
           let match = starRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let range = Range(match.range(at: 1), in: header) {
            let raw = String(header[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return raw.removingPercentEncoding ?? raw
        }

        // Standard: filename="example file.zip" or filename=example.zip
        if let basicRegex = try? NSRegularExpression(pattern: #"filename\s*=\s*"?([^";\r\n]+)"?"#),
           let match = basicRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let range = Range(match.range(at: 1), in: header) {
            return String(header[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func sanitizeFilename(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        return cleaned.isEmpty ? "pixeldrain_download" : cleaned
    }

    private static func orderedHosts(preferred: String, includeCDN: Bool) -> [String] {
        var list = [preferred] + PixeldrainLink.supportedHosts
        if includeCDN {
            list.append("cdn01.pixeldrain.eu.cc")
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
