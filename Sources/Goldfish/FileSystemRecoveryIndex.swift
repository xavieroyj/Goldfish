import Foundation
import Darwin

struct FileSystemExtent: Sendable {
    let offset: UInt64
    let length: UInt64
}

struct DeletedFileRecord: Sendable {
    let name: String
    let fileExtension: String
    let offset: UInt64
    let size: UInt64
    let extents: [FileSystemExtent]
    let isContiguousEstimate: Bool
}

enum FileSystemRecoveryIndex {
    static func deletedFiles(path: String, total: UInt64) -> [DeletedFileRecord] {
        guard let reader = Reader(path: path, total: total),
              let boot = reader.read(0, 512), boot.count == 512 else { return [] }
        if String(data: boot[3..<11], encoding: .ascii) == "EXFAT   " {
            return ExFAT(reader: reader, boot: boot).deletedFiles()
        }
        return FAT32(reader: reader, boot: boot).deletedFiles()
    }
}

private final class Reader {
    let fd: Int32
    let total: UInt64

    init?(path: String, total: UInt64) {
        fd = open(path, O_RDONLY)
        self.total = total
        guard fd >= 0 else { return nil }
    }

    deinit { Darwin.close(fd) }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard count > 0, offset < total else { return nil }
        let bounded = min(UInt64(count), total - offset)
        guard bounded <= UInt64(Int.max) else { return nil }
        var data = Data(count: Int(bounded))
        let result = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(bounded), off_t(offset)) }
        guard result == Int(bounded) else { return nil }
        return data
    }
}

private func le16(_ data: Data, _ offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func le32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
}

private func appendExtent(_ extent: FileSystemExtent, to extents: inout [FileSystemExtent]) {
    if let last = extents.last, last.offset <= UInt64.max - last.length, last.offset + last.length == extent.offset {
        extents[extents.count - 1] = FileSystemExtent(offset: last.offset, length: last.length + extent.length)
    } else {
        extents.append(extent)
    }
}

private struct FAT32 {
    let reader: Reader
    let boot: Data
    let bytesPerSector: UInt64
    let clusterSize: UInt64
    let fatOffset: UInt64
    let fatCount: UInt64
    let sectorsPerFAT: UInt64
    let heapOffset: UInt64
    let rootCluster: UInt32

    init(reader: Reader, boot: Data) {
        self.reader = reader
        self.boot = boot
        bytesPerSector = UInt64(le16(boot, 11) ?? 0)
        clusterSize = bytesPerSector * UInt64(boot[13])
        let reservedSectors = UInt64(le16(boot, 14) ?? 0)
        let (fatStart, fatStartOverflow) = reservedSectors.multipliedReportingOverflow(by: bytesPerSector)
        fatOffset = fatStartOverflow ? UInt64.max : fatStart
        fatCount = UInt64(boot[16])
        sectorsPerFAT = UInt64(le32(boot, 36) ?? 0)
        let (singleFATBytes, singleFATOverflow) = sectorsPerFAT.multipliedReportingOverflow(by: bytesPerSector)
        let (allFATBytes, allFATOverflow) = fatCount.multipliedReportingOverflow(by: singleFATBytes)
        let (heap, heapOverflow) = fatOffset.addingReportingOverflow(allFATBytes)
        heapOffset = fatStartOverflow || singleFATOverflow || allFATOverflow || heapOverflow ? UInt64.max : heap
        rootCluster = le32(boot, 44) ?? 0
    }

    func deletedFiles() -> [DeletedFileRecord] {
        guard boot[510] == 0x55, boot[511] == 0xAA,
              bytesPerSector >= 512, bytesPerSector <= 4096,
              clusterSize >= bytesPerSector, clusterSize <= 1024 * 1024,
              boot[13] > 0, boot[13] & (boot[13] - 1) == 0,
              (le16(boot, 14) ?? 0) > 0, (1...4).contains(fatCount), sectorsPerFAT > 0,
              le16(boot, 17) == 0, le16(boot, 22) == 0,
              fatOffset < reader.total, heapOffset < reader.total, rootCluster >= 2 else { return [] }
        var result: [DeletedFileRecord] = []
        var pending = [rootCluster]
        var visited = Set<UInt32>()
        while let directoryCluster = pending.popLast(), visited.insert(directoryCluster).inserted, visited.count < 100_000 {
            let directory = readChain(start: directoryCluster, maximumBytes: 32 * 1024 * 1024)
            guard directory.count >= 32 else { continue }
            for base in stride(from: 0, through: directory.count - 32, by: 32) {
                let first = directory[base]
                if first == 0 { break }
                let attributes = directory[base + 11]
                if attributes == 0x0F || attributes & 0x08 != 0 { continue }
                let high = UInt32(le16(directory, base + 20) ?? 0)
                let low = UInt32(le16(directory, base + 26) ?? 0)
                let cluster = (high << 16) | low
                if first == 0xE5 {
                    let size = UInt64(le32(directory, base + 28) ?? 0)
                    if attributes & 0x10 == 0, cluster >= 2, size > 0,
                       let record = makeRecord(cluster: cluster, size: size, shortEntry: directory, base: base) {
                        result.append(record)
                    }
                    continue
                }
                guard cluster >= 2 else { continue }
                if attributes & 0x10 != 0 { pending.append(cluster) }
            }
        }
        return result
    }

    private func makeRecord(cluster: UInt32, size: UInt64, shortEntry: Data, base: Int) -> DeletedFileRecord? {
        guard let start = dataOffset(cluster), start < reader.total else { return nil }
        let extBytes = shortEntry[(base + 8)..<(base + 11)].filter { $0 != 0x20 && $0 != 0x00 }
        let ext = String(decoding: extBytes, as: UTF8.self).lowercased()
        guard size <= reader.total, let extents = extents(startCluster: cluster, size: size) else { return nil }
        let name = "Recovered_\(String(format: "%06llx", start))"
        return DeletedFileRecord(name: name, fileExtension: ext, offset: start, size: size, extents: extents.extents, isContiguousEstimate: extents.estimated)
    }

    private func extents(startCluster: UInt32, size: UInt64) -> (extents: [FileSystemExtent], estimated: Bool)? {
        let needed = size / clusterSize + (size % clusterSize == 0 ? 0 : 1)
        guard needed > 0, needed <= 1_000_000 else { return nil }
        var clusters = [startCluster]
        var visited: Set<UInt32> = [startCluster]
        var ended = false
        var estimated = false
        while UInt64(clusters.count) < needed {
            guard let next = nextCluster(clusters[clusters.count - 1]) else { ended = true; break }
            guard visited.insert(next).inserted else { return nil }
            clusters.append(next)
        }
        if UInt64(clusters.count) < needed {
            guard ended, fatEntry(startCluster) == 0 else { return nil }
            guard needed <= UInt64(UInt32.max - startCluster) + 1 else { return nil }
            clusters = (0..<Int(needed)).map { startCluster &+ UInt32($0) }
            estimated = true
        }
        var remaining = size
        var extents: [FileSystemExtent] = []
        for current in clusters.prefix(Int(needed)) {
            guard let offset = dataOffset(current) else { return nil }
            let length = min(clusterSize, remaining)
            guard offset <= reader.total, length <= reader.total - offset else { return nil }
            appendExtent(FileSystemExtent(offset: offset, length: length), to: &extents)
            remaining -= length
        }
        guard remaining == 0 else { return nil }
        return (extents, estimated)
    }

    private func fatEntry(_ cluster: UInt32) -> UInt32? {
        guard UInt64(cluster) < sectorsPerFAT * bytesPerSector / 4,
              let bytes = reader.read(fatOffset + UInt64(cluster) * 4, 4) else { return nil }
        return (le32(bytes, 0) ?? 0) & 0x0FFFFFFF
    }

    private func nextCluster(_ cluster: UInt32) -> UInt32? {
        guard let value = fatEntry(cluster), value >= 2, value < 0x0FFFFFF8 else { return nil }
        return value
    }

    private func dataOffset(_ cluster: UInt32) -> UInt64? {
        guard cluster >= 2 else { return nil }
        let (delta, overflow) = UInt64(cluster - 2).multipliedReportingOverflow(by: clusterSize)
        guard !overflow else { return nil }
        let (offset, addOverflow) = heapOffset.addingReportingOverflow(delta)
        return addOverflow ? nil : offset
    }

    private func readChain(start: UInt32, maximumBytes: Int) -> Data {
        var output = Data()
        var current: UInt32? = start
        var visited = Set<UInt32>()
        while let cluster = current, visited.insert(cluster).inserted, visited.count < 1_000_000,
              output.count < maximumBytes, let offset = dataOffset(cluster), let bytes = reader.read(offset, Int(clusterSize)) {
            output.append(bytes.prefix(maximumBytes - output.count))
            current = nextCluster(cluster)
        }
        return output
    }
}

private struct ExFAT {
    let reader: Reader
    let boot: Data
    let bytesPerSector: UInt64
    let clusterSize: UInt64
    let fatOffset: UInt64
    let heapOffset: UInt64
    let rootCluster: UInt32

    init(reader: Reader, boot: Data) {
        self.reader = reader
        self.boot = boot
        bytesPerSector = (9...12).contains(Int(boot[108])) ? UInt64(1) << UInt64(boot[108]) : 0
        let sectorsPerCluster = boot[109] <= 16 ? UInt64(1) << UInt64(boot[109]) : 0
        clusterSize = bytesPerSector * sectorsPerCluster
        fatOffset = UInt64(le32(boot, 80) ?? 0) * bytesPerSector
        heapOffset = UInt64(le32(boot, 88) ?? 0) * bytesPerSector
        rootCluster = le32(boot, 96) ?? 0
    }

    func deletedFiles() -> [DeletedFileRecord] {
        guard bytesPerSector >= 512, bytesPerSector <= 4096,
              clusterSize >= bytesPerSector, clusterSize <= 32 * 1024 * 1024, rootCluster >= 2 else { return [] }
        var result: [DeletedFileRecord] = []
        var pending = [rootCluster]
        var visited = Set<UInt32>()
        while let directoryCluster = pending.popLast(), visited.insert(directoryCluster).inserted, visited.count < 100_000 {
            let directory = readChain(start: directoryCluster, maximumBytes: 32 * 1024 * 1024)
            var index = 0
            while index + 32 <= directory.count {
                let type = directory[index]
                if type == 0 { break }
                guard type == 0x85 || type == 0x05 else {
                    if type & 0x7F == 0x05, directory[index + 1] & 0x02 != 0,
                       let child = le32(directory, index + 20), child >= 2 { pending.append(child) }
                    index += 32
                    continue
                }
                let secondaryCount = Int(directory[index + 1])
                let end = index + (secondaryCount + 1) * 32
                guard secondaryCount >= 2, end <= directory.count else { index += 32; continue }
                let deleted = type == 0x05
                var firstCluster: UInt32?
                var dataLength: UInt64 = 0
                var noFatChain = false
                var nameUnits: [UInt16] = []
                for secondary in stride(from: index + 32, to: end, by: 32) {
                    let secondaryType = directory[secondary]
                    if secondaryType == 0xC0 || secondaryType == 0x40 {
                        noFatChain = directory[secondary + 1] & 0x02 != 0
                        dataLength = UInt64(le64(directory, secondary + 24) ?? 0)
                        firstCluster = le32(directory, secondary + 20)
                    } else if secondaryType == 0xC1 || secondaryType == 0x41 {
                        for unitOffset in stride(from: 2, to: 32, by: 2) {
                            if let unit = le16(directory, secondary + unitOffset), unit != 0 { nameUnits.append(unit) }
                        }
                    }
                }
                if let cluster = firstCluster, cluster >= 2 {
                    if deleted, dataLength > 0,
                       let record = makeRecord(cluster: cluster, size: dataLength, noFatChain: noFatChain, nameUnits: nameUnits) {
                        result.append(record)
                    } else if directory[index + 4] & 0x10 != 0 {
                        pending.append(cluster)
                    }
                }
                index = end
            }
        }
        return result
    }

    private func makeRecord(cluster: UInt32, size: UInt64, noFatChain: Bool, nameUnits: [UInt16]) -> DeletedFileRecord? {
        guard let start = dataOffset(cluster), start < reader.total, size <= reader.total,
              let extents = extents(startCluster: cluster, size: size, noFatChain: noFatChain) else { return nil }
        let originalName = String(decoding: nameUnits, as: UTF16.self)
        let safeName = URL(fileURLWithPath: originalName).lastPathComponent
        let ext = (safeName as NSString).pathExtension.lowercased()
        let name = safeName.isEmpty ? "Recovered_\(String(format: "%06llx", start))" : (safeName as NSString).deletingPathExtension
        return DeletedFileRecord(name: name, fileExtension: ext, offset: start, size: size, extents: extents, isContiguousEstimate: false)
    }

    private func extents(startCluster: UInt32, size: UInt64, noFatChain: Bool) -> [FileSystemExtent]? {
        let needed = size / clusterSize + (size % clusterSize == 0 ? 0 : 1)
        guard needed > 0, needed <= 1_000_000 else { return nil }
        var clusters: [UInt32] = []
        if noFatChain {
            guard needed <= UInt64(UInt32.max - startCluster) + 1 else { return nil }
            clusters = (0..<Int(needed)).map { startCluster &+ UInt32($0) }
        } else {
            var current: UInt32? = startCluster
            var visited = Set<UInt32>()
            while let cluster = current, UInt64(clusters.count) < needed,
                  visited.insert(cluster).inserted, visited.count < 1_000_000 {
                clusters.append(cluster)
                current = nextCluster(cluster)
            }
            guard UInt64(clusters.count) == needed else { return nil }
        }
        var remaining = size
        var result: [FileSystemExtent] = []
        for cluster in clusters {
            guard let offset = dataOffset(cluster) else { return nil }
            let length = min(clusterSize, remaining)
            guard offset <= reader.total, length <= reader.total - offset else { return nil }
            appendExtent(FileSystemExtent(offset: offset, length: length), to: &result)
            remaining -= length
        }
        return remaining == 0 ? result : nil
    }

    private func nextCluster(_ cluster: UInt32) -> UInt32? {
        guard let bytes = reader.read(fatOffset + UInt64(cluster) * 4, 4), let value = le32(bytes, 0),
              value >= 2, value < 0xFFFFFFF8 else { return nil }
        return value
    }

    private func dataOffset(_ cluster: UInt32) -> UInt64? {
        guard cluster >= 2 else { return nil }
        let (delta, overflow) = UInt64(cluster - 2).multipliedReportingOverflow(by: clusterSize)
        guard !overflow else { return nil }
        let (offset, addOverflow) = heapOffset.addingReportingOverflow(delta)
        return addOverflow ? nil : offset
    }

    private func readChain(start: UInt32, maximumBytes: Int) -> Data {
        var output = Data()
        var current: UInt32? = start
        var visited = Set<UInt32>()
        while let cluster = current, visited.insert(cluster).inserted, visited.count < 1_000_000,
              output.count < maximumBytes, let offset = dataOffset(cluster), let bytes = reader.read(offset, Int(clusterSize)) {
            output.append(bytes.prefix(maximumBytes - output.count))
            current = nextCluster(cluster)
        }
        return output
    }
}

private func le64(_ data: Data, _ offset: Int) -> UInt64? {
    guard offset >= 0, offset + 8 <= data.count else { return nil }
    return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
}
