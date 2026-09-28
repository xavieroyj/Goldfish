import Foundation
import Testing
@testable import Goldfish

private func lines(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

@Test func logRotatesInsteadOfGrowingWithoutLimit() throws {
    let folder = try TemporaryFolder()
    let log = folder.url.appendingPathComponent("debug.log")
    let previous = folder.url.appendingPathComponent("debug.1.log")
    for index in 0..<100 {
        GoldfishLog.write("message \(index)", to: folder.url, maximumSize: 400)
    }
    let size = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0 }
    #expect(try size(log) <= 400)
    #expect(try size(previous) <= 400)
    #expect(try lines(log).last?.hasSuffix("message 99") == true)
    // Only the current and one previous log are kept.
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == ["debug.1.log", "debug.log"])
}

@Test func concurrentLogWritesKeepEveryLineWhole() throws {
    let folder = try TemporaryFolder()
    let url = folder.url
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
        for index in 0..<250 {
            GoldfishLog.write("worker \(worker) line \(index)", to: url, maximumSize: 10 * 1024 * 1024)
        }
    }
    let written = try lines(url.appendingPathComponent("debug.log"))
    #expect(written.count == 2000)
    let pattern = /^\[[0-9TZ:-]+\] worker [0-7] line [0-9]+$/
    #expect(written.allSatisfy { $0.wholeMatch(of: pattern) != nil })
}
