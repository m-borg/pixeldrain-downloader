import Foundation

struct Aria2Binary: Sendable {
    let url: URL
    let isBundled: Bool
}

enum Aria2Locator {
    static func locate() -> Aria2Binary? {
        let fm = FileManager.default

        if let helperURL = Bundle.main.url(forAuxiliaryExecutable: "aria2c"),
           fm.isExecutableFile(atPath: helperURL.path) {
            return Aria2Binary(url: helperURL, isBundled: true)
        }

        let explicitHelpersURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/aria2c")
        if fm.isExecutableFile(atPath: explicitHelpersURL.path) {
            return Aria2Binary(url: explicitHelpersURL, isBundled: true)
        }

        var candidates = [
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
            "/usr/bin/aria2c",
        ]

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append(String(dir) + "/aria2c")
            }
        }

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if fm.isExecutableFile(atPath: path) {
                return Aria2Binary(url: URL(fileURLWithPath: path), isBundled: false)
            }
        }

        return nil
    }

    static func versionString(for binaryURL: URL) -> String? {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8),
               let firstLine = text.components(separatedBy: .newlines).first {
                return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }
        return nil
    }
}
