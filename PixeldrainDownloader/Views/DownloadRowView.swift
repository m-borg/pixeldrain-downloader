import AppKit
import SwiftUI

struct DownloadRowView: View {
    let item: DownloadItem
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void

    @State private var showingLog = false

    private var fileIcon: NSImage {
        let ext = (item.filename as NSString).pathExtension
        if ext.isEmpty {
            return NSWorkspace.shared.icon(for: .data)
        }
        return NSWorkspace.shared.icon(forFileType: ext)
    }

    private var sizeSummary: String {
        if item.status == .completed, let total = item.totalBytes {
            return DownloadItem.formatBytes(total)
        }
        if let total = item.totalBytes, total > 0 {
            let pct = Int((item.progressFraction * 100).rounded())
            return "\(DownloadItem.formatBytes(item.downloadedBytes)) / \(DownloadItem.formatBytes(total)) (\(pct)%)"
        }
        if item.downloadedBytes > 0 {
            return DownloadItem.formatBytes(item.downloadedBytes)
        }
        return ""
    }

    private var progressTint: Color {
        switch item.status {
        case .completed:
            return .green
        case .switchingMirror, .paused:
            return .orange
        case .failed:
            return .red
        case .queued, .downloading:
            return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        if let source = item.activeSourceLabel, item.status.isActive {
                            let badgeColor: Color = item.isUsingBypassProxy ? .teal : .accentColor
                            Text(item.isUsingBypassProxy ? "bypass: \(source)" : source)
                                .font(.caption2.monospaced().weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(badgeColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(badgeColor)
                        }

                        Text(item.statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if !sizeSummary.isEmpty {
                    Text(sizeSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    if item.status.isActive {
                        Button(action: onPause) {
                            Image(systemName: "pause.fill")
                        }
                        .help("Pause download")
                    } else if item.status != .completed {
                        Button(action: onResume) {
                            Image(systemName: "play.fill")
                        }
                        .help("Resume download")
                    }

                    if FileManager.default.fileExists(atPath: item.destinationFileURL.path) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.destinationFileURL])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal in Finder")
                    }

                    Button {
                        showingLog.toggle()
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .help("View aria2c log")
                    .popover(isPresented: $showingLog, arrowEdge: .trailing) {
                        LogPopoverView(item: item)
                    }

                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                    }
                    .help(item.status.isActive ? "Cancel and remove" : "Remove from list")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if item.status != .completed {
                ProgressView(value: item.progressFraction)
                    .progressViewStyle(.linear)
                    .tint(progressTint)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return .green
        case .failed: return .red
        case .switchingMirror: return .orange
        default: return .secondary
        }
    }
}

private struct LogPopoverView: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Download Log")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    let text = item.logLines.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if item.logLines.isEmpty {
                            Text("Waiting for aria2c output...")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(item.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: item.logLines.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 460, height: 260)
    }
}
