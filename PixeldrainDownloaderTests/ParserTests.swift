import XCTest
@testable import PixeldrainDownloader

final class ParserTests: XCTestCase {
    func testParsesStandardViewAndMirrorLinks() throws {
        let link = try PixeldrainLink.parse("https://pixeldrain.com/u/AbC123_xy").get()
        XCTAssertEqual(link.kind, .file(id: "AbC123_xy"))
        XCTAssertEqual(link.originHost, "pixeldrain.com")
        XCTAssertEqual(
            link.cdnMirrorURL(mirrorIndex: 7, fileID: "AbC123_xy").absoluteString,
            "https://cdn07.pixeldrain.eu.cc/api/file/AbC123_xy"
        )

        let netLink = try PixeldrainLink.parse("https://pixeldra.in/u/short99").get()
        XCTAssertEqual(netLink.kind, .file(id: "short99"))
        XCTAssertEqual(netLink.originHost, "pixeldra.in")
    }

    func testParsesListAndDirectoryLinks() throws {
        let listLink = try PixeldrainLink.parse("https://pixeldrain.net/l/album123").get()
        XCTAssertEqual(listLink.kind, .list(id: "album123"))
        XCTAssertEqual(listLink.originHost, "pixeldrain.net")

        let dirLink = try PixeldrainLink.parse("https://pixeldrain.dev/d/Dir_987").get()
        XCTAssertEqual(dirLink.kind, .directory(id: "Dir_987"))
        XCTAssertEqual(dirLink.originHost, "pixeldrain.dev")
    }

    func testParsesAPIFileLinkWithQuery() throws {
        let link = try PixeldrainLink.parse("  https://cdn12.pixeldrain.eu.cc/api/file/xyz-789?download  ").get()
        XCTAssertEqual(link.kind, .file(id: "xyz-789"))
        XCTAssertEqual(
            link.cdnMirrorURL(mirrorIndex: 48, fileID: "xyz-789").absoluteString,
            "https://cdn48.pixeldrain.eu.cc/api/file/xyz-789"
        )
    }

    func testRejectsInvalidAndEmptyLinks() {
        XCTAssertEqual(
            PixeldrainLink.parse("https://example.com/file.zip"),
            .failure(.invalidURL)
        )
        XCTAssertEqual(
            PixeldrainLink.parse("   "),
            .failure(.empty)
        )
    }

    func testClipboardCandidateDetection() {
        XCTAssertEqual(
            PixeldrainLink.parseClipboardCandidate("  https://pixeldrain.com/u/FGGjAT2C  ")?.fileID,
            "FGGjAT2C"
        )
        XCTAssertEqual(
            PixeldrainLink.parseClipboardCandidate("https://pixeldra.in/u/short99")?.fileID,
            "short99"
        )
        XCTAssertEqual(
            PixeldrainLink.parseClipboardCandidate("https://cdn03.pixeldrain.eu.cc/api/file/abc123")?.fileID,
            "abc123"
        )
        XCTAssertNil(PixeldrainLink.parseClipboardCandidate("https://reddit.com/u/someone"))
        XCTAssertNil(PixeldrainLink.parseClipboardCandidate("https://github.com/org/repo"))
        XCTAssertNil(PixeldrainLink.parseClipboardCandidate("just some text"))
    }

    func testParsesProxyJSONFormats() {
        let objData = #"{"proxies":["pd.cybar.to","https://mirror2.example.org/"]}"#.data(using: .utf8)!
        let objList = BypassProxyService.parseProxyJSON(data: objData)
        XCTAssertEqual(objList.map(\.absoluteString), [
            "https://pd.cybar.to/",
            "https://mirror2.example.org/",
        ])

        let singleData = #"{"proxy":"http://proxy.local:8080"}"#.data(using: .utf8)!
        XCTAssertEqual(
            BypassProxyService.parseProxyJSON(data: singleData).map(\.absoluteString),
            ["http://proxy.local:8080/"]
        )

        let arrData = #"["p1.example.com","p2.example.com/"]"#.data(using: .utf8)!
        XCTAssertEqual(
            BypassProxyService.parseProxyJSON(data: arrData).map(\.absoluteString),
            ["https://p1.example.com/", "https://p2.example.com/"]
        )
    }

    func testBuildsBypassURLsAndCDNFallbacks() {
        let proxy = URL(string: "https://pd.cybar.to/")!

        XCTAssertEqual(
            BypassProxyService.buildProxyURL(proxyBase: proxy, target: .file(id: "abc123"))?.absoluteString,
            "https://pd.cybar.to/abc123"
        )
        XCTAssertEqual(
            BypassProxyService.buildProxyURL(proxyBase: proxy, target: .directorySingle(dirID: "d1"))?.absoluteString,
            "https://pd.cybar.to/ds/d1"
        )
        XCTAssertEqual(
            BypassProxyService.buildProxyURL(
                proxyBase: proxy,
                target: .directoryFile(dirID: "d1", relativePath: "Season 1/Episode 01.mkv")
            )?.absoluteString,
            "https://pd.cybar.to/d/d1/Season%201/Episode%2001.mkv"
        )
        XCTAssertEqual(
            BypassProxyService.buildProxyURL(proxyBase: proxy, target: .listZip(listID: "l1"))?.absoluteString,
            "https://pd.cybar.to/zip/l1"
        )
        XCTAssertEqual(
            BypassProxyService.buildProxyURL(proxyBase: proxy, target: .directoryZip(dirID: "d1"))?.absoluteString,
            "https://pd.cybar.to/dzip/d1"
        )

        let candidates = BypassProxyService.candidateURLs(
            for: .file(id: "abc123"),
            proxies: [proxy],
            includeBypassProxies: true,
            maxCDNMirrors: 3
        )
        XCTAssertEqual(candidates.count, 4)
        XCTAssertTrue(candidates[0].isBypassProxy)
        XCTAssertEqual(candidates[0].url.absoluteString, "https://pd.cybar.to/abc123")
        XCTAssertFalse(candidates[1].isBypassProxy)
        XCTAssertEqual(candidates[1].label, "cdn01")
        XCTAssertEqual(candidates[3].label, "cdn03")
    }

    func testParsesDirectoryHTMLSingleFileIgnoringSearchIndex() throws {
        let html = """
        <html><body><script>
        window.initial_node = {"path":[{"id":"dirXYZ","name":"Game Pack","type":"dir"}],"children":[{"id":"f1","name":".search_index.gz","type":"file","size":123},{"id":"f2","name":"Awesome.Game.v1.0.zip","type":"file","size":4096}]};
        </script></body></html>
        """
        let pkg = try XCTUnwrap(PixeldrainAPI.parseDirectoryHTML(html, fallbackDirID: "dirXYZ"))
        XCTAssertEqual(pkg.entries.count, 1)
        XCTAssertEqual(pkg.entries[0].filename, "Awesome.Game.v1.0.zip")
        XCTAssertEqual(pkg.entries[0].size, 4096)
        XCTAssertEqual(pkg.entries[0].target, .directorySingle(dirID: "dirXYZ"))
    }

    func testParsesDirectoryHTMLMultiFile() throws {
        let html = """
        <html><body><script>
        window.initial_node = {"path":[{"id":"dirMulti","name":"Movies","type":"dir"}],"children":[{"id":"f1","name":"Part 1.mkv","type":"file","size":1000},{"id":"f2","name":"Part 2.mkv","type":"file","size":2000}]};
        </script></body></html>
        """
        let pkg = try XCTUnwrap(PixeldrainAPI.parseDirectoryHTML(html, fallbackDirID: "dirMulti"))
        XCTAssertEqual(pkg.entries.count, 2)
        XCTAssertEqual(pkg.entries[0].target, .directoryFile(dirID: "dirMulti", relativePath: "Part 1.mkv"))
        XCTAssertEqual(pkg.entries[0].filename, "Part 1.mkv")
        XCTAssertEqual(pkg.entries[0].subfolder, "Movies")
        XCTAssertEqual(pkg.zipEntry?.target, .directoryZip(dirID: "dirMulti"))
        XCTAssertEqual(pkg.zipEntry?.filename, "Movies.zip")
    }

    func testParsesListJSONAndContentDisposition() throws {
        let listJSON = """
        {"id":"lst1","title":"My Album","success":true,"files":[{"id":"idA","name":"track 1.flac","size":500},{"id":"idB","name":"track 2.flac","size":600}]}
        """.data(using: .utf8)!
        let pkg = try XCTUnwrap(PixeldrainAPI.parseListJSON(data: listJSON, listID: "lst1"))
        XCTAssertEqual(pkg.title, "My Album")
        XCTAssertEqual(pkg.entries.count, 2)
        XCTAssertEqual(pkg.entries[0].filename, "track 1.flac")
        XCTAssertEqual(pkg.entries[0].target, .file(id: "idA"))
        XCTAssertEqual(pkg.zipEntry?.filename, "My Album.zip")

        XCTAssertEqual(
            PixeldrainAPI.parseContentDispositionFilename(#"attachment; filename*=UTF-8''My%20Movie%20(2026).mkv"#),
            "My Movie (2026).mkv"
        )
        XCTAssertEqual(
            PixeldrainAPI.parseContentDispositionFilename(#"attachment; filename="archive.tar.gz""#),
            "archive.tar.gz"
        )
    }

    func testAria2SummaryParserMegabytes() throws {
        let line = "[#1a2b3c 12.5MiB/100MiB(12%) CN:8 DL:4.5MiB ETA:19s]"
        let sample = try XCTUnwrap(Aria2OutputParser.parseLine(line))
        XCTAssertEqual(sample.speedMBps ?? 0, 4.5, accuracy: 0.01)
        XCTAssertEqual(sample.connections, 8)
        XCTAssertEqual(sample.eta, "19s")
        XCTAssertEqual(sample.percent ?? 0, 12.0, accuracy: 0.01)
        XCTAssertEqual(sample.totalBytes, 100 * 1_048_576)
    }

    func testAria2SummaryParserKilobytesAndGigabytes() throws {
        let line = "[#deadbe 1.5GiB/2.0GiB(75%) CN:4 DL:512KiB ETA:12m]"
        let sample = try XCTUnwrap(Aria2OutputParser.parseLine(line))
        XCTAssertEqual(sample.speedMBps ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(sample.connections, 4)
        XCTAssertEqual(sample.eta, "12m")
        XCTAssertEqual(sample.percent ?? 0, 75.0, accuracy: 0.01)
    }

    func testFilenameSanitization() {
        XCTAssertEqual(PixeldrainAPI.sanitizeFilename("..hidden/movie:1.mkv "), "hidden_movie-1.mkv")
        XCTAssertEqual(PixeldrainAPI.sanitizeFilename("   "), "pixeldrain_download")
    }
}
