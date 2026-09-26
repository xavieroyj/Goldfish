import Foundation

enum GoldfishLog {
    static func write(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Goldfish", isDirectory: true)
        let logFile = directory.appendingPathComponent("debug.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
    }
}
