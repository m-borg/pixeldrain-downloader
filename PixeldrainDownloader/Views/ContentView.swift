import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum MultiFileDownloadMode: String, CaseIterable, Identifiable {
    case individual = "Individual Files"
    case zip = "ZIP Archive"
    var id: String { rawValue }
}

struct ContentView: View {
    @Bindable var settings: AppSettings
    @Bindable var downloadManager: DownloadManager

    @State private var urlInput: String = ""
    @State private var filenameInput: String = ""
    @State private var userEditedFilename: Bool = false

    @State private var parsedLink: PixeldrainLink?
    @State private var parseError: String?
    @State private var isFetchingInfo: Bool = false
    @State private var resolvedPackage: ResolvedPixeldrainPackage?
    @State private var multiFileMode: MultiFileDownloadMode = .individual
    @State private var lookupTask: Task<Void, Never>?
    @State private var lastAutoPastedChangeCount: Int = -1

    @State private var aria2Available: Bool = Aria2Locator.locate() != nil

    private var isMultiFilePackage: Bool {
        guard let pkg = resolvedPackage else { return false }
        return pkg.entries.count > 1 || (pkg.entries.isEmpty && pkg.zipEntry != nil)
    }

    private var canStartDownload: Bool {
        guard parsedLink != nil, aria2Available else { return false }
        if isMultiFilePackage && multiFileMode == .individual {
            if let pkg = resolvedPackage, !pkg.entries.isEmpty {
                return true
            }
            return resolvedPackage?.zipEntry != nil
        }
        return !filenameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            inputCard
                .padding(16)

            Divider()

            downloadsList
        }
        .frame(minWidth: 540, minHeight: 480)
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openDownloadFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open download folder in Finder")

                if downloadManager.items.contains(where: { $0.status == .completed }) {
                    Button {
                        downloadManager.clearCompleted()
                    } label: {
                        Label("Clear Completed", systemImage: "trash")
                    }
                    .help("Remove completed downloads from list")
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .onAppear {
            aria2Available = Aria2Locator.locate() != nil
            autoPasteClipboardIfPixeldrainLink()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            autoPasteClipboardIfPixeldrainLink()
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !aria2Available {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("aria2c was not found. Install it with `brew install aria2` and reopen the app.")
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pixeldrain Link")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    linkStatusBadge
                }

                HStack(spacing: 6) {
                    TextField(
                        "Pixeldrain Link",
                        text: $urlInput,
                        prompt: Text(verbatim: "https://pixeldrain.com/u/..., /l/..., or /d/...")
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: urlInput) { _, newValue in
                        handleURLChange(newValue)
                    }
                    .onSubmit {
                        if canStartDownload { startDownload() }
                    }

                    if !urlInput.isEmpty {
                        Button {
                            resetComposer()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear link")
                    }

                    Button("Paste") {
                        pasteFromClipboard()
                    }
                }
            }

            if isMultiFilePackage, let pkg = resolvedPackage, !pkg.entries.isEmpty {
                HStack(spacing: 10) {
                    Picker("Mode", selection: $multiFileMode) {
                        ForEach(MultiFileDownloadMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: multiFileMode) { _, newMode in
                        if !userEditedFilename {
                            if newMode == .zip, let zipName = pkg.zipEntry?.filename {
                                filenameInput = zipName
                            } else {
                                filenameInput = pkg.title
                            }
                        }
                    }

                    Spacer()

                    Button {
                        startDownload()
                    } label: {
                        Label(
                            multiFileMode == .individual ? "Download All (\(pkg.entries.count))" : "Download ZIP",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartDownload)
                    .keyboardShortcut(.defaultAction)
                }

                if multiFileMode == .zip {
                    HStack(spacing: 8) {
                        Text("ZIP Name:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("archive.zip", text: Binding(
                            get: { filenameInput },
                            set: { newValue in
                                filenameInput = newValue
                                userEditedFilename = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output Filename")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        TextField("Auto-detected from Pixeldrain (or type manually)", text: Binding(
                            get: { filenameInput },
                            set: { newValue in
                                filenameInput = newValue
                                userEditedFilename = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if canStartDownload { startDownload() }
                        }
                    }

                    Button {
                        startDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartDownload)
                    .keyboardShortcut(.defaultAction)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("Save to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(settings.downloadDirectory.path.abbreviatingWithTilde)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if settings.useBypassProxies {
                    Text("Auto-Bypass")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.14), in: Capsule())
                        .foregroundStyle(.teal)
                }
                Button("Choose…") {
                    chooseFolder()
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var linkStatusBadge: some View {
        if let link = parsedLink {
            HStack(spacing: 5) {
                if isFetchingInfo {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Resolving \(link.kind.typeLabel.lowercased())…")
                        .font(.caption2)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                    Text("\(link.kind.typeLabel): \(link.fileID)")
                        .font(.caption2.monospaced())
                }

                if let pkg = resolvedPackage {
                    if pkg.entries.count > 1 {
                        let totalSize = pkg.entries.compactMap(\.size).reduce(0, +)
                        if totalSize > 0 {
                            Text("• \(pkg.entries.count) files (\(DownloadItem.formatBytes(totalSize)))")
                                .font(.caption2)
                        } else {
                            Text("• \(pkg.entries.count) files")
                                .font(.caption2)
                        }
                    } else if let size = pkg.entries.first?.size, size > 0 {
                        Text("• \(DownloadItem.formatBytes(size))")
                            .font(.caption2)
                    }
                }
            }
            .foregroundStyle(.secondary)
        } else if let parseError, !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(parseError)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var downloadsList: some View {
        if downloadManager.items.isEmpty {
            ContentUnavailableView {
                Label("No Downloads Yet", systemImage: "arrow.down.doc")
            } description: {
                Text("Paste any normal Pixeldrain link (/u/, /l/, or /d/) above.\nFilenames are resolved automatically and downloads route through bypass proxies with cdn01–cdn48 fallback.")
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(downloadManager.items) { item in
                        DownloadRowView(
                            item: item,
                            onPause: { downloadManager.pause(item) },
                            onResume: { downloadManager.resume(item, settings: settings) },
                            onRemove: { downloadManager.remove(item) }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private func handleURLChange(_ rawValue: String) {
        lookupTask?.cancel()
        resolvedPackage = nil

        switch PixeldrainLink.parse(rawValue) {
        case .success(let link):
            let changedLink = parsedLink != link
            parsedLink = link
            parseError = nil
            if changedLink {
                userEditedFilename = false
                multiFileMode = .individual
                fetchMetadata(for: link)
            }
        case .failure(let error):
            parsedLink = nil
            parseError = error == .empty ? nil : error.localizedDescription
            isFetchingInfo = false
        }
    }

    private func fetchMetadata(for link: PixeldrainLink) {
        isFetchingInfo = true
        let expectedLink = link
        let shouldPrewarmProxies = settings.useBypassProxies

        lookupTask = Task {
            if shouldPrewarmProxies {
                async let _ = BypassProxyService.shared.loadProxies()
            }
            let pkg = await PixeldrainAPI.resolve(link: expectedLink)
            guard !Task.isCancelled, parsedLink == expectedLink else { return }

            isFetchingInfo = false
            resolvedPackage = pkg

            if let pkg {
                if !userEditedFilename {
                    if pkg.entries.count == 1, let first = pkg.entries.first {
                        filenameInput = first.filename
                    } else if pkg.entries.isEmpty, let zip = pkg.zipEntry {
                        filenameInput = zip.filename
                    } else {
                        filenameInput = pkg.title
                    }
                }
            } else if filenameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                filenameInput = expectedLink.fileID
            }
        }
    }

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let str = pasteboard.string(forType: .string) else { return }
        lastAutoPastedChangeCount = pasteboard.changeCount
        urlInput = str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func autoPasteClipboardIfPixeldrainLink() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastAutoPastedChangeCount else { return }
        guard urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let str = pasteboard.string(forType: .string),
              let link = PixeldrainLink.parseClipboardCandidate(str) else {
            return
        }
        lastAutoPastedChangeCount = currentChangeCount
        urlInput = link.originalURL
    }

    private func startDownload() {
        guard let link = parsedLink else { return }

        if let pkg = resolvedPackage {
            if isMultiFilePackage {
                if multiFileMode == .individual && !pkg.entries.isEmpty {
                    downloadManager.startDownloads(
                        entries: pkg.entries,
                        sourceURL: link.originalURL,
                        baseDirectory: settings.downloadDirectory,
                        settings: settings
                    )
                    resetComposer()
                    return
                } else if let zip = pkg.zipEntry {
                    let chosenName = filenameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalName = chosenName.isEmpty ? zip.filename : chosenName
                    downloadManager.startDownload(
                        target: zip.target,
                        sourceURL: link.originalURL,
                        filename: finalName,
                        directory: settings.downloadDirectory,
                        knownSize: zip.size,
                        settings: settings
                    )
                    resetComposer()
                    return
                }
            } else if let single = pkg.entries.first {
                let chosenName = filenameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalName = chosenName.isEmpty ? single.filename : chosenName
                downloadManager.startDownload(
                    target: single.target,
                    sourceURL: link.originalURL,
                    filename: finalName,
                    directory: settings.downloadDirectory,
                    knownSize: single.size,
                    settings: settings
                )
                resetComposer()
                return
            }
        }

        // Fallback if metadata resolution hasn't completed yet
        let trimmedName = filenameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: DownloadTargetKind
        switch link.kind {
        case .file(let id): target = .file(id: id)
        case .list(let id): target = .listZip(listID: id)
        case .directory(let id): target = .directoryZip(dirID: id)
        }
        downloadManager.startDownload(
            target: target,
            sourceURL: link.originalURL,
            filename: trimmedName.isEmpty ? link.fileID : trimmedName,
            directory: settings.downloadDirectory,
            knownSize: nil,
            settings: settings
        )
        resetComposer()
    }

    private func resetComposer() {
        urlInput = ""
        filenameInput = ""
        userEditedFilename = false
        parsedLink = nil
        parseError = nil
        resolvedPackage = nil
        lookupTask?.cancel()
        isFetchingInfo = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.downloadDirectory
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadDirectory = url
        }
    }

    private func openDownloadFolder() {
        try? FileManager.default.createDirectory(
            at: settings.downloadDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(settings.downloadDirectory)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let resolvedURL: URL? = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let urlString = resolvedURL?.absoluteString else { return }
                    Task { @MainActor in
                        urlInput = urlString
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    Task { @MainActor in
                        urlInput = text
                    }
                }
                return true
            }
        }
        return false
    }
}
