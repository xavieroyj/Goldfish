import Foundation
import Darwin

/// A best-effort, read-only index of names to the physical start of files on
/// FAT32 and exFAT volumes. The signature carver remains the source of file
/// bytes; this only supplements its generated names when directory metadata
/// provides an exact cluster-start match.
enum FileSystemNameIndex {
    static func namesByOffset(path: String, total: UInt64) -> [UInt64: String] {
        guard let reader = VolumeReader(path: path, total: total),
              let boot = reader.read(offset: 0, count: 512), boot.count >= 512 else { return [:] }
        if String(data: boot[3..<11], encoding: .ascii) == "EXFAT   " {
            return ExFATIndex(reader: reader, boot: boot).build()
        }
        return FAT32Index(reader: reader, boot: boot).build()
    }
}

private final class VolumeReader {
    let descriptor: Int32
    let total: UInt64

    init?(path: String, total: UInt64) {
        descriptor = open(path, O_RDONLY)
        self.total = total
        guard descriptor >= 0 else { return nil }
    }

    deinit { Darwin.close(descriptor) }

    func read(offset: UInt64, count: Int) -> Data? {
        guard count > 0, offset < total else { return nil }
        let bounded = min(count, Int(min(UInt64(Int.max), total - offset)))
        var data = Data(count: bounded)
        let readCount = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, bounded, off_t(offset)) }
        guard readCount > 0 else { return nil }
        if readCount != bounded { data = Data(data.prefix(readCount)) }
        return data
    }

    func close() { Darwin.close(descriptor) }
}

private func u16(_ data: Data, _ offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

private func u32(_ data: Data, _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
}

private struct FAT32Index {
    let reader: VolumeReader
    let boot: Data
    let bytesPerSector: UInt64
    let sectorsPerCluster: UInt64
    let reservedSectors: UInt64
    let fatCount: UInt64
    let sectorsPerFAT: UInt64
    let rootCluster: UInt32
    let clusterSize: UInt64
    let fatOffset: UInt64
    let heapOffset: UInt64

    init(reader: VolumeReader, boot: Data) {
        self.reader = reader
        self.boot = boot
        bytesPerSector = UInt64(u16(boot, 11) ?? 0)
        sectorsPerCluster = UInt64(boot[13])
        reservedSectors = UInt64(u16(boot, 14) ?? 0)
        fatCount = UInt64(boot[16])
        sectorsPerFAT = UInt64(u32(boot, 36) ?? 0)
        rootCluster = u32(boot, 44) ?? 0
        clusterSize = bytesPerSector * sectorsPerCluster
        fatOffset = reservedSectors * bytesPerSector
        heapOffset = fatOffset + fatCount * sectorsPerFAT * bytesPerSector
    }

    func build() -> [UInt64: String] {
        guard boot.count >= 512, boot[510] == 0x55, boot[511] == 0xAA,
              bytesPerSector >= 512, bytesPerSector <= 4096,
              sectorsPerCluster > 0, clusterSize > 0, sectorsPerFAT > 0,
              rootCluster >= 2 else { return [:] }
        var result: [UInt64: String] = [:]
        var pending = [rootCluster]
        var visitedDirectories = Set<UInt32>()
        while let cluster = pending.popLast(), visitedDirectories.insert(cluster).inserted, visitedDirectories.count < 100_000 {
            let bytes = readChain(start: cluster, maximumBytes: 32 * 1024 * 1024)
            var longNameParts: [Int: String] = [:]
            var expectedLongNameCount: Int?
            for base in stride(from: 0, to: bytes.count - 31, by: 32) {
                let first = bytes[base]
                if first == 0 { break }
                let attributes = bytes[base + 11]
                if attributes == 0x0F {
                    if first & 0x40 != 0 {
                        longNameParts.removeAll(keepingCapacity: true)
                        expectedLongNameCount = Int(first & 0x1F)
                    }
                    let index = Int(first & 0x1F)
                    if index > 0 { longNameParts[index] = decodeFATLongName(bytes, base) }
                    continue
                }
                if first == 0xE5 || attributes & 0x08 != 0 {
                    longNameParts.removeAll(keepingCapacity: true)
                    expectedLongNameCount = nil
                    continue
                }
                let clusterHigh = UInt32(u16(bytes, base + 20) ?? 0)
                let clusterLow = UInt32(u16(bytes, base + 26) ?? 0)
                let firstCluster = (clusterHigh << 16) | clusterLow
                let name: String
                if let expectedLongNameCount, longNameParts.count == expectedLongNameCount {
                    name = (1...expectedLongNameCount).compactMap { longNameParts[$0] }.joined()
                } else {
                    name = decodeShortName(bytes, base)
                }
                longNameParts.removeAll(keepingCapacity: true)
                expectedLongNameCount = nil
                guard !name.isEmpty, name != ".", name != "..", firstCluster >= 2 else { continue }
                if attributes & 0x10 != 0 {
                    pending.append(firstCluster)
                } else if let offset = dataOffset(firstCluster) {
                    result[offset] = name
                }
            }
        }
        return result
    }

    private func dataOffset(_ cluster: UInt32) -> UInt64? {
        guard cluster >= 2 else { return nil }
        return heapOffset + UInt64(cluster - 2) * clusterSize
    }

    private func nextCluster(_ cluster: UInt32) -> UInt32? {
        guard let bytes = reader.read(offset: fatOffset + UInt64(cluster) * 4, count: 4),
              let value = u32(bytes, 0), value >= 2, value < 0x0FFFFFF8 else { return nil }
        return value & 0x0FFFFFFF
    }

    private func readChain(start: UInt32, maximumBytes: Int) -> Data {
        var output = Data()
        var cluster: UInt32? = start
        var visited = Set<UInt32>()
        while let current = cluster, visited.insert(current).inserted,
              output.count < maximumBytes, visited.count < 1_000_000,
              let offset = dataOffset(current), let data = reader.read(offset: offset, count: Int(clusterSize)) {
            output.append(data)
            cluster = nextCluster(current)
        }
        return output
    }

    private func decodeFATLongName(_ data: Data, _ base: Int) -> String {
        let positions = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        let units = positions.compactMap { u16(data, base + $0) }.prefix { $0 != 0 && $0 != 0xFFFF }
        return String(decoding: units, as: UTF16.self)
    }

    private func decodeShortName(_ data: Data, _ base: Int) -> String {
        let stem = String(decoding: data[base..<(base + 8)].prefix { $0 != 0x20 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let ext = String(decoding: data[(base + 8)..<(base + 11)].prefix { $0 != 0x20 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}

private struct ExFATIndex {
    let reader: VolumeReader
    let boot: Data
    let bytesPerSector: UInt64
    let clusterSize: UInt64
    let fatOffset: UInt64
    let clusterHeapOffset: UInt64
    let rootCluster: UInt32

    init(reader: VolumeReader, boot: Data) {
        self.reader = reader
        self.boot = boot
        bytesPerSector = (9...12).contains(Int(boot[108])) ? UInt64(1) << UInt64(boot[108]) : 0
        let sectorsPerCluster = boot[109] <= 16 ? UInt64(1) << UInt64(boot[109]) : 0
        clusterSize = bytesPerSector * sectorsPerCluster
        fatOffset = UInt64(u32(boot, 80) ?? 0) * bytesPerSector
        clusterHeapOffset = UInt64(u32(boot, 88) ?? 0) * bytesPerSector
        rootCluster = u32(boot, 96) ?? 0
    }

    func build() -> [UInt64: String] {
        guard boot.count >= 512, bytesPerSector >= 512, bytesPerSector <= 4096,
              clusterSize >= bytesPerSector, clusterSize <= 32 * 1024 * 1024, rootCluster >= 2 else { return [:] }
        var result: [UInt64: String] = [:]
        var pending = [rootCluster]
        var visited = Set<UInt32>()
        while let cluster = pending.popLast(), visited.insert(cluster).inserted, visited.count < 100_000 {
            let directory = readChain(start: cluster, maximumBytes: 32 * 1024 * 1024)
            var index = 0
            while index + 32 <= directory.count {
                let type = directory[index]
                if type == 0 { break }
                // File entry sets can be active (0x85) or deleted (0x05); the
                // secondary records retain the stream and UTF-16 filename.
                guard type == 0x85 || type == 0x05 else {
                    if type & 0x7F == 0x05, directory[index + 1] & 0x02 != 0,
                       let child = u32(directory, index + 20), child >= 2 { pending.append(child) }
                    index += 32
                    continue
                }
                let secondaryCount = Int(directory[index + 1])
                let end = index + (secondaryCount + 1) * 32
                guard secondaryCount >= 2, end <= directory.count else { index += 32; continue }
                var firstCluster: UInt32?
                var nameUnits: [UInt16] = []
                for secondary in stride(from: index + 32, to: end, by: 32) {
                    let secondaryType = directory[secondary]
                    if secondaryType == 0xC0 || secondaryType == 0x40 {
                        firstCluster = u32(directory, secondary + 20)
                    } else if secondaryType == 0xC1 || secondaryType == 0x41 {
                        for unitOffset in stride(from: 2, to: 32, by: 2) {
                            if let unit = u16(directory, secondary + unitOffset), unit != 0 { nameUnits.append(unit) }
                        }
                    }
                }
                let name = String(decoding: nameUnits, as: UTF16.self)
                if let firstCluster, firstCluster >= 2, !name.isEmpty {
                    if directory[index + 4] & 0x10 != 0 { pending.append(firstCluster) }
                    else if let offset = dataOffset(firstCluster) { result[offset] = name }
                }
                index = end
            }
        }
        return result
    }

    private func dataOffset(_ cluster: UInt32) -> UInt64? {
        guard cluster >= 2 else { return nil }
        return clusterHeapOffset + UInt64(cluster - 2) * clusterSize
    }

    private func nextCluster(_ cluster: UInt32) -> UInt32? {
        guard let bytes = reader.read(offset: fatOffset + UInt64(cluster) * 4, count: 4),
              let value = u32(bytes, 0), value >= 2, value < 0xFFFFFFF8 else { return nil }
        return value
    }

    private func readChain(start: UInt32, maximumBytes: Int) -> Data {
        var output = Data()
        var cluster: UInt32? = start
        var visited = Set<UInt32>()
        while let current = cluster, visited.insert(current).inserted,
              output.count < maximumBytes, visited.count < 1_000_000,
              let offset = dataOffset(current), let data = reader.read(offset: offset, count: Int(clusterSize)) {
            output.append(data)
            cluster = nextCluster(current)
        }
        return output
    }
}
