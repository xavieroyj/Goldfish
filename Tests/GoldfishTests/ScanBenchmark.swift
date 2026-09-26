import Foundation
import CryptoKit
import Testing
@testable import Goldfish

/// Scans a real device or attached disk image and prints timing. Skipped
/// unless GOLDFISH_BENCH_DEVICE names a raw device, for example:
///
///     GOLDFISH_BENCH_DEVICE=/dev/rdisk6s1 swift test -c release -Xswiftc -enable-testing --filter ScanBenchmark
///
/// Set GOLDFISH_BENCH_MANIFEST to a file path to also write every recovered
/// file's offset, size, name and SHA-256, for comparing two builds' results.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GOLDFISH_BENCH_DEVICE"] != nil))
func ScanBenchmark() async throws {
    let path = ProcessInfo.processInfo.environment["GOLDFISH_BENCH_DEVICE"]!
    let size = try benchmarkDeviceSize(path)
    let device = Device(mountPath: "/Volumes/benchmark", name: "Benchmark", path: path, isRemovable: true, isInternal: false, identifier: "benchmark", size: size)

    let start = DispatchTime.now().uptimeNanoseconds
    let files = try await RecoveryEngine().scan(device: device) { _ in }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

    let bySource = Dictionary(grouping: files, by: \.recoverySource).mapValues(\.count)
    let byKind = Dictionary(grouping: files, by: \.kind).mapValues(\.count)
    let byStatus = Dictionary(grouping: files, by: \.status).mapValues(\.count)
    let recoveredBytes = files.reduce(UInt64(0)) { $0 + $1.size }
    print(String(format: "BENCH scan: %.2fs, %.0f MiB/s over %.0f MiB", seconds, Double(size) / seconds / 1_048_576, Double(size) / 1_048_576))
    if let manifestPath = ProcessInfo.processInfo.environment["GOLDFISH_BENCH_MANIFEST"] {
        var lines: [String] = []
        for file in files.sorted(by: { $0.offset < $1.offset }) {
            let digest = SHA256.hash(data: try file.readData()).map { String(format: "%02x", $0) }.joined()
            lines.append("\(file.offset)\t\(file.size)\t\(file.recoverySource.rawValue)\t\(file.name).\(file.fileExtension)\t\(file.physicalRanges.count)\t\(digest)")
        }
        try lines.joined(separator: "\n").appending("\n").write(toFile: manifestPath, atomically: true, encoding: .utf8)
    }
    print("BENCH files: \(files.count), recovered \(recoveredBytes / 1_048_576) MiB, sources \(bySource), kinds \(byKind)")
    print("BENCH status: \(byStatus)")
}

private func benchmarkDeviceSize(_ path: String) throws -> UInt64 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "-plist", path.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    return (info["IOKitSize"] as! NSNumber).uint64Value
}
