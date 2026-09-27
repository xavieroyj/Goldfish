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
struct FileSystemIndex: Sendable {
    /// Every macOS AppleDouble file ("._name") starts with this magic number.
    private static let appleDoubleMagic = Data([0x00, 0x05, 0x16, 0x07])

    /// Original filenames keyed by the device offset of the file's first byte.
    let namesByOffset: [UInt64: String]
    /// Start offsets of files that live directory entries point to.
    let liveOffsets: Set<UInt64>
    /// Start offsets of files that only deleted directory entries point to.
    let deletedOffsets: Set<UInt64>
    let deletedFiles: [DeletedFileRecord]

    static let empty = FileSystemIndex(namesByOffset: [:], liveOffsets: [], deletedOffsets: [], deletedFiles: [])

    func status(at offset: UInt64) -> FileStatus {
        if liveOffsets.contains(offset) { return .stillOnCard }
        if deletedOffsets.contains(offset) { return .deleted }
        return .noRecord
    }

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

    private init(namesByOffset: [UInt64: String], liveOffsets: Set<UInt64>, deletedOffsets: Set<UInt64>, deletedFiles: [DeletedFileRecord]) {
        self.namesByOffset = namesByOffset
        self.liveOffsets = liveOffsets
        self.deletedOffsets = deletedOffsets
        self.deletedFiles = deletedFiles
    }

    private init(volume: any FATVolume) {
        let entries = volume.fileEntries().compactMap { entry -> (entry: FATDirectoryEntry, offset: UInt64)? in
            let offset = volume.dataOffset(entry.firstCluster)
            return offset < volume.device.total ? (entry, offset) : nil
        }
        // When a live and a deleted entry share a start cluster, the space was
        // reused: the bytes now belong to the live file.
        let liveOffsets = Set(entries.filter { !$0.entry.isDeleted }.map(\.offset))
        var names: [UInt64: String] = [:]
        var deletedOffsets = Set<UInt64>()
        var deleted: [DeletedFileRecord] = []
        for (entry, offset) in entries {
            let isLive = liveOffsets.contains(offset)
            let ownsData = !entry.isDeleted || !isLive
            if case .full(let name) = entry.name, !name.isEmpty, ownsData {
                names[offset] = name
            }
            guard entry.isDeleted, !isLive else { continue }
            deletedOffsets.insert(offset)
            if let record = Self.deletedRecord(for: entry, at: offset, in: volume) {
                deleted.append(record)
            }
        }
        // macOS writes a "._" AppleDouble sidecar beside each file it copies to
        // a FAT volume. It holds only Mac metadata, never file contents, so it
        // is not worth recovering.
        let sidecarCount = deleted.count
        deleted.removeAll { Self.isAppleDouble($0, on: volume.device) }
        if sidecarCount > deleted.count {
            GoldfishLog.write("Skipped \(sidecarCount - deleted.count) deleted macOS AppleDouble sidecar file(s)")
        }
        self.init(namesByOffset: names, liveOffsets: liveOffsets, deletedOffsets: deletedOffsets, deletedFiles: deleted)
    }

    private static func isAppleDouble(_ record: DeletedFileRecord, on device: RawDevice) -> Bool {
        guard record.size >= UInt64(appleDoubleMagic.count) else { return false }
        return (try? device.read(at: record.offset, count: appleDoubleMagic.count)) == appleDoubleMagic
    }

    private static func deletedRecord(for entry: FATDirectoryEntry, at offset: UInt64, in volume: any FATVolume) -> DeletedFileRecord? {
        guard let (extents, estimated) = volume.extents(for: entry) else { return nil }
        let generatedName = RecoveredFile.generatedName(offset: offset)
        let name: String
        let fileExtension: String
        switch entry.name {
        case .full(let original):
            guard let safeName = RecoveredFile.safeFilename(original) else {
                name = generatedName
                fileExtension = ""
                break
            }
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
