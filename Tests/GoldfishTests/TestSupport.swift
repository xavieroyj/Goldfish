import Foundation
@testable import Goldfish

/// A temporary file standing in for a card. It is removed when released.
final class TemporaryImage {
    let url: URL

    init(_ data: Data = Data()) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("goldfish-test-\(UUID().uuidString)")
        try data.write(to: url)
    }

    /// A sparse image of `size` bytes holding `writes` at their offsets.
    convenience init(size: UInt64, writes: [(offset: UInt64, data: Data)]) throws {
        try self.init()
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        for write in writes {
            try handle.seek(toOffset: write.offset)
            try handle.write(contentsOf: write.data)
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var size: UInt64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0 }

    func rawDevice() throws -> RawDevice { try RawDevice(path: url.path, total: size) }

    func device(name: String = "Test") -> Device {
        Device(mountPath: url.path, name: name, path: url.path, isRemovable: true, isInternal: false, identifier: "test", size: size)
    }
}

/// A temporary folder, removed when released.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("goldfish-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

extension Data {
    mutating func putLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        for byte in 0..<MemoryLayout<T>.size { self[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }

    mutating func put(_ bytes: Data, at offset: Int) {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}

func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
func be32(_ value: UInt32) -> Data { Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
func be64(_ value: UInt64) -> Data { Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }

/// Deterministic pseudo-random bytes (xorshift64), so failures reproduce.
func noise(count: Int, seed: UInt64) -> Data {
    var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    var output = Data(count: count)
    for index in 0..<count {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        output[index] = UInt8(truncatingIfNeeded: state)
    }
    return output
}

/// A minimal baseline JPEG: SOI, frame header, scan header, scan data, EOI.
func minimalJPEG(scanData: Data = Data(repeating: 0x20, count: 220)) -> Data {
    let sof = Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
    let sos = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    return Data([0xFF, 0xD8]) + sof + sos + scanData + Data([0xFF, 0xD9])
}

func pngChunk(_ type: String, payload: Data) -> Data {
    be32(UInt32(payload.count)) + Data(type.utf8) + payload + Data(repeating: 0, count: 4)
}

func minimalPNG() -> Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        + pngChunk("IHDR", payload: Data(repeating: 0, count: 13))
        + pngChunk("IDAT", payload: Data(repeating: 0x31, count: 100))
        + pngChunk("IEND", payload: Data())
}

/// Runs one format parser over `data` as if a signature matched at its first byte.
func carvedSize(_ format: SignatureFormat, _ data: Data) throws -> UInt64? {
    let image = try TemporaryImage(data)
    let cache = ChunkCache(device: try image.rawDevice())
    return format.size(CarveReader(cache: cache, base: 0, limit: UInt64(data.count)))
}

/// A FAT32 image with 512-byte sectors and clusters: the FAT is sector 1,
/// cluster 2 (the root directory) starts at byte 1024, and cluster n at
/// 1024 + (n - 2) * 512. The FAT has room for 128 clusters.
struct FAT32Image {
    static let clusterSize = 512
    var bytes: Data

    init(clusters: Int) {
        bytes = Data(repeating: 0, count: 1024 + clusters * Self.clusterSize)
        bytes.putLE(UInt16(512), at: 11)
        bytes[13] = 1
        bytes.putLE(UInt16(1), at: 14)
        bytes[16] = 1
        bytes.putLE(UInt32(1), at: 36)
        bytes.putLE(UInt32(2), at: 44)
        bytes[510] = 0x55
        bytes[511] = 0xAA
        setFAT(2, 0x0FFF_FFFF)
    }

    static func offset(ofCluster cluster: Int) -> Int { 1024 + (cluster - 2) * clusterSize }

    mutating func setFAT(_ cluster: Int, _ value: UInt32) { bytes.putLE(value, at: 512 + cluster * 4) }

    /// Writes an 8.3 entry. `shortName` is the 11-character padded name.
    mutating func putShortEntry(at offset: Int, shortName: String, attributes: UInt8 = 0x20, cluster: Int, size: Int, deleted: Bool = false) {
        bytes.put(Data(shortName.utf8), at: offset)
        if deleted { bytes[offset] = 0xE5 }
        bytes[offset + 11] = attributes
        bytes.putLE(UInt16(cluster >> 16), at: offset + 20)
        bytes.putLE(UInt16(cluster & 0xFFFF), at: offset + 26)
        bytes.putLE(UInt32(size), at: offset + 28)
    }

    /// Writes the long-filename entries for `name` followed by its short entry,
    /// and returns the offset after them.
    @discardableResult
    mutating func putLongNameEntry(at offset: Int, name: String, shortName: String, cluster: Int, size: Int) -> Int {
        var units = Array(name.utf16)
        let partCount = (units.count + 12) / 13
        if units.count % 13 != 0 { units.append(0) }
        while units.count < partCount * 13 { units.append(0xFFFF) }
        let positions = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        var cursor = offset
        for part in (1...partCount).reversed() {
            bytes[cursor] = UInt8(part) | (part == partCount ? 0x40 : 0)
            bytes[cursor + 11] = 0x0F
            for (index, position) in positions.enumerated() {
                bytes.putLE(units[(part - 1) * 13 + index], at: cursor + position)
            }
            cursor += 32
        }
        putShortEntry(at: cursor, shortName: shortName, cluster: cluster, size: size)
        return cursor + 32
    }
}

/// An exFAT image with 512-byte sectors and clusters: the FAT is sector 1,
/// cluster 2 (the root directory) starts at byte 1024, and cluster n at
/// 1024 + (n - 2) * 512.
struct ExFATImage {
    static let clusterSize = 512
    var bytes: Data

    init(clusters: Int) {
        bytes = Data(repeating: 0, count: 1024 + clusters * Self.clusterSize)
        bytes.put(Data("EXFAT   ".utf8), at: 3)
        bytes.putLE(UInt32(1), at: 80)
        bytes.putLE(UInt32(2), at: 88)
        bytes.putLE(UInt32(2), at: 96)
        bytes[108] = 9
        bytes[109] = 0
        setFAT(2, 0xFFFF_FFFF)
    }

    static func offset(ofCluster cluster: Int) -> Int { 1024 + (cluster - 2) * clusterSize }

    mutating func setFAT(_ cluster: Int, _ value: UInt32) { bytes.putLE(value, at: 512 + cluster * 4) }

    /// Writes a file entry set (file, stream extension and one name entry) and
    /// returns the offset after it. Names must fit one name entry (15 units).
    @discardableResult
    mutating func putFileSet(at offset: Int, name: String, cluster: Int, length: Int, deleted: Bool = false, contiguous: Bool = true, directory: Bool = false) -> Int {
        let units = Array(name.utf16)
        precondition(units.count <= 15, "Test names must fit one exFAT name entry")
        let inUse: UInt8 = deleted ? 0 : 0x80
        bytes[offset] = 0x05 | inUse
        bytes[offset + 1] = 2
        if directory { bytes.putLE(UInt16(0x10), at: offset + 4) }
        let stream = offset + 32
        bytes[stream] = 0x40 | inUse
        bytes[stream + 1] = contiguous ? 0x03 : 0x01
        bytes[stream + 3] = UInt8(units.count)
        bytes.putLE(UInt32(cluster), at: stream + 20)
        bytes.putLE(UInt64(length), at: stream + 24)
        let nameEntry = offset + 64
        bytes[nameEntry] = 0x41 | inUse
        for (index, unit) in units.enumerated() { bytes.putLE(unit, at: nameEntry + 2 + index * 2) }
        return offset + 96
    }
}
