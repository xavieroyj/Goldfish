import Foundation

enum GoldfishLog {
    /// Past this size the log moves to `debug.1.log`, replacing the previous
    /// one, and a new log starts, so at most about twice this is kept.
    static let maximumSize: UInt64 = 5 * 1024 * 1024
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Goldfish", isDirectory: true)
    /// Scan workers log concurrently; one writer at a time keeps lines whole.
    private static let lock = NSLock()

    static func write(_ message: String) {
        write(message, to: directory, maximumSize: maximumSize)
    }

    static func write(_ message: String, to directory: URL, maximumSize: UInt64) {
        let data = Data("[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".utf8)
        let logFile = directory.appendingPathComponent("debug.log")
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            let size = handle.seekToEndOfFile()
            if size > 0, size + UInt64(data.count) > maximumSize {
                try? handle.close()
                let previous = directory.appendingPathComponent("debug.1.log")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: logFile, to: previous)
                try? data.write(to: logFile, options: .atomic)
                return
            }
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFile, options: .atomic)
        }
    }
}
