import AppKit
import SwiftUI

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var downloadManager: DownloadManager?

    func applicationWillTerminate(_ notification: Notification) {
        downloadManager?.terminateAllActive()
    }
}

@main
struct PixeldrainDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var downloadManager = DownloadManager()

    var body: some Scene {
        Window("Pixeldrain Downloader", id: "main") {
            ContentView(settings: settings, downloadManager: downloadManager)
                .onAppear {
                    appDelegate.downloadManager = downloadManager
                }
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(settings: settings)
        }
    }
}
