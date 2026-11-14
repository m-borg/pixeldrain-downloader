import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var aria2Status: String = "Checking..."
    @State private var proxyStatus: String = "Checking..."
    @State private var isRefreshingProxies: Bool = false

    var body: some View {
        Form {
            Section("Destination") {
                LabeledContent("Default Folder") {
                    HStack(spacing: 8) {
                        Text(settings.downloadDirectory.path.abbreviatingWithTilde)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            chooseFolder()
                        }
                    }
                }

                Toggle("Play sound when download finishes", isOn: $settings.playCompletionSound)
            }

            Section("Bypass Proxies") {
                Toggle("Automatically use bypass proxies (pixeldrain-bypass.cybar.to)", isOn: $settings.useBypassProxies)

                LabeledContent("Cached Proxies") {
                    HStack(spacing: 8) {
                        Text(proxyStatus)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button(isRefreshingProxies ? "Refreshing…" : "Refresh") {
                            Task {
                                isRefreshingProxies = true
                                let list = await BypassProxyService.shared.loadProxies(forceRefresh: true)
                                proxyStatus = list.isEmpty ? "Unavailable (will use CDN mirrors)" : "\(list.count) proxies"
                                isRefreshingProxies = false
                            }
                        }
                        .disabled(isRefreshingProxies)
                    }
                }
            }

            Section("Mirror Cycling (cdn01 – cdn48)") {
                HStack {
                    Text("Minimum Speed Threshold")
                    Spacer()
                    Stepper(
                        value: $settings.minimumSpeedMBps,
                        in: 0.5...25.0,
                        step: 0.5
                    ) {
                        Text(String(format: "%.1f MB/s", settings.minimumSpeedMBps))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }

                HStack {
                    Text("Warm-up Before Switching")
                    Spacer()
                    Stepper(
                        value: $settings.warmupSeconds,
                        in: 5...60,
                        step: 5
                    ) {
                        Text("\(settings.warmupSeconds)s")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }

                HStack {
                    Text("Speed Check Interval")
                    Spacer()
                    Stepper(
                        value: $settings.checkIntervalSeconds,
                        in: 3...20,
                        step: 1
                    ) {
                        Text("\(settings.checkIntervalSeconds)s")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }

                HStack {
                    Text("Connections per Mirror")
                    Spacer()
                    Stepper(
                        value: $settings.connectionsPerMirror,
                        in: 1...16,
                        step: 1
                    ) {
                        Text("\(settings.connectionsPerMirror)")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }

            Section("Engine") {
                LabeledContent("aria2c") {
                    Text(aria2Status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if let bin = Aria2Locator.locate() {
                let source = bin.isBundled ? "Bundled" : "System"
                let ver = Aria2Locator.versionString(for: bin.url) ?? "aria2c"
                aria2Status = "\(source) (\(ver))"
            } else {
                aria2Status = "Not found — install via `brew install aria2`"
            }

            let proxies = await BypassProxyService.shared.cachedProxies()
            proxyStatus = proxies.isEmpty ? "Not cached yet" : "\(proxies.count) proxies"
        }
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
}

extension String {
    var abbreviatingWithTilde: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}
