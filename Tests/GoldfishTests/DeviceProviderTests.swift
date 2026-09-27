import Foundation
import Testing
@testable import Goldfish

/// `diskutil info -plist` output for a partition, trimmed to the keys Goldfish reads.
private func diskInfo(node: String = "disk4s1", parent: String? = "disk4", isInternal: Bool?, removable: Bool?, size: UInt64? = 61_874_372_608, filesystem: String? = "ExFAT") -> [String: Any] {
    var info: [String: Any] = ["DeviceIdentifier": node, "DeviceNode": "/dev/\(node)"]
    if let parent { info["ParentWholeDisk"] = parent }
    if let isInternal { info["Internal"] = NSNumber(value: isInternal) }
    if let removable { info["Removable"] = NSNumber(value: removable) }
    if let size { info["IOKitSize"] = NSNumber(value: size) }
    if let filesystem { info["FilesystemPersonality"] = filesystem }
    return info
}

private func device(_ info: [String: Any], lookup: (String) -> [String: Any]? = { _ in nil }) -> Device? {
    DeviceProvider.device(mountPath: "/Volumes/Untitled", name: "Untitled", info: info, lookup: lookup)
}

@Test func cardInBuiltInReaderIsScannable() throws {
    // A built-in SD slot reports its cards as Internal and Removable.
    let card = try #require(device(diskInfo(isInternal: true, removable: true)))
    #expect(card.isInternal == false)
    #expect(card.isRemovable == true)
    #expect(card.path == "/dev/rdisk4s1")
    #expect(card.identifier == "disk4")
    #expect(card.size == 61_874_372_608)
    #expect(card.filesystem == "exFAT")
}

@Test func cardInUSBReaderIsScannable() throws {
    let card = try #require(device(diskInfo(isInternal: false, removable: true)))
    #expect(card.isInternal == false)
}

@Test func fixedInternalDiskIsBlocked() throws {
    let disk = try #require(device(diskInfo(node: "disk1s1", parent: "disk1", isInternal: true, removable: false, filesystem: "APFS")))
    #expect(disk.isInternal == true)
}

@Test func identifierFallsBackToPartitionWithoutParentDisk() throws {
    let card = try #require(device(diskInfo(parent: nil, isInternal: false, removable: true)))
    #expect(card.identifier == "disk4s1")
}

@Test func volumeWithoutRequiredFieldsIsSkipped() {
    #expect(device(diskInfo(isInternal: nil, removable: true)) == nil)
    #expect(device(diskInfo(isInternal: true, removable: nil)) == nil)
    #expect(device(diskInfo(isInternal: false, removable: true, size: nil)) == nil)
    #expect(device(diskInfo(isInternal: false, removable: true, size: 0)) == nil)
}

@Test func volumeWithNonDiskNodeIsSkipped() {
    var info = diskInfo(isInternal: false, removable: true)
    info["DeviceNode"] = "/private/var/vm/image"
    #expect(device(info) == nil)
}

@Test func apfsVolumeScansItsPhysicalStore() throws {
    var info = diskInfo(node: "disk7s1", parent: "disk7", isInternal: false, removable: true, size: 100, filesystem: "APFS")
    info["APFSPhysicalStores"] = [["APFSPhysicalStore": "disk6s2"]]
    var lookedUp: [String] = []
    let store = diskInfo(node: "disk6s2", parent: "disk6", isInternal: false, removable: true, size: 5_000_000)
    let volume = try #require(device(info) { target in
        lookedUp.append(target)
        return target == "/dev/disk6s2" ? store : nil
    })
    #expect(lookedUp == ["/dev/disk6s2"])
    #expect(volume.path == "/dev/rdisk6s2")
    #expect(volume.size == 5_000_000)
    #expect(volume.filesystem == "APFS")
}

@Test func apfsVolumeWithUnclearPhysicalStoreIsSkipped() {
    var twoStores = diskInfo(isInternal: false, removable: true, filesystem: "APFS")
    twoStores["APFSPhysicalStores"] = [["APFSPhysicalStore": "disk6s2"], ["APFSPhysicalStore": "disk8s2"]]
    #expect(device(twoStores) { _ in diskInfo(isInternal: false, removable: true) } == nil)

    var missingStore = diskInfo(isInternal: false, removable: true, filesystem: "APFS")
    missingStore["APFSPhysicalStores"] = [["APFSPhysicalStore": "disk6s2"]]
    #expect(device(missingStore) { _ in nil } == nil)
}

@Test(arguments: [
    ("ExFAT", "exFAT"), ("FAT32", "FAT32"), ("MS-DOS", "MS-DOS"), ("msdos", "FAT"),
    ("apfs", "APFS"), ("HFS+", "HFS+"), ("hfsx", "HFS+"), ("NTFS", "NTFS"),
])
func filesystemNamesAreNormalized(raw: String, shown: String) {
    #expect(DeviceProvider.filesystemDescription(from: ["FilesystemPersonality": raw]) == shown)
}

@Test func filesystemNameFallsBackThroughKeysThenUnknown() {
    #expect(DeviceProvider.filesystemDescription(from: ["FilesystemType": "exfat"]) == "exFAT")
    #expect(DeviceProvider.filesystemDescription(from: ["FilesystemPersonality": "ExFAT", "FilesystemType": "msdos"]) == "exFAT")
    #expect(DeviceProvider.filesystemDescription(from: [:]) == "Unknown")
}
