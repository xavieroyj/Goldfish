import Foundation

public struct DeviceProvider: Sendable {
    public init() {}

    public func devices() -> [Device] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        var devices: [Device] = []
        for entry in entries where !entry.hasPrefix(".") {
            let mountPath = "/Volumes/\(entry)"
            guard let info = diskInfo(mountPath: mountPath) else { continue }
            // Every field decides whether and how the volume may be scanned, so
            // a volume diskutil does not fully describe is left out.
            guard let identifier = info["DeviceIdentifier"] as? String,
                  let deviceNode = info["DeviceNode"] as? String, deviceNode.hasPrefix("/dev/disk"),
                  let isInternal = (info["Internal"] as? NSNumber)?.boolValue,
                  let isRemovable = (info["Removable"] as? NSNumber)?.boolValue,
                  let size = (info["IOKitSize"] as? NSNumber)?.uint64Value, size > 0 else {
                GoldfishLog.write("Skipping \(mountPath): diskutil did not report device node, internal/removable flags, and size")
                continue
            }
            devices.append(Device(
                mountPath: mountPath,
                name: entry,
                path: deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"),
                isRemovable: isRemovable,
                isInternal: isInternal,
                identifier: info["ParentWholeDisk"] as? String ?? identifier,
                size: size
            ))
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func diskInfo(mountPath: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", mountPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain the pipe before waiting so a large plist cannot block diskutil.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
