import Foundation

public struct DeviceProvider: Sendable {
    public init() {}

    public func devices() -> [Device] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        var devices: [Device] = []
        for entry in entries where !entry.hasPrefix(".") {
            let mountPath = "/Volumes/\(entry)"
            guard let info = diskInfo(mountPath: mountPath) else { continue }
            let identifier = info["DeviceIdentifier"] as? String ?? ""
            let deviceNode = info["DeviceNode"] as? String ?? ""
            let rawDeviceNode = deviceNode.hasPrefix("/dev/disk")
                ? deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
                : deviceNode
            let parent = info["ParentWholeDisk"] as? String ?? identifier
            let size = (info["IOKitSize"] as? NSNumber)?.uint64Value ?? (info["TotalSize"] as? NSNumber)?.uint64Value ?? 0
            let isRemovable = (info["Removable"] as? NSNumber)?.boolValue ?? true
            let isInternal = (info["Internal"] as? NSNumber)?.boolValue ?? false
            guard !deviceNode.isEmpty else { continue }
            devices.append(Device(id: mountPath, name: entry, path: rawDeviceNode, isRemovable: isRemovable, isReadOnly: true, identifier: parent, size: size, isInternal: isInternal))
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func diskInfo(mountPath: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", mountPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
