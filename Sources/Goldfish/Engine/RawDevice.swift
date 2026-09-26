import Foundation
import Darwin

/// Read-only access to a device node or disk image. Raw disk devices only
/// accept sector-aligned I/O, so reads on them are widened to whole sectors.
final class RawDevice: @unchecked Sendable {
    static let sectorSize: UInt64 = 512
    private static let copyChunkSize: UInt64 = 4 * 1024 * 1024

    let path: String
    let total: UInt64
    private let descriptor: Int32
    private let requiresSectorAlignment: Bool

    init(path: String, total: UInt64) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw RecoveryError.rawAccessRequired(path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw RecoveryError.readFailed(path, code)
        }
        let fileType = info.st_mode & S_IFMT
        self.path = path
        self.total = total
        self.descriptor = descriptor
        self.requiresSectorAlignment = fileType == S_IFCHR || fileType == S_IFBLK
    }

    deinit { close(descriptor) }

    /// Returns up to `count` bytes at `offset`; the result is shorter only at
    /// the end of the device.
    func read(at offset: UInt64, count: Int) throws -> Data {
        precondition(count >= 0, "Negative read count")
        guard count > 0, offset < total else { return Data() }
        let wanted = min(UInt64(count), total - offset)
        guard requiresSectorAlignment else { return try readBytes(at: offset, count: Int(wanted)) }

        let prefix = offset % Self.sectorSize
        let alignedOffset = offset - prefix
        let alignedEnd = (offset + wanted + Self.sectorSize - 1) / Self.sectorSize * Self.sectorSize
        let buffer = try readBytes(at: alignedOffset, count: Int(alignedEnd - alignedOffset))
        let lower = min(Int(prefix), buffer.count)
        let upper = min(buffer.count, lower + Int(wanted))
        if lower == 0 && upper == buffer.count { return buffer }
        return Data(buffer[lower..<upper])
    }

    /// Copies `ranges` in order into a new file at `destination`, failing if it
    /// already exists. The file is removed if the copy does not complete.
    func copy(_ ranges: [ScannedRange], size: UInt64, to destination: URL) throws {
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard output >= 0 else { throw RecoveryError.readFailed(destination.path, errno) }
        var completed = false
        defer {
            Darwin.close(output)
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }

        var copied: UInt64 = 0
        for range in ranges {
            var offset = range.start
            while offset < range.end {
                try Task.checkCancellation()
                let amount = Int(min(Self.copyChunkSize, range.end - offset))
                let chunk = try read(at: offset, count: amount)
                guard chunk.count == amount else { throw RecoveryError.incompleteRead(path, offset: offset + UInt64(chunk.count)) }
                try writeAll(chunk, to: output, path: destination.path)
                offset += UInt64(amount)
            }
            copied += range.end - range.start
        }
        guard copied == size else { throw RecoveryError.incompleteRead(path, offset: copied) }
        completed = true
    }

    private func readBytes(at offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, off_t(offset)) }
        guard result >= 0 else {
            let code = errno
            GoldfishLog.write("Raw read failed: path=\(path), offset=\(offset), count=\(count), errno=\(code)")
            // A bad sector and a removed card both report EIO, but macOS revokes
            // the descriptor of a removed device, so fstat on it then fails.
            var info = stat()
            if fstat(descriptor, &info) != 0 { throw RecoveryError.deviceDisconnected(path) }
            throw RecoveryError.readFailed(path, code)
        }
        if result < count { data.count = result }
        return data
    }

    private func writeAll(_ data: Data, to output: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(output, pointer, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw RecoveryError.readFailed(path, errno) }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }
}

/// Keeps recently read, chunk-aligned regions of the device so the scan loop
/// and the format parsers share reads: a parser that follows a file past the
/// current block leaves those chunks here for the scan loop to reuse. Owned by
/// a single scan worker.
final class ChunkCache {
    static let chunkSize: UInt64 = 4 * 1024 * 1024
    private static let capacity = 8

    let device: RawDevice
    private var chunks: [UInt64: Data] = [:]
    private var recentlyUsed: [UInt64] = []
    private var unreadableChunks: [UInt64: Error] = [:]

    init(device: RawDevice) {
        self.device = device
    }

    /// Same contract as `RawDevice.read(at:count:)`.
    func read(at offset: UInt64, count: Int) throws -> Data {
        precondition(count >= 0, "Negative read count")
        guard count > 0, offset < device.total else { return Data() }
        let end = min(device.total, offset + UInt64(count))
        let firstIndex = offset / Self.chunkSize
        let lastIndex = (end - 1) / Self.chunkSize
        var output = Data()
        for index in firstIndex...lastIndex {
            let chunk: Data
            do {
                chunk = try self.chunk(at: index)
            } catch {
                // A smaller read may avoid the unreadable sectors; a whole-chunk
                // read would only fail again.
                guard UInt64(count) < Self.chunkSize else { throw error }
                return try device.read(at: offset, count: count)
            }
            let chunkStart = index * Self.chunkSize
            let lower = Int(max(offset, chunkStart) - chunkStart)
            let upper = min(chunk.count, Int(end - chunkStart))
            if firstIndex == lastIndex, lower == 0, upper == chunk.count { return chunk }
            guard lower < upper else { break }
            output.append(chunk[lower..<upper])
            if chunk.count < Int(Self.chunkSize) { break }
        }
        return output
    }

    /// Drops chunks that end at or before `offset`. The scan loop calls this
    /// once it has moved past them, since parsers only read forward.
    func discard(below offset: UInt64) {
        chunks = chunks.filter { ($0.key + 1) * Self.chunkSize > offset }
        unreadableChunks = unreadableChunks.filter { ($0.key + 1) * Self.chunkSize > offset }
        recentlyUsed.removeAll { chunks[$0] == nil }
    }

    private func chunk(at index: UInt64) throws -> Data {
        if let chunk = chunks[index] {
            markUsed(index)
            return chunk
        }
        if let error = unreadableChunks[index] { throw error }
        let chunk: Data
        do {
            chunk = try device.read(at: index * Self.chunkSize, count: Int(Self.chunkSize))
        } catch {
            unreadableChunks[index] = error
            throw error
        }
        chunks[index] = chunk
        markUsed(index)
        if chunks.count > Self.capacity {
            chunks[recentlyUsed.removeFirst()] = nil
        }
        return chunk
    }

    private func markUsed(_ index: UInt64) {
        recentlyUsed.removeAll { $0 == index }
        recentlyUsed.append(index)
    }
}

/// A bounded view of the device starting at a candidate's first byte, used by
/// the format parsers. Read failures read as "no file here".
final class CarveReader {
    private let cache: ChunkCache
    private let base: UInt64
    let limit: UInt64

    init(cache: ChunkCache, base: UInt64, limit: UInt64) {
        self.cache = cache
        self.base = base
        self.limit = limit
    }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard count >= 0, offset <= limit, UInt64(count) <= limit - offset else { return nil }
        guard let data = try? cache.read(at: base + offset, count: count), data.count == count else { return nil }
        return data
    }

    func byte(_ offset: UInt64) -> UInt8? { read(offset, 1)?.first }
}
