import Foundation
import Observation

enum DownloadStatus: Equatable {
    case queued
    case downloading
    case switchingMirror
    case paused
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .downloading, .switchingMirror:
            return true
        case .paused, .completed, .failed:
            return false
        }
    }
}

@Observable
@MainActor
final class DownloadItem: Identifiable {
    let id = UUID()
    let target: DownloadTargetKind
    let sourceURL: String
    var filename: String
    let destinationDirectory: URL
    let createdAt = Date()

    var status: DownloadStatus = .queued
    var activeSourceLabel: String?
    var isUsingBypassProxy: Bool = false
    var nextCandidateIndex: Int = 0
    var statusMessage: String = "Queued"
    var speedMBps: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64?
    var parsedPercent: Double = 0
    var etaText: String = ""
    var activeConnections: Int = 0
    var logLines: [String] = []

    var destinationFileURL: URL {
        destinationDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    var controlFileURL: URL {
        destinationDirectory.appendingPathComponent(filename + ".aria2", isDirectory: false)
    }

    var progressFraction: Double {
        if status == .completed { return 1.0 }
        if let total = totalBytes, total > 0 {
            return min(1.0, max(0.0, Double(downloadedBytes) / Double(total)))
        }
        return min(1.0, max(0.0, parsedPercent / 100.0))
    }

    init(
        target: DownloadTargetKind,
        sourceURL: String,
        filename: String,
        destinationDirectory: URL,
        totalBytes: Int64? = nil
    ) {
        self.target = target
        self.sourceURL = sourceURL
        self.filename = filename
        self.destinationDirectory = destinationDirectory
        self.totalBytes = totalBytes
    }

    func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}
