import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    private enum Keys {
        static let downloadDirectory = "downloadDirectoryPath"
        static let minimumSpeedMBps = "minimumSpeedMBps"
        static let warmupSeconds = "warmupSeconds"
        static let checkIntervalSeconds = "checkIntervalSeconds"
        static let connectionsPerMirror = "connectionsPerMirror"
        static let playCompletionSound = "playCompletionSound"
        static let useBypassProxies = "useBypassProxies"
    }

    static var defaultDownloadDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    var downloadDirectory: URL {
        didSet {
            UserDefaults.standard.set(downloadDirectory.path, forKey: Keys.downloadDirectory)
        }
    }

    var minimumSpeedMBps: Double {
        didSet {
            UserDefaults.standard.set(minimumSpeedMBps, forKey: Keys.minimumSpeedMBps)
        }
    }

    var warmupSeconds: Int {
        didSet {
            UserDefaults.standard.set(warmupSeconds, forKey: Keys.warmupSeconds)
        }
    }

    var checkIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(checkIntervalSeconds, forKey: Keys.checkIntervalSeconds)
        }
    }

    var connectionsPerMirror: Int {
        didSet {
            UserDefaults.standard.set(connectionsPerMirror, forKey: Keys.connectionsPerMirror)
        }
    }

    var playCompletionSound: Bool {
        didSet {
            UserDefaults.standard.set(playCompletionSound, forKey: Keys.playCompletionSound)
        }
    }

    var useBypassProxies: Bool {
        didSet {
            UserDefaults.standard.set(useBypassProxies, forKey: Keys.useBypassProxies)
        }
    }

    let maxMirrors: Int = 48

    init() {
        let defaults = UserDefaults.standard

        if let savedPath = defaults.string(forKey: Keys.downloadDirectory), !savedPath.isEmpty {
            self.downloadDirectory = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            self.downloadDirectory = Self.defaultDownloadDirectory
        }

        let storedSpeed = defaults.object(forKey: Keys.minimumSpeedMBps) as? Double
        self.minimumSpeedMBps = storedSpeed ?? 3.0

        let storedWarmup = defaults.object(forKey: Keys.warmupSeconds) as? Int
        self.warmupSeconds = storedWarmup ?? 20

        let storedCheck = defaults.object(forKey: Keys.checkIntervalSeconds) as? Int
        self.checkIntervalSeconds = storedCheck ?? 6

        let storedConn = defaults.object(forKey: Keys.connectionsPerMirror) as? Int
        self.connectionsPerMirror = storedConn ?? 8

        if defaults.object(forKey: Keys.playCompletionSound) != nil {
            self.playCompletionSound = defaults.bool(forKey: Keys.playCompletionSound)
        } else {
            self.playCompletionSound = true
        }

        if defaults.object(forKey: Keys.useBypassProxies) != nil {
            self.useBypassProxies = defaults.bool(forKey: Keys.useBypassProxies)
        } else {
            self.useBypassProxies = true
        }
    }

    func resetDefaults() {
        downloadDirectory = Self.defaultDownloadDirectory
        minimumSpeedMBps = 3.0
        warmupSeconds = 20
        checkIntervalSeconds = 6
        connectionsPerMirror = 8
        playCompletionSound = true
        useBypassProxies = true
    }
}
