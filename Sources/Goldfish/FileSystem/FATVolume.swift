import Foundation

/// A file entry found while walking a FAT32 or exFAT directory tree.
struct FATDirectoryEntry {
    enum Name {
        /// The complete original filename.
        case full(String)
        /// A deleted FAT32 short entry loses the first character of its name,
        /// so only the extension survives.
        case extensionOnly(String)
    }

    let name: Name
    let firstCluster: UInt32
    let size: UInt64
    let isDeleted: Bool
    /// exFAT "NoFatChain": the data is one contiguous run of clusters.
    let isContiguous: Bool
}

/// The layout and directory tree of a FAT32 or exFAT volume. Conforming types
/// validate the boot sector in their failable initializers, so an instance
/// always describes a plausible volume.
protocol FATVolume {
    var device: RawDevice { get }
    var clusterSize: UInt64 { get }
    var heapOffset: UInt64 { get }
    var rootCluster: UInt32 { get }

    func nextCluster(after cluster: UInt32) -> UInt32?
    /// The file entries of every directory reachable from the root.
    func fileEntries() -> [FATDirectoryEntry]
    /// The clusters holding an entry's data, and whether their order is an
    /// assumption rather than read from the FAT.
    func dataClusters(for entry: FATDirectoryEntry, count: UInt64) -> (clusters: [UInt32], estimated: Bool)?
}

enum FATLimits {
    static let maximumDirectories = 100_000
    static let maximumDirectoryBytes = 32 * 1024 * 1024
    static let maximumChainLength = 1_000_000
    static let entrySize = 32
}

extension FATVolume {
    func dataOffset(_ cluster: UInt32) -> UInt64 {
        precondition(cluster >= 2, "FAT data clusters start at 2")
        return heapOffset + UInt64(cluster - 2) * clusterSize
    }

    /// Reads exactly `count` bytes, or returns nil.
    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard let data = try? device.read(at: offset, count: count), data.count == count else { return nil }
        return data
    }

    /// Follows the cluster chain from `start` for at most `limit` clusters.
    /// Returns nil when the chain loops back on itself.
    func chain(from start: UInt32, limit: UInt64) -> [UInt32]? {
        var clusters = [start]
        var visited: Set<UInt32> = [start]
        while UInt64(clusters.count) < limit, let next = nextCluster(after: clusters[clusters.count - 1]) {
            guard visited.insert(next).inserted else { return nil }
            clusters.append(next)
        }
        return clusters
    }

    func contiguousRun(from start: UInt32, count: UInt64) -> [UInt32]? {
        guard count <= UInt64(UInt32.max - start) + 1 else { return nil }
        return (0..<UInt32(count)).map { start + $0 }
    }

    /// Reads a directory's cluster chain, stopping at a loop, an unreadable
    /// cluster, or the size cap.
    func readDirectory(startingAt start: UInt32) -> Data {
        var output = Data()
        var current: UInt32? = start
        var visited = Set<UInt32>()
        while let cluster = current, visited.insert(cluster).inserted, visited.count < FATLimits.maximumChainLength,
              output.count < FATLimits.maximumDirectoryBytes, let bytes = read(dataOffset(cluster), Int(clusterSize)) {
            output.append(bytes.prefix(FATLimits.maximumDirectoryBytes - output.count))
            current = nextCluster(after: cluster)
        }
        return output
    }

    /// The device ranges holding an entry's data, in file order.
    func extents(for entry: FATDirectoryEntry) -> (extents: [ScannedRange], estimated: Bool)? {
        guard entry.size > 0, entry.size <= device.total else { return nil }
        let needed = (entry.size + clusterSize - 1) / clusterSize
        guard needed <= UInt64(FATLimits.maximumChainLength),
              let (clusters, estimated) = dataClusters(for: entry, count: needed) else { return nil }
        var remaining = entry.size
        var extents: [ScannedRange] = []
        for cluster in clusters {
            let offset = dataOffset(cluster)
            let length = min(clusterSize, remaining)
            guard offset <= device.total, length <= device.total - offset else { return nil }
            if let last = extents.last, last.end == offset {
                extents[extents.count - 1] = ScannedRange(start: last.start, end: offset + length)
            } else {
                extents.append(ScannedRange(start: offset, end: offset + length))
            }
            remaining -= length
        }
        return remaining == 0 ? (extents, estimated) : nil
    }
}

func le16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

func le32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(le16(data, offset)) | UInt32(le16(data, offset + 2)) << 16
}

func le64(_ data: Data, _ offset: Int) -> UInt64 {
    UInt64(le32(data, offset)) | UInt64(le32(data, offset + 4)) << 32
}

struct FAT32Volume: FATVolume {
    private static let endOfChain: UInt32 = 0x0FFF_FFF8
    private static let clusterMask: UInt32 = 0x0FFF_FFFF

    let device: RawDevice
    let clusterSize: UInt64
    let heapOffset: UInt64
    let rootCluster: UInt32
    private let fatOffset: UInt64
    private let fatEntryCount: UInt64

    init?(device: RawDevice, boot: Data) {
        precondition(boot.count == 512, "Boot sector must be one 512-byte sector")
        let bytesPerSector = UInt64(le16(boot, 11))
        let sectorsPerCluster = UInt64(boot[13])
        let reservedSectors = UInt64(le16(boot, 14))
        let fatCount = UInt64(boot[16])
        let sectorsPerFAT = UInt64(le32(boot, 36))
        let rootCluster = le32(boot, 44)
        // Root entry count and 16-bit FAT size are zero only on FAT32.
        guard boot[510] == 0x55, boot[511] == 0xAA,
              (512...4096).contains(bytesPerSector),
              sectorsPerCluster > 0, sectorsPerCluster.nonzeroBitCount == 1,
              bytesPerSector * sectorsPerCluster <= 1024 * 1024,
              reservedSectors > 0, (1...4).contains(fatCount), sectorsPerFAT > 0,
              le16(boot, 17) == 0, le16(boot, 22) == 0,
              rootCluster >= 2 else { return nil }
        let fatOffset = reservedSectors * bytesPerSector
        let fatBytes = sectorsPerFAT * bytesPerSector
        let heapOffset = fatOffset + fatCount * fatBytes
        guard fatOffset < device.total, heapOffset < device.total else { return nil }
        self.device = device
        self.clusterSize = bytesPerSector * sectorsPerCluster
        self.heapOffset = heapOffset
        self.rootCluster = rootCluster
        self.fatOffset = fatOffset
        self.fatEntryCount = fatBytes / 4
    }

    func nextCluster(after cluster: UInt32) -> UInt32? {
        guard let value = fatEntry(cluster), value >= 2, value < Self.endOfChain else { return nil }
        return value
    }

    func fileEntries() -> [FATDirectoryEntry] {
        var entries: [FATDirectoryEntry] = []
        var pending = [rootCluster]
        var visited = Set<UInt32>()
        while let directoryCluster = pending.popLast(), visited.insert(directoryCluster).inserted, visited.count < FATLimits.maximumDirectories {
            let directory = readDirectory(startingAt: directoryCluster)
            var longNameParts: [Int: String] = [:]
            var expectedLongNameCount: Int?
            for base in stride(from: 0, through: directory.count - FATLimits.entrySize, by: FATLimits.entrySize) {
                let first = directory[base]
                if first == 0 { break }
                let attributes = directory[base + 11]
                if attributes == 0x0F {
                    if first & 0x40 != 0 {
                        longNameParts.removeAll(keepingCapacity: true)
                        expectedLongNameCount = Int(first & 0x1F)
                    }
                    let index = Int(first & 0x1F)
                    if index > 0 { longNameParts[index] = decodeLongNamePart(directory, base) }
                    continue
                }
                let longName = expectedLongNameCount.flatMap { count in
                    longNameParts.count == count ? (1...count).compactMap { longNameParts[$0] }.joined() : nil
                }
                longNameParts.removeAll(keepingCapacity: true)
                expectedLongNameCount = nil
                let isVolumeLabel = attributes & 0x08 != 0
                let isDirectory = attributes & 0x10 != 0
                let cluster = UInt32(le16(directory, base + 20)) << 16 | UInt32(le16(directory, base + 26))
                guard !isVolumeLabel, cluster >= 2 else { continue }
                let size = UInt64(le32(directory, base + 28))

                if first == 0xE5 {
                    guard !isDirectory else { continue }
                    let extBytes = directory[(base + 8)..<(base + 11)].filter { $0 != 0x20 && $0 != 0x00 }
                    let ext = String(decoding: extBytes, as: UTF8.self).lowercased()
                    entries.append(FATDirectoryEntry(name: .extensionOnly(ext), firstCluster: cluster, size: size, isDeleted: true, isContiguous: false))
                    continue
                }
                let name = longName ?? decodeShortName(directory, base)
                guard !name.isEmpty, name != ".", name != ".." else { continue }
                if isDirectory {
                    pending.append(cluster)
                } else {
                    entries.append(FATDirectoryEntry(name: .full(name), firstCluster: cluster, size: size, isDeleted: false, isContiguous: false))
                }
            }
        }
        return entries
    }

    /// Follows the surviving FAT chain. When deletion has cleared the chain,
    /// assumes the data continues in consecutive clusters.
    func dataClusters(for entry: FATDirectoryEntry, count: UInt64) -> (clusters: [UInt32], estimated: Bool)? {
        guard let clusters = chain(from: entry.firstCluster, limit: count) else { return nil }
        if UInt64(clusters.count) == count { return (clusters, false) }
        guard fatEntry(entry.firstCluster) == 0,
              let run = contiguousRun(from: entry.firstCluster, count: count) else { return nil }
        return (run, true)
    }

    private func fatEntry(_ cluster: UInt32) -> UInt32? {
        guard UInt64(cluster) < fatEntryCount, let bytes = read(fatOffset + UInt64(cluster) * 4, 4) else { return nil }
        return le32(bytes, 0) & Self.clusterMask
    }

    private func decodeLongNamePart(_ data: Data, _ base: Int) -> String {
        let positions = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        let units = positions.map { le16(data, base + $0) }.prefix { $0 != 0 && $0 != 0xFFFF }
        return String(decoding: units, as: UTF16.self)
    }

    private func decodeShortName(_ data: Data, _ base: Int) -> String {
        let stem = String(decoding: data[base..<(base + 8)].prefix { $0 != 0x20 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let ext = String(decoding: data[(base + 8)..<(base + 11)].prefix { $0 != 0x20 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}

struct ExFATVolume: FATVolume {
    static let fileSystemName = Data("EXFAT   ".utf8)
    private static let endOfChain: UInt32 = 0xFFFF_FFF8

    let device: RawDevice
    let clusterSize: UInt64
    let heapOffset: UInt64
    let rootCluster: UInt32
    private let fatOffset: UInt64

    init?(device: RawDevice, boot: Data) {
        precondition(boot.count == 512, "Boot sector must be one 512-byte sector")
        let bytesPerSectorShift = boot[108]
        let sectorsPerClusterShift = boot[109]
        guard boot[3..<11] == Self.fileSystemName,
              (9...12).contains(bytesPerSectorShift), sectorsPerClusterShift <= 16 else { return nil }
        let bytesPerSector = UInt64(1) << bytesPerSectorShift
        let clusterSize = bytesPerSector << sectorsPerClusterShift
        let rootCluster = le32(boot, 96)
        guard clusterSize <= 32 * 1024 * 1024, rootCluster >= 2 else { return nil }
        self.device = device
        self.clusterSize = clusterSize
        self.heapOffset = UInt64(le32(boot, 88)) * bytesPerSector
        self.rootCluster = rootCluster
        self.fatOffset = UInt64(le32(boot, 80)) * bytesPerSector
    }

    func nextCluster(after cluster: UInt32) -> UInt32? {
        guard let bytes = read(fatOffset + UInt64(cluster) * 4, 4) else { return nil }
        let value = le32(bytes, 0)
        return value >= 2 && value < Self.endOfChain ? value : nil
    }

    /// Walks active (0x85) and deleted (0x05) file entry sets. Deleted sets
    /// keep their stream and filename records, so they are still usable.
    func fileEntries() -> [FATDirectoryEntry] {
        var entries: [FATDirectoryEntry] = []
        var pending = [rootCluster]
        var visited = Set<UInt32>()
        while let directoryCluster = pending.popLast(), visited.insert(directoryCluster).inserted, visited.count < FATLimits.maximumDirectories {
            let directory = readDirectory(startingAt: directoryCluster)
            var index = 0
            while index + FATLimits.entrySize <= directory.count {
                let type = directory[index]
                if type == 0 { break }
                let secondaryCount = Int(directory[index + 1])
                let end = index + (secondaryCount + 1) * FATLimits.entrySize
                guard type == 0x85 || type == 0x05, secondaryCount >= 2, end <= directory.count else {
                    index += FATLimits.entrySize
                    continue
                }
                let isDirectory = le16(directory, index + 4) & 0x10 != 0
                var firstCluster: UInt32?
                var dataLength: UInt64 = 0
                var noFatChain = false
                var nameUnits: [UInt16] = []
                for secondary in stride(from: index + FATLimits.entrySize, to: end, by: FATLimits.entrySize) {
                    switch directory[secondary] {
                    case 0xC0, 0x40:
                        noFatChain = directory[secondary + 1] & 0x02 != 0
                        firstCluster = le32(directory, secondary + 20)
                        dataLength = le64(directory, secondary + 24)
                    case 0xC1, 0x41:
                        for unitOffset in stride(from: 2, to: FATLimits.entrySize, by: 2) {
                            let unit = le16(directory, secondary + unitOffset)
                            if unit != 0 { nameUnits.append(unit) }
                        }
                    default:
                        break
                    }
                }
                index = end
                guard let firstCluster, firstCluster >= 2 else { continue }
                if isDirectory {
                    pending.append(firstCluster)
                } else {
                    let name = String(decoding: nameUnits, as: UTF16.self)
                    entries.append(FATDirectoryEntry(name: .full(name), firstCluster: firstCluster, size: dataLength, isDeleted: type == 0x05, isContiguous: noFatChain))
                }
            }
        }
        return entries
    }

    func dataClusters(for entry: FATDirectoryEntry, count: UInt64) -> (clusters: [UInt32], estimated: Bool)? {
        if entry.isContiguous {
            return contiguousRun(from: entry.firstCluster, count: count).map { ($0, false) }
        }
        guard let clusters = chain(from: entry.firstCluster, limit: count), UInt64(clusters.count) == count else { return nil }
        return (clusters, false)
    }
}
