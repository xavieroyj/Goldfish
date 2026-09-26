import Foundation

struct DeletedFileRecord: Sendable {
    let name: String
    let fileExtension: String
    let offset: UInt64
    let size: UInt64
    /// Where the data lives on the device, in file order.
    let extents: [ScannedRange]
    let isContiguousEstimate: Bool

    var filename: String { fileExtension.isEmpty ? name : "\(name).\(fileExtension)" }
}

/// A best-effort, read-only view of FAT32 or exFAT directory metadata. It
/// supplies original names for carved files and recovers deleted files the
/// signature scan cannot recognise. It is empty for other file systems.
struct FileSystemIndex {
    /// Original filenames keyed by the device offset of the file's first byte.
    let namesByOffset: [UInt64: String]
    let deletedFiles: [DeletedFileRecord]

    static let empty = FileSystemIndex(namesByOffset: [:], deletedFiles: [])

    static func load(from device: RawDevice) -> FileSystemIndex {
        guard let boot = try? device.read(at: 0, count: 512), boot.count == 512 else { return .empty }
        let volume: (any FATVolume)?
        if boot[3..<11] == ExFATVolume.fileSystemName {
            volume = ExFATVolume(device: device, boot: boot)
        } else {
            volume = FAT32Volume(device: device, boot: boot)
        }
        guard let volume else { return .empty }
        return FileSystemIndex(volume: volume)
    }

    private init(namesByOffset: [UInt64: String], deletedFiles: [DeletedFileRecord]) {
        self.namesByOffset = namesByOffset
        self.deletedFiles = deletedFiles
    }

    private init(volume: any FATVolume) {
        var names: [UInt64: String] = [:]
        var deleted: [DeletedFileRecord] = []
        for entry in volume.fileEntries() {
            let offset = volume.dataOffset(entry.firstCluster)
            guard offset < volume.device.total else { continue }
            if case .full(let name) = entry.name, !name.isEmpty {
                names[offset] = name
            }
            if entry.isDeleted, let record = Self.deletedRecord(for: entry, at: offset, in: volume) {
                deleted.append(record)
            }
        }
        self.init(namesByOffset: names, deletedFiles: deleted)
    }

    private static func deletedRecord(for entry: FATDirectoryEntry, at offset: UInt64, in volume: any FATVolume) -> DeletedFileRecord? {
        guard let (extents, estimated) = volume.extents(for: entry) else { return nil }
        let generatedName = RecoveredFile.generatedName(offset: offset)
        let name: String
        let fileExtension: String
        switch entry.name {
        case .full(let original) where original.isEmpty:
            name = generatedName
            fileExtension = ""
        case .full(let original):
            let safeName = URL(fileURLWithPath: original).lastPathComponent
            fileExtension = (safeName as NSString).pathExtension.lowercased()
            let stem = (safeName as NSString).deletingPathExtension
            name = stem.isEmpty ? generatedName : stem
        case .extensionOnly(let ext):
            name = generatedName
            fileExtension = ext
        }
        return DeletedFileRecord(name: name, fileExtension: fileExtension, offset: offset, size: entry.size, extents: extents, isContiguousEstimate: estimated)
    }
}
