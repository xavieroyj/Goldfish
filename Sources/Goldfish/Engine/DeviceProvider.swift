import Foundation

public struct DeviceProvider: Sendable {
    public init() {}

    public func devices() -> [Device] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        var devices: [Device] = []
        for entry in entries where !entry.hasPrefix(".") {
            let mountPath = "/Volumes/\(entry)"
            guard let info = diskInfo(target: mountPath) else { continue }
            // Every field decides whether and how the volume may be scanned, so
            // a volume diskutil does not fully describe is left out.
            guard let identifier = info["DeviceIdentifier"] as? String,
                  let isInternal = (info["Internal"] as? NSNumber)?.boolValue,
                  let isRemovable = (info["Removable"] as? NSNumber)?.boolValue,
                  let (deviceNode, size) = scanTarget(for: info) else {
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
                size: size,
                filesystem: filesystemDescription(from: info)
            ))
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The device node to scan and its size. An APFS volume's node is a virtual
    /// device that macOS will not read raw, so its container's physical
    /// partition is scanned instead; it also holds the free space where
    /// deleted data survives.
    private func scanTarget(for info: [String: Any]) -> (deviceNode: String, size: UInt64)? {
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
            guard stores.count == 1, let store = stores[0]["APFSPhysicalStore"] as? String,
                  let storeInfo = diskInfo(target: "/dev/\(store)") else { return nil }
            return scanTarget(for: storeInfo)
        }
        guard let deviceNode = info["DeviceNode"] as? String, deviceNode.hasPrefix("/dev/disk"),
              let size = (info["IOKitSize"] as? NSNumber)?.uint64Value, size > 0 else { return nil }
        return (deviceNode, size)
    }

    private func filesystemDescription(from info: [String: Any]) -> String {
        let keys = ["FilesystemPersonality", "FileSystemPersonality", "FilesystemName", "FileSystemName", "FilesystemType", "FileSystemType"]
        let raw = keys.lazy.compactMap { info[$0] as? String }.first ?? "Unknown"
        switch raw.lowercased() {
        case "exfat": return "exFAT"
        case "fat32": return "FAT32"
        case "msdos": return "FAT"
        case "apfs": return "APFS"
        case "hfs+", "hfsplus", "hfsx": return "HFS+"
        default: return raw
        }
    }

    private func diskInfo(target: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", target]
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
