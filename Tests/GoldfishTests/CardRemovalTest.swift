import Foundation
import Testing
@testable import Goldfish

/// Attaches real disk images with hdiutil, so it only runs when
/// GOLDFISH_CARD_REMOVAL_TEST is set:
///
///     GOLDFISH_CARD_REMOVAL_TEST=1 swift test --filter CardRemoval
///
/// Scans a card, ejects it, attaches a different card (which may take over the
/// same device node), and checks that export fails without leaving a file.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GOLDFISH_CARD_REMOVAL_TEST"] != nil))
func CardRemovalFailsExportWithoutReadingAnotherCard() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("goldfish-card-removal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let first = try attachImage(named: "FIRST", in: workspace)
    var detached = false
    defer { if !detached { _ = try? hdiutil(["detach", "-force", first.wholeDisk]) } }
    let photo = syntheticJPEG()
    let photoURL = URL(fileURLWithPath: first.mountPoint).appendingPathComponent("PHOTO.JPG")
    FileManager.default.createFile(atPath: photoURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: photoURL)
    try handle.write(contentsOf: photo)
    try handle.synchronize()
    try handle.close()

    let device = Device(mountPath: first.mountPoint, name: "FIRST", path: first.rawNode, isRemovable: true, isInternal: false, identifier: first.wholeDisk, size: try deviceSize(first.rawNode))
    let files = try await RecoveryEngine().scan(device: device) { _ in }
    let recovered = try #require(files.first { $0.size == UInt64(photo.count) })
    #expect(try recovered.readData() == photo)

    try hdiutil(["detach", "-force", first.wholeDisk])
    detached = true
    let second = try attachImage(named: "SECOND", in: workspace)
    defer { _ = try? hdiutil(["detach", "-force", second.wholeDisk]) }

    let destination = workspace.appendingPathComponent("exported.jpg")
    let exportError = #expect(throws: RecoveryError.self) { try recovered.write(to: destination) }
    guard case .deviceDisconnected = exportError else {
        Issue.record("Expected deviceDisconnected, got \(String(describing: exportError))")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(throws: RecoveryError.self) { try recovered.readData() }
}

private struct AttachedImage {
    let wholeDisk: String
    let rawNode: String
    let mountPoint: String
}

private func attachImage(named name: String, in directory: URL) throws -> AttachedImage {
    let image = directory.appendingPathComponent("\(name).dmg")
    try hdiutil(["create", "-size", "64m", "-fs", "MS-DOS FAT32", "-volname", name, "-layout", "MBRSPUD", image.path])
    let output = try hdiutil(["attach", "-plist", image.path])
    let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as! [String: Any]
    let entities = plist["system-entities"] as! [[String: Any]]
    let volume = entities.first { $0["mount-point"] != nil }!
    let node = volume["dev-entry"] as! String
    return AttachedImage(wholeDisk: entities[0]["dev-entry"] as! String, rawNode: node.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"), mountPoint: volume["mount-point"] as! String)
}

@discardableResult
private func hdiutil(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.joined(separator: " ")) failed"]) }
    return output
}

private func deviceSize(_ rawNode: String) throws -> UInt64 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "-plist", rawNode.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let info = try PropertyListSerialization.propertyList(from: output, format: nil) as! [String: Any]
    return (info["IOKitSize"] as! NSNumber).uint64Value
}

/// A structurally valid baseline JPEG with enough scan data to span several sectors.
private func syntheticJPEG() -> Data {
    let sof = Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
    let sos = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    let scan = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
    return Data([0xFF, 0xD8]) + sof + sos + scan + Data([0xFF, 0xD9])
}
