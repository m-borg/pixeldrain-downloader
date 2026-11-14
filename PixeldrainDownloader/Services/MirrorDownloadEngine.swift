import AppKit
import Foundation
import Observation

struct Aria2ProgressSample: Sendable {
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var percent: Double?
    var connections: Int?
    var speedMBps: Double?
    var eta: String?
}

enum Aria2OutputParser {
    static func parseLine(_ line: String) -> Aria2ProgressSample? {
        guard line.contains("DL:") || (line.contains("%)") && line.contains("/")) else {
            return nil
        }

        var sample = Aria2ProgressSample()

        if let speedMatch = firstMatch(
            in: line,
            pattern: #"DL:([0-9.,]+)(GiB|MiB|KiB|G|M|K|B)"#
        ) {
            let numberText = speedMatch[1].replacingOccurrences(of: ",", with: ".")
            let unit = speedMatch[2].uppercased()
            if let value = Double(numberText) {
                switch unit {
                case "G", "GIB":
                    sample.speedMBps = value * 1024.0
                case "M", "MIB":
                    sample.speedMBps = value
                case "K", "KIB":
                    sample.speedMBps = value / 1024.0
                case "B":
                    sample.speedMBps = value / 1_048_576.0
                default:
                    break
                }
            }
        }

        if let progressMatch = firstMatch(
            in: line,
            pattern: #"([0-9.,]+(?:GiB|MiB|KiB|B))/([0-9.,]+(?:GiB|MiB|KiB|B))\((\d+(?:\.\d+)?)%\)"#
        ) {
            sample.downloadedBytes = parseByteSize(progressMatch[1])
            sample.totalBytes = parseByteSize(progressMatch[2])
            sample.percent = Double(progressMatch[3])
        }

        if let cnMatch = firstMatch(in: line, pattern: #"CN:(\d+)"#),
           let cn = Int(cnMatch[1]) {
            sample.connections = cn
        }

        if let etaMatch = firstMatch(in: line, pattern: #"ETA:([0-9a-zA-Z]+)"#) {
            sample.eta = etaMatch[1]
        }

        return sample
    }

    static func parseByteSize(_ token: String) -> Int64? {
        guard let match = firstMatch(
            in: token,
            pattern: #"^([0-9.,]+)(GiB|MiB|KiB|B)$"#
        ) else {
            return nil
        }
        let numberText = match[1].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numberText) else { return nil }
        switch match[2].uppercased() {
        case "GIB": return Int64(value * 1_073_741_824.0)
        case "MIB": return Int64(value * 1_048_576.0)
        case "KIB": return Int64(value * 1024.0)
        case "B": return Int64(value)
        default: return nil
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (0..<match.numberOfRanges).compactMap { idx in
            guard let range = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[range])
        }
    }
}

private final class Aria2ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var _hasExited = false
    private var _exitCode: Int32 = -1
    private var _latestSpeedMBps: Double?
    private var _latestSpeedDate: Date?
    private var _stdoutBuffer = ""
    private var _stderrBuffer = ""
    private var _notFoundError = false

    private let onLine: @Sendable (String) -> Void
    private let onSample: @Sendable (Aria2ProgressSample) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(
        executableURL: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void,
        onSample: @escaping @Sendable (Aria2ProgressSample) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.onLine = onLine
        self.onSample = onSample
        self.onExit = onExit

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var hasExited: Bool {
        lock.withLock { _hasExited }
    }

    var exitCode: Int32 {
        lock.withLock { _exitCode }
    }

    var latestSpeed: (mbps: Double, date: Date)? {
        lock.withLock {
            guard let speed = _latestSpeedMBps, let date = _latestSpeedDate else { return nil }
            return (speed, date)
        }
    }

    var detectedNotFoundError: Bool {
        lock.withLock { _notFoundError }
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.flushBuffer(isStderr: false)
                return
            }
            self?.consume(data: data, isStderr: false)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.flushBuffer(isStderr: true)
                return
            }
            self?.consume(data: data, isStderr: true)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.flushBuffer(isStderr: false)
            self.flushBuffer(isStderr: true)

            let code = proc.terminationStatus
            self.lock.withLock {
                self._hasExited = true
                self._exitCode = code
            }
            self.onExit(code)
        }

        try process.run()
    }

    func terminate() {
        let shouldTerminate = lock.withLock { !_hasExited && process.isRunning }
        if shouldTerminate {
            process.terminate()
        }
    }

    func terminateAndWait(timeoutSeconds: TimeInterval) async {
        terminate()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !hasExited && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let stillRunning = lock.withLock { !_hasExited && process.isRunning }
        if stillRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func consume(data: Data, isStderr: Bool) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        let lines: [String] = lock.withLock {
            if isStderr {
                _stderrBuffer.append(chunk)
                return Self.extractLines(from: &_stderrBuffer)
            } else {
                _stdoutBuffer.append(chunk)
                return Self.extractLines(from: &_stdoutBuffer)
            }
        }
        processExtractedLines(lines)
    }

    private func flushBuffer(isStderr: Bool) {
        let remainder: String = lock.withLock {
            if isStderr {
                let s = _stderrBuffer
                _stderrBuffer = ""
                return s
            } else {
                let s = _stdoutBuffer
                _stdoutBuffer = ""
                return s
            }
        }
        let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            processExtractedLines([trimmed])
        }
    }

    private func processExtractedLines(_ lines: [String]) {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.localizedCaseInsensitiveContains("404 Not Found")
                || trimmed.localizedCaseInsensitiveContains("errorCode=22")
                || trimmed.localizedCaseInsensitiveContains("status=404") {
                lock.withLock { _notFoundError = true }
            }

            if let sample = Aria2OutputParser.parseLine(trimmed) {
                if let speed = sample.speedMBps {
                    lock.withLock {
                        _latestSpeedMBps = speed
                        _latestSpeedDate = Date()
                    }
                }
                onSample(sample)
            }
            onLine(trimmed)
        }
    }

    private static func extractLines(from buffer: inout String) -> [String] {
        var result: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<idx])
            let nextIdx = buffer.index(after: idx)
            buffer.removeSubrange(..<nextIdx)
            if !line.isEmpty {
                result.append(line)
            }
        }
        return result
    }
}

@Observable
@MainActor
final class DownloadManager {
    var items: [DownloadItem] = []

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeControllers: [UUID: Aria2ProcessController] = [:]

    func startDownload(
        target: DownloadTargetKind,
        sourceURL: String,
        filename: String,
        directory: URL,
        knownSize: Int64?,
        settings: AppSettings
    ) {
        let safeName = resolveUniqueFilenameIfNeeded(
            desiredName: PixeldrainAPI.sanitizeFilename(filename),
            in: directory
        )

        let item = DownloadItem(
            target: target,
            sourceURL: sourceURL,
            filename: safeName,
            destinationDirectory: directory,
            totalBytes: knownSize
        )
        items.insert(item, at: 0)
        launchTask(for: item, settings: settings)
    }

    func startDownloads(
        entries: [ResolvedPixeldrainEntry],
        sourceURL: String,
        baseDirectory: URL,
        settings: AppSettings
    ) {
        for entry in entries.reversed() {
            let targetDir: URL
            if let subfolder = entry.subfolder, !subfolder.isEmpty {
                targetDir = baseDirectory.appendingPathComponent(
                    PixeldrainAPI.sanitizeFilename(subfolder),
                    isDirectory: true
                )
            } else {
                targetDir = baseDirectory
            }

            startDownload(
                target: entry.target,
                sourceURL: sourceURL,
                filename: entry.filename,
                directory: targetDir,
                knownSize: entry.size,
                settings: settings
            )
        }
    }

    func pause(_ item: DownloadItem) {
        guard item.status.isActive else { return }
        activeTasks[item.id]?.cancel()
        activeTasks[item.id] = nil
        activeControllers[item.id]?.terminate()
        activeControllers[item.id] = nil
        item.status = .paused
        item.speedMBps = 0
        item.activeConnections = 0
        item.etaText = ""
        item.statusMessage = "Paused"
        item.appendLog("Paused by user.")
    }

    func resume(_ item: DownloadItem, settings: AppSettings) {
        guard !item.status.isActive, item.status != .completed else { return }
        item.status = .queued
        item.statusMessage = "Resuming..."
        launchTask(for: item, settings: settings)
    }

    func remove(_ item: DownloadItem) {
        activeTasks[item.id]?.cancel()
        activeTasks[item.id] = nil
        activeControllers[item.id]?.terminate()
        activeControllers[item.id] = nil
        items.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        items.removeAll { $0.status == .completed }
    }

    func terminateAllActive() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()

        for controller in activeControllers.values {
            controller.terminate()
        }
        activeControllers.removeAll()
    }

    private func resolveUniqueFilenameIfNeeded(desiredName: String, in directory: URL) -> String {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(desiredName)
        let control = directory.appendingPathComponent(desiredName + ".aria2")

        if fm.fileExists(atPath: control.path) {
            return desiredName
        }

        if !fm.fileExists(atPath: target.path) {
            return desiredName
        }

        let nsName = desiredName as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        for counter in 1...999 {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: candidateURL.path) {
                return candidate
            }
        }
        return "\(UUID().uuidString.prefix(6))-\(desiredName)"
    }

    private func launchTask(for item: DownloadItem, settings: AppSettings) {
        activeTasks[item.id]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDownloadLoop(item: item, settings: settings)
        }
        activeTasks[item.id] = task
    }

    private func runDownloadLoop(item: DownloadItem, settings: AppSettings) async {
        defer {
            activeTasks[item.id] = nil
            activeControllers[item.id] = nil
        }

        guard let aria2 = Aria2Locator.locate() else {
            item.status = .failed("aria2c not found")
            item.statusMessage = "aria2c binary missing. Install aria2 via Homebrew (`brew install aria2`)."
            item.appendLog("Error: could not locate aria2c executable.")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: item.destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            item.status = .failed("Folder error")
            item.statusMessage = "Could not create folder: \(error.localizedDescription)"
            return
        }

        // If user hit Download before metadata resolved (filename is still just the raw ID), resolve proper filename now.
        if case .file(let id) = item.target, item.filename == id {
            item.statusMessage = "Resolving filename..."
            if let info = await PixeldrainAPI.fetchFileInfo(fileID: id) {
                item.filename = resolveUniqueFilenameIfNeeded(
                    desiredName: PixeldrainAPI.sanitizeFilename(info.name),
                    in: item.destinationDirectory
                )
                if info.size > 0 { item.totalBytes = info.size }
            } else if let headerMeta = await PixeldrainAPI.probeFilenameFromHeaders(fileID: id) {
                item.filename = resolveUniqueFilenameIfNeeded(
                    desiredName: PixeldrainAPI.sanitizeFilename(headerMeta.filename),
                    in: item.destinationDirectory
                )
                if let sz = headerMeta.size { item.totalBytes = sz }
            }
        }

        let proxies = settings.useBypassProxies
            ? await BypassProxyService.shared.loadProxies()
            : []

        let candidates = BypassProxyService.candidateURLs(
            for: item.target,
            proxies: proxies,
            includeBypassProxies: settings.useBypassProxies,
            maxCDNMirrors: settings.maxMirrors
        )

        guard !candidates.isEmpty else {
            item.status = .failed("No bypass proxy available")
            item.statusMessage = "Could not load bypass proxy list from pixeldrain-bypass.cybar.to."
            item.appendLog("No bypass proxies available for this link type.")
            return
        }

        var candidateIndex = item.nextCandidateIndex % candidates.count
        var consecutiveFastFailures = 0
        var notFoundCount = 0

        while !Task.isCancelled {
            if isDownloadComplete(for: item) {
                markCompleted(item: item, settings: settings)
                return
            }

            let candidate = candidates[candidateIndex]
            candidateIndex = (candidateIndex + 1) % candidates.count
            item.nextCandidateIndex = candidateIndex

            item.activeSourceLabel = candidate.label
            item.isUsingBypassProxy = candidate.isBypassProxy
            item.status = .downloading
            item.speedMBps = 0
            item.activeConnections = 0
            item.etaText = ""
            item.statusMessage = "Connecting to \(candidate.label)..."

            item.appendLog(">>> \(candidate.label) (\(candidate.url.absoluteString))")

            let conn = max(1, min(16, settings.connectionsPerMirror))
            let args = [
                "-x\(conn)",
                "-s\(conn)",
                "-k1M",
                "--stream-piece-selector=inorder",
                "--file-allocation=trunc",
                "--continue=true",
                "--auto-file-renaming=false",
                "--console-log-level=error",
                "--summary-interval=2",
                "-d", item.destinationDirectory.path,
                "-o", item.filename,
                candidate.url.absoluteString,
            ]

            let controller = Aria2ProcessController(
                executableURL: aria2.url,
                arguments: args,
                onLine: { [weak item] line in
                    Task { @MainActor in
                        item?.appendLog(line)
                    }
                },
                onSample: { [weak item] sample in
                    Task { @MainActor in
                        guard let item, item.status.isActive else { return }
                        if let dl = sample.downloadedBytes {
                            item.downloadedBytes = max(item.downloadedBytes, dl)
                        }
                        if let total = sample.totalBytes, total > 0 {
                            item.totalBytes = total
                        }
                        if let pct = sample.percent {
                            item.parsedPercent = max(item.parsedPercent, pct)
                        }
                        if let cn = sample.connections {
                            item.activeConnections = cn
                        }
                        if let speed = sample.speedMBps {
                            item.speedMBps = speed
                        }
                        if let eta = sample.eta {
                            item.etaText = eta
                        }
                    }
                },
                onExit: { _ in }
            )

            activeControllers[item.id] = controller

            do {
                try controller.start()
            } catch {
                item.status = .failed("Launch error")
                item.statusMessage = "Failed to start aria2c: \(error.localizedDescription)"
                item.appendLog("Failed to launch aria2c: \(error.localizedDescription)")
                return
            }

            let mirrorStart = Date()
            let warmupDuration = TimeInterval(max(5, settings.warmupSeconds))
            let checkInterval = TimeInterval(max(2, settings.checkIntervalSeconds))

            // Warm-up phase
            while !Task.isCancelled && !controller.hasExited {
                let elapsed = Date().timeIntervalSince(mirrorStart)
                if elapsed >= warmupDuration {
                    break
                }

                updateLiveStatusMessage(
                    for: item,
                    sourceLabel: candidate.label,
                    remainingWarmup: Int(ceil(warmupDuration - elapsed))
                )
                try? await Task.sleep(for: .milliseconds(500))
            }

            if Task.isCancelled {
                await controller.terminateAndWait(timeoutSeconds: 2.0)
                return
            }

            if controller.hasExited {
                if controller.exitCode == 0 && isDownloadComplete(for: item) {
                    markCompleted(item: item, settings: settings)
                    return
                }
                if controller.detectedNotFoundError {
                    notFoundCount += 1
                    if notFoundCount >= 3 {
                        item.status = .failed("File not found")
                        item.statusMessage = "Pixeldrain returned 404 Not Found for this file."
                        item.appendLog("Stopping: multiple sources returned 404 Not Found.")
                        return
                    }
                }
                consecutiveFastFailures += 1
                item.appendLog("Source \(candidate.label) exited (code \(controller.exitCode)) — switching.")
                if consecutiveFastFailures >= candidates.count {
                    item.status = .failed("All sources failed")
                    item.statusMessage = "All bypass proxies and CDN mirrors failed to respond."
                    return
                }
                item.status = .switchingMirror
                item.statusMessage = "Source unavailable — switching..."
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            consecutiveFastFailures = 0

            // Speed monitor loop
            while !Task.isCancelled && !controller.hasExited {
                let stepDeadline = Date().addingTimeInterval(checkInterval)
                while !Task.isCancelled && !controller.hasExited && Date() < stepDeadline {
                    updateLiveStatusMessage(for: item, sourceLabel: candidate.label, remainingWarmup: nil)
                    try? await Task.sleep(for: .milliseconds(500))
                }

                if Task.isCancelled {
                    await controller.terminateAndWait(timeoutSeconds: 2.0)
                    return
                }

                if controller.hasExited {
                    break
                }

                let minSpeed = settings.minimumSpeedMBps
                if let latest = controller.latestSpeed {
                    let isStale = Date().timeIntervalSince(latest.date) > (checkInterval + 10)
                    if isStale || latest.mbps < minSpeed {
                        let reason = isStale
                            ? "Source stalled — switching"
                            : String(format: "Slow (%.1f MB/s < %.1f MB/s) — switching", latest.mbps, minSpeed)
                        item.appendLog(reason)
                        item.status = .switchingMirror
                        item.statusMessage = reason
                        await controller.terminateAndWait(timeoutSeconds: 3.0)
                        break
                    }
                } else if Date().timeIntervalSince(mirrorStart) > warmupDuration + checkInterval {
                    item.appendLog("No throughput reported — switching source")
                    item.status = .switchingMirror
                    item.statusMessage = "No throughput — switching..."
                    await controller.terminateAndWait(timeoutSeconds: 3.0)
                    break
                }
            }

            if controller.hasExited && controller.exitCode == 0 && isDownloadComplete(for: item) {
                markCompleted(item: item, settings: settings)
                return
            }
        }
    }

    private func updateLiveStatusMessage(for item: DownloadItem, sourceLabel: String, remainingWarmup: Int?) {
        if item.speedMBps > 0 {
            let speedStr = String(format: "%.1f MB/s", item.speedMBps)
            if let remainingWarmup, remainingWarmup > 0 {
                item.statusMessage = "\(sourceLabel) • \(speedStr) (checking in \(remainingWarmup)s)"
            } else if !item.etaText.isEmpty {
                item.statusMessage = "\(sourceLabel) • \(speedStr) • ETA \(item.etaText)"
            } else {
                item.statusMessage = "\(sourceLabel) • \(speedStr)"
            }
        } else if let remainingWarmup, remainingWarmup > 0 {
            item.statusMessage = "Warming up \(sourceLabel) (\(remainingWarmup)s)..."
        } else {
            item.statusMessage = "Downloading via \(sourceLabel)..."
        }
    }

    private func isDownloadComplete(for item: DownloadItem) -> Bool {
        let fm = FileManager.default
        let controlExists = fm.fileExists(atPath: item.controlFileURL.path)
        guard !controlExists else { return false }

        guard let attrs = try? fm.attributesOfItem(atPath: item.destinationFileURL.path),
              let fileSize = attrs[.size] as? NSNumber else {
            return false
        }
        return fileSize.int64Value > 0
    }

    private func markCompleted(item: DownloadItem, settings: AppSettings) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: item.destinationFileURL.path),
           let fileSize = attrs[.size] as? NSNumber {
            let bytes = fileSize.int64Value
            item.downloadedBytes = bytes
            if item.totalBytes == nil || item.totalBytes == 0 {
                item.totalBytes = bytes
            }
        }
        item.parsedPercent = 100
        item.speedMBps = 0
        item.activeConnections = 0
        item.etaText = ""
        item.status = .completed
        item.statusMessage = "Completed"
        item.appendLog("DONE — \(item.destinationFileURL.path)")

        if settings.playCompletionSound {
            NSSound(named: "Glass")?.play()
        }
    }
}
