import Foundation
import Darwin
import ImageIO
import CoreGraphics

fileprivate enum RecoveredPayload: Hashable, Sendable {
    case memory(Data)
    case staged(URL)
}

fileprivate enum RecoveryStaging {
    static var processDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Goldfish-Recovery-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    static func prepare() -> URL? {
        let directory = processDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            atexit {
                try? FileManager.default.removeItem(at: RecoveryStaging.processDirectory)
            }
            return directory
        } catch {
            return nil
        }
    }

    static func store(_ data: Data, in directory: URL?) -> RecoveredPayload {
        guard let directory else { return .memory(data) }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("recovered")
        do {
            // The staging filename is unique and the directory is disposable, so
            // an atomic write only adds a second full-file write and rename.
            try data.write(to: url)
            return .staged(url)
        } catch {
            return .memory(data)
        }
    }

    static func store(device: RawDevice, offset: UInt64, size: UInt64, in directory: URL?) throws -> RecoveredPayload {
        guard let directory else {
            guard size <= UInt64(Int.max) else { throw RecoveryError.cannotRead }
            let data = try device.read(at: offset, count: Int(size))
            guard UInt64(data.count) == size else { throw RecoveryError.cannotRead }
            return .memory(data)
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("recovered")
        do {
            try device.copy(at: offset, size: size, to: url)
            return .staged(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func store(device: RawDevice, extents: [FileSystemExtent], size: UInt64, in directory: URL?) throws -> RecoveredPayload {
        guard let directory else {
            guard size <= UInt64(Int.max) else { throw RecoveryError.cannotRead }
            var data = Data()
            for extent in extents {
                guard extent.length <= UInt64(Int.max), extent.length <= size - UInt64(data.count) else { throw RecoveryError.cannotRead }
                data.append(try device.read(at: extent.offset, count: Int(extent.length)))
            }
            guard UInt64(data.count) == size else { throw RecoveryError.cannotRead }
            return .memory(data)
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("recovered")
        let output = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw RecoveryError.readFailed(url.path, errno) }
        var shouldRemove = true
        defer {
            Darwin.close(output)
            if shouldRemove { try? FileManager.default.removeItem(at: url) }
        }
        var copied: UInt64 = 0
        for extent in extents {
            var extentCopied: UInt64 = 0
            while extentCopied < extent.length {
                try Task.checkCancellation()
                let amount = Int(min(UInt64(4 * 1024 * 1024), extent.length - extentCopied))
                let chunk = try device.read(at: extent.offset + extentCopied, count: amount)
                guard chunk.count == amount else { throw RecoveryError.cannotRead }
                try chunk.withUnsafeBytes { rawBuffer in
                    guard var pointer = rawBuffer.baseAddress else { return }
                    var remaining = rawBuffer.count
                    while remaining > 0 {
                        let written = Darwin.write(output, pointer, remaining)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw RecoveryError.readFailed(url.path, errno) }
                        remaining -= written
                        pointer = pointer.advanced(by: written)
                    }
                }
                extentCopied += UInt64(chunk.count)
                copied += UInt64(chunk.count)
            }
        }
        guard copied == size else { throw RecoveryError.cannotRead }
        shouldRemove = false
        return .staged(url)
    }

    static func removeUnretainedFiles(in directory: URL?, keeping files: [RecoveredFile]) {
        guard let directory else { return }
        let retained = Set(files.compactMap(\.stagedFileURL).map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where !retained.contains(url.standardizedFileURL.resolvingSymlinksInPath()) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

public struct RecoveredFile: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var name: String
    public let kind: FileKind
    public let offset: UInt64
    public let size: UInt64
    public let recoverySource: RecoverySource
    public var fileExtension: String
    public let metadata: [String: String]
    public let physicalRanges: [ScannedRange]
    public var isFragmented: Bool? { recoverySource == .deletedFileRecord ? physicalRanges.count > 1 : nil }
    public let embeddedThumbnailData: Data?
    public let embeddedThumbnailOffset: UInt64?
    private let payload: RecoveredPayload
    public var data: Data {
        switch payload {
        case .memory(let data): data
        case .staged(let url): (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        }
    }
    var stagedFileURL: URL? {
        if case .staged(let url) = payload { return url }
        return nil
    }

    init(name: String, kind: FileKind, offset: UInt64, size: UInt64, recoverySource: RecoverySource, data: Data, fileExtension: String, stagingDirectory: URL?, metadata: [String: String] = [:], physicalRanges: [ScannedRange] = [], embeddedThumbnailData: Data? = nil, embeddedThumbnailOffset: UInt64? = nil) {
        self.name = name
        self.kind = kind
        self.offset = offset
        self.size = size
        self.recoverySource = recoverySource
        self.fileExtension = fileExtension
        self.metadata = metadata
        self.physicalRanges = Self.normalizedRanges(physicalRanges, offset: offset, size: size)
        self.embeddedThumbnailData = embeddedThumbnailData
        self.embeddedThumbnailOffset = embeddedThumbnailOffset
        self.payload = RecoveryStaging.store(data, in: stagingDirectory)
    }

    fileprivate init(name: String, kind: FileKind, offset: UInt64, size: UInt64, recoverySource: RecoverySource, fileExtension: String, payload: RecoveredPayload, metadata: [String: String] = [:], physicalRanges: [ScannedRange] = [], embeddedThumbnailData: Data? = nil, embeddedThumbnailOffset: UInt64? = nil) {
        self.name = name
        self.kind = kind
        self.offset = offset
        self.size = size
        self.recoverySource = recoverySource
        self.fileExtension = fileExtension
        self.metadata = metadata
        self.physicalRanges = Self.normalizedRanges(physicalRanges, offset: offset, size: size)
        self.embeddedThumbnailData = embeddedThumbnailData
        self.embeddedThumbnailOffset = embeddedThumbnailOffset
        self.payload = payload
    }

    public func write(to destination: URL) throws {
        if let stagedFileURL, !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: stagedFileURL, to: destination)
        } else {
            try data.write(to: destination)
        }
    }

    mutating func applyOriginalFilename(_ filename: String) {
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { return }
        let originalExtension = (safeName as NSString).pathExtension
        name = (safeName as NSString).deletingPathExtension
        if !originalExtension.isEmpty { fileExtension = originalExtension.lowercased() }
    }

    public var sizeDescription: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    private static func normalizedRanges(_ ranges: [ScannedRange], offset: UInt64, size: UInt64) -> [ScannedRange] {
        guard !ranges.isEmpty else {
            let end = offset.addingReportingOverflow(size)
            return [ScannedRange(start: offset, end: end.overflow ? UInt64.max : end.partialValue)]
        }
        return ranges
    }

    public static func == (lhs: RecoveredFile, rhs: RecoveredFile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum RecoverySource: String, Sendable {
    case signatureScan
    case deletedFileRecord
    case filesystemContiguousEstimate

    var label: String {
        switch self {
        case .signatureScan: "Signature found"
        case .deletedFileRecord: "Deleted file record"
        case .filesystemContiguousEstimate: "Deleted record · data order assumed"
        }
    }
}

enum PhotoMetadataExtractor {
    static func extract(from data: Data) -> [String: String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var result: [String: String] = [:]
        func add(_ label: String, _ value: Any?) {
            guard let value else { return }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result[label] = text }
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        add("Dimensions", dimensions(width: properties[kCGImagePropertyPixelWidth], height: properties[kCGImagePropertyPixelHeight]))
        add("Camera make", tiff[kCGImagePropertyTIFFMake])
        add("Camera model", tiff[kCGImagePropertyTIFFModel])
        add("Captured", exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime])
        add("Lens", exif[kCGImagePropertyExifLensModel])
        add("Focal length", exif[kCGImagePropertyExifFocalLength].map { "\($0) mm" })
        add("Exposure", exif[kCGImagePropertyExifExposureTime].map { "\($0) s" })
        add("Aperture", exif[kCGImagePropertyExifFNumber].map { "f/\($0)" })
        add("ISO", exif[kCGImagePropertyExifISOSpeedRatings])
        return result
    }

    private static func dimensions(width: Any?, height: Any?) -> String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }
}

public enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case image = "Photos", video = "Videos", document = "Documents", audio = "Audio", raw = "Camera RAW", unknown = "Other"
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .image: "photo"; case .video: "film"; case .document: "doc.text"; case .audio: "waveform"; case .raw: "camera.aperture"; case .unknown: "doc" }
    }

    static func from(fileExtension: String) -> FileKind {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "tif", "tiff", "heic", "heif", "bmp", "webp": .image
        case "mp4", "m4v", "mov", "mkv", "avi", "mts", "m2ts": .video
        case "pdf", "doc", "docx", "txt", "rtf": .document
        case "wav", "mp3", "m4a", "aac", "flac", "aiff": .audio
        case "nef", "cr2", "cr3", "arw", "dng", "orf", "rw2", "raw": .raw
        default: .unknown
        }
    }
}

public struct Device: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let isRemovable: Bool
    public let isInternal: Bool
    public let isReadOnly: Bool
    public let identifier: String
    public let size: UInt64

    public init(id: String, name: String, path: String, isRemovable: Bool, isReadOnly: Bool, identifier: String = "", size: UInt64 = 0, isInternal: Bool = false) {
        self.id = id; self.name = name; self.path = path; self.isRemovable = isRemovable; self.isInternal = isInternal; self.isReadOnly = isReadOnly; self.identifier = identifier; self.size = size
    }

    public var sizeDescription: String { size == 0 ? "Size unavailable" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

public enum RecoveryError: LocalizedError {
    case noVolume, cannotRead, rawAccessRequired(String), readFailed(String, Int32), cancelled

    public var errorDescription: String? {
        switch self {
        case .noVolume: "No removable storage was found."
        case .cannotRead: "The selected storage could not be opened."
        case .rawAccessRequired(let path): "macOS still cannot open the SD-card device at \(path). The card was not changed. Full Disk Access and device permissions are separate."
        case .readFailed(let path, let code): "Reading \(path) failed with system error \(code) (\(String(cString: strerror(code)))). The card was not changed."
        case .cancelled: "Scan cancelled."
        }
    }
}

public struct ScanProgress: Sendable {
    public let bytesRead: UInt64
    public let total: UInt64
    public let found: Int
    public let scannedRanges: [ScannedRange]
    public let candidateRanges: [ScannedRange]
    public let readErrors: [ScannedRange]
    public let bytesPerSecond: Double?
    public let estimatedSecondsRemaining: Double?
    public var fraction: Double { total == 0 ? 0 : min(1, Double(bytesRead) / Double(total)) }

    public var scannedWithoutCandidates: [ScannedRange] {
        var output: [ScannedRange] = []
        for scanned in scannedRanges {
            var cursor = scanned.start
            for candidate in candidateRanges where candidate.end > cursor && candidate.start < scanned.end {
                if candidate.start > cursor { output.append(ScannedRange(start: cursor, end: min(candidate.start, scanned.end))) }
                cursor = max(cursor, candidate.end)
                if cursor >= scanned.end { break }
            }
            if cursor < scanned.end { output.append(ScannedRange(start: cursor, end: scanned.end)) }
        }
        return output
    }

    public var unscannedRanges: [ScannedRange] {
        var covered = scannedRanges + readErrors
        covered.sort { $0.start < $1.start }
        var merged: [ScannedRange] = []
        for range in covered {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = ScannedRange(start: last.start, end: max(last.end, range.end))
            } else if range.end > range.start {
                merged.append(range)
            }
        }
        var output: [ScannedRange] = []
        var cursor: UInt64 = 0
        for range in merged where range.start < total {
            if range.start > cursor { output.append(ScannedRange(start: cursor, end: min(range.start, total))) }
            cursor = max(cursor, min(range.end, total))
        }
        if cursor < total { output.append(ScannedRange(start: cursor, end: total)) }
        return output
    }

    public init(bytesRead: UInt64, total: UInt64, found: Int, scannedRanges: [ScannedRange] = [], candidateRanges: [ScannedRange] = [], readErrors: [ScannedRange] = [], bytesPerSecond: Double? = nil, estimatedSecondsRemaining: Double? = nil) {
        self.bytesRead = bytesRead
        self.total = total
        self.found = found
        self.scannedRanges = scannedRanges
        self.candidateRanges = candidateRanges
        self.readErrors = readErrors
        self.bytesPerSecond = bytesPerSecond
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }
}

public struct ScannedRange: Hashable, Sendable {
    /// Inclusive starting byte offset.
    public let start: UInt64
    /// Exclusive ending byte offset.
    public let end: UInt64

    public init(start: UInt64, end: UInt64) {
        self.start = start
        self.end = end
    }
}

private struct Signature: Sendable {
    let marker: [UInt8]
    let kind: FileKind
    let ext: String
    let minSize: UInt64
    let maxSize: UInt64
    let startAdjustment: UInt64

    init(bytes: [UInt8], kind: FileKind, ext: String, minSize: UInt64, maxSize: UInt64, startAdjustment: UInt64 = 0) {
        self.marker = bytes
        self.kind = kind
        self.ext = ext
        self.minSize = minSize
        self.maxSize = maxSize
        self.startAdjustment = startAdjustment
    }
}

fileprivate final class RawDevice: @unchecked Sendable {
    let descriptor: Int32
    let path: String
    let total: UInt64

    init(path: String, total: UInt64 = 0) throws {
        self.path = path
        self.total = total
        descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw RecoveryError.rawAccessRequired(path) }
    }

    deinit { close(descriptor) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        // Raw disk devices require sector-aligned I/O. Round the request up
        // to the card's 512-byte sector size; regular files simply return EOF
        // earlier, which is harmless.
        let sectorSize = 512
        let prefix = Int(offset % UInt64(sectorSize))
        let alignedOffset = offset - UInt64(prefix)
        let alignedCount = max(sectorSize, ((prefix + count + sectorSize - 1) / sectorSize) * sectorSize)
        if total > 0, alignedOffset >= total { return Data() }
        let cappedCount = total > 0 ? min(alignedCount, Int((total - alignedOffset) / UInt64(sectorSize) * UInt64(sectorSize))) : alignedCount
        if cappedCount == 0 { return Data() }
        var data = Data(count: cappedCount)
        let result = data.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, cappedCount, off_t(alignedOffset))
        }
        if result == 0 { return Data() }
        guard result > 0 else {
            GoldfishLog.write("Raw read failed: path=\(path), offset=\(offset), requested=\(count), alignedOffset=\(alignedOffset), aligned=\(alignedCount), errno=\(errno)")
            throw RecoveryError.readFailed(path, errno)
        }
        let validCount = min(Int(result), cappedCount)
        let lower = min(prefix, validCount)
        let upper = min(validCount, lower + count)
        if lower == 0 && upper == data.count { return data }
        return Data(data[lower..<upper])
    }

    func copy(at offset: UInt64, size: UInt64, to destination: URL) throws {
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw RecoveryError.readFailed(destination.path, errno) }
        var shouldRemove = true
        defer {
            Darwin.close(output)
            if shouldRemove { try? FileManager.default.removeItem(at: destination) }
        }

        var copied: UInt64 = 0
        let chunkSize = 4 * 1024 * 1024
        while copied < size {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(chunkSize), size - copied))
            let chunk = try read(at: offset + copied, count: requested)
            guard chunk.count == requested else { throw RecoveryError.cannotRead }
            try chunk.withUnsafeBytes { rawBuffer in
                guard var pointer = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(output, pointer, remaining)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw RecoveryError.readFailed(destination.path, errno) }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
            copied += UInt64(chunk.count)
        }
        shouldRemove = false
    }
}

fileprivate final class CarveReader {
    private let device: RawDevice
    private let base: UInt64
    let limit: UInt64
    private var cacheStart: UInt64 = 0
    private var cache = Data()

    init(device: RawDevice, base: UInt64, limit: UInt64) {
        self.device = device
        self.base = base
        self.limit = limit
    }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard count >= 0, offset <= limit, UInt64(count) <= limit - offset else { return nil }
        let end = offset + UInt64(count)
        let cacheEnd = cacheStart + UInt64(cache.count)
        if offset >= cacheStart, end <= cacheEnd {
            let lower = Int(offset - cacheStart)
            return Data(cache[lower..<(lower + count)])
        }
        let request = Int(min(limit - offset, UInt64(max(count, 64 * 1024))))
        guard let data = try? device.read(at: base + offset, count: request), data.count >= count else { return nil }
        cacheStart = offset
        cache = data
        return Data(data.prefix(count))
    }

    func byte(_ offset: UInt64) -> UInt8? { read(offset, 1)?.first }
}

private struct RangeResult: Sendable {
    let files: [RecoveredFile]
}

private actor ScanProgressReporter {
    private var bytesRead: UInt64 = 0
    private var found: Int = 0
    private var scannedRanges: [ScannedRange] = []
    private var candidateRanges: [ScannedRange] = []
    private var readErrors: [ScannedRange] = []
    private var candidateOffsets = Set<UInt64>()
    private var lastSampleAt = DispatchTime.now().uptimeNanoseconds
    private var lastSampleBytes: UInt64 = 0
    private var smoothedBytesPerSecond: Double?

    func addBytes(_ bytes: UInt64, at offset: UInt64, total: UInt64) -> ScanProgress {
        bytesRead = min(total, bytesRead + bytes)
        insert(ScannedRange(start: offset, end: min(total, offset + bytes)))
        updateSpeed()
        return snapshot(total: total)
    }

    func addCandidate(_ file: RecoveredFile, total: UInt64) -> ScanProgress? {
        guard candidateOffsets.insert(file.offset).inserted else { return nil }
        found += 1
        for range in file.physicalRanges {
            insert(ScannedRange(start: range.start, end: min(total, range.end)), into: &candidateRanges)
        }
        return snapshot(total: total)
    }

    func addReadError(_ range: ScannedRange, total: UInt64) -> ScanProgress {
        insert(ScannedRange(start: range.start, end: min(total, range.end)), into: &readErrors)
        return snapshot(total: total)
    }

    func addRecoveredFiles(_ files: [RecoveredFile], total: UInt64) -> ScanProgress {
        for file in files where candidateOffsets.insert(file.offset).inserted {
            found += 1
            for range in file.physicalRanges {
                insert(ScannedRange(start: range.start, end: min(total, range.end)), into: &candidateRanges)
            }
        }
        return snapshot(total: total)
    }

    private func snapshot(total: UInt64) -> ScanProgress {
        let eta = smoothedBytesPerSecond.flatMap { rate in
            rate > 0 ? Double(total > bytesRead ? total - bytesRead : 0) / rate : nil
        }
        return ScanProgress(bytesRead: bytesRead, total: total, found: found, scannedRanges: scannedRanges, candidateRanges: candidateRanges, readErrors: readErrors, bytesPerSecond: smoothedBytesPerSecond, estimatedSecondsRemaining: eta)
    }

    private func insert(_ range: ScannedRange) {
        insert(range, into: &scannedRanges)
    }

    private func insert(_ range: ScannedRange, into target: inout [ScannedRange]) {
        guard range.end > range.start else { return }
        var merged = range
        var output: [ScannedRange] = []
        var inserted = false
        for existing in target {
            if existing.end < merged.start {
                output.append(existing)
            } else if merged.end < existing.start {
                if !inserted { output.append(merged); inserted = true }
                output.append(existing)
            } else {
                merged = ScannedRange(start: min(merged.start, existing.start), end: max(merged.end, existing.end))
            }
        }
        if !inserted { output.append(merged) }
        target = output
    }

    private func updateSpeed() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - lastSampleAt) / 1_000_000_000
        guard elapsed >= 0.25 else { return }
        let delta = bytesRead >= lastSampleBytes ? bytesRead - lastSampleBytes : 0
        let rate = Double(delta) / elapsed
        smoothedBytesPerSecond = smoothedBytesPerSecond.map { $0 * 0.7 + rate * 0.3 } ?? rate
        lastSampleAt = now
        lastSampleBytes = bytesRead
    }
}

public actor RecoveryEngine {
    private var cancelled = false
    private var previousStagingDirectory: URL?
    private static let signatures: [Signature] = [
        Signature(bytes: [0xFF,0xD8,0xFF], kind: .image, ext: "jpg", minSize: 128, maxSize: 50_000_000),
        Signature(bytes: [0x49,0x49,0x2A,0x00], kind: .raw, ext: "raw", minSize: 256, maxSize: 200_000_000),
        Signature(bytes: [0x4D,0x4D,0x00,0x2A], kind: .raw, ext: "raw", minSize: 256, maxSize: 200_000_000),
        Signature(bytes: [0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A], kind: .image, ext: "png", minSize: 128, maxSize: 100_000_000),
        Signature(bytes: [0x47,0x49,0x46,0x38], kind: .image, ext: "gif", minSize: 64, maxSize: 100_000_000),
        Signature(bytes: [0x25,0x50,0x44,0x46], kind: .document, ext: "pdf", minSize: 64, maxSize: 200_000_000),
        Signature(bytes: [0x1A,0x45,0xDF,0xA3], kind: .video, ext: "mkv", minSize: 1024, maxSize: 4_000_000_000),
        Signature(bytes: [0x66,0x74,0x79,0x70], kind: .video, ext: "mp4", minSize: 1024, maxSize: 4_000_000_000, startAdjustment: 4)
    ]
    private static let signatureOverlap = signatures.map(\.marker.count).max()! - 1

    public init() {}
    public func cancel() { cancelled = true }

    public func scan(device: Device, progress: @escaping @Sendable (ScanProgress) async -> Void, onCandidate: @escaping @Sendable (RecoveredFile) async -> Void = { _ in }) async throws -> [RecoveredFile] {
        cancelled = false
        let scanStart = DispatchTime.now().uptimeNanoseconds
        let total = device.size > 0 ? device.size : Self.fileSize(at: device.path)
        guard total > 0 else { throw RecoveryError.cannotRead }
        if let previousStagingDirectory { try? FileManager.default.removeItem(at: previousStagingDirectory) }
        let stagingDirectory = RecoveryStaging.prepare()
        previousStagingDirectory = stagingDirectory

        // Keep each range large enough to amortize task setup, but use several
        // descriptors so the SD reader can service independent requests in parallel.
        let rangeSize = UInt64(64 * 1024 * 1024)
        let ranges = (0..<Int((total + rangeSize - 1) / rangeSize)).map { index in
            let start = UInt64(index) * rangeSize
            return RangeResultPlaceholder(start: start, end: min(total, start + rangeSize))
        }
        let workerLimit = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        GoldfishLog.write("Parallel scan starting: \(ranges.count) ranges, worker limit \(workerLimit)")

        var allFiles: [RecoveredFile] = []
        var allOffsets = Set<UInt64>()
        let reporter = ScanProgressReporter()
        try await withThrowingTaskGroup(of: RangeResult.self) { group in
            var next = 0
            while next < min(workerLimit, ranges.count) {
                let item = ranges[next]
                group.addTask {
                    try await Self.scanRange(path: device.path, start: item.start, end: item.end, total: total, stagingDirectory: stagingDirectory, onReadError: { range in
                        let p = await reporter.addReadError(range, total: total)
                        await progress(p)
                    }) { offset, bytes in
                        let p = await reporter.addBytes(bytes, at: offset, total: total)
                        await progress(p)
                    } onCandidate: { file in
                        if let p = await reporter.addCandidate(file, total: total) {
                            await progress(p)
                            await onCandidate(file)
                        }
                    }
                }
                next += 1
            }

            while let result = try await group.next() {
                for file in result.files where allOffsets.insert(file.offset).inserted {
                    allFiles.append(file)
                }

                if next < ranges.count {
                    let item = ranges[next]
                    group.addTask {
                    try await Self.scanRange(path: device.path, start: item.start, end: item.end, total: total, stagingDirectory: stagingDirectory, onReadError: { range in
                        let p = await reporter.addReadError(range, total: total)
                        await progress(p)
                    }) { offset, bytes in
                        let p = await reporter.addBytes(bytes, at: offset, total: total)
                        await progress(p)
                    } onCandidate: { file in
                        if let p = await reporter.addCandidate(file, total: total) {
                                await progress(p)
                                await onCandidate(file)
                            }
                        }
                    }
                    next += 1
                }
            }
        }

        if cancelled || Task.isCancelled { throw RecoveryError.cancelled }
        let detectedCandidateCount = allFiles.count
        let namesByOffset = FileSystemNameIndex.namesByOffset(path: device.path, total: total)
        for index in allFiles.indices {
            if let originalName = namesByOffset[allFiles[index].offset] {
                allFiles[index].applyOriginalFilename(originalName)
            }
        }
        let deletedRecords = FileSystemRecoveryIndex.deletedFiles(path: device.path, total: total)
        let deviceReader = try RawDevice(path: device.path, total: device.path.hasPrefix("/dev/") ? total : 0)
        for record in deletedRecords {
            if let existing = allFiles.firstIndex(where: { $0.offset == record.offset }) {
                let originalName = record.fileExtension.isEmpty ? record.name : "\(record.name).\(record.fileExtension)"
                allFiles[existing].applyOriginalFilename(originalName)
                continue
            }
            guard allOffsets.insert(record.offset).inserted else { continue }
            do {
                let payload = try RecoveryStaging.store(device: deviceReader, extents: record.extents, size: record.size, in: stagingDirectory)
                let kind = FileKind.from(fileExtension: record.fileExtension)
                let metadata: [String: String]
                if (kind == .image || kind == .raw), record.size > 0 {
                    let headerSize = Int(min(record.size, 2 * 1024 * 1024))
                    metadata = (try? deviceReader.read(at: record.offset, count: headerSize)).map(PhotoMetadataExtractor.extract(from:)) ?? [:]
                } else {
                    metadata = [:]
                }
                allFiles.append(RecoveredFile(
                    name: record.name,
                    kind: kind,
                    offset: record.offset,
                    size: record.size,
                    recoverySource: record.isContiguousEstimate ? .filesystemContiguousEstimate : .deletedFileRecord,
                    fileExtension: record.fileExtension,
                    payload: payload,
                    metadata: metadata,
                    physicalRanges: record.extents.map { ScannedRange(start: $0.offset, end: $0.offset + $0.length) }
                ))
            } catch {
                GoldfishLog.write("Deleted-file metadata recovery failed at offset \(record.offset): \(error.localizedDescription)")
            }
        }
        allFiles.sort { $0.offset < $1.offset }
        let recoveredImageRanges = Self.mergedImageRanges(in: allFiles)
        allFiles.removeAll { file in
            Self.isStrictlyContained(file.offset, in: recoveredImageRanges)
        }
        let retainedSignatureCandidates = allFiles.filter { $0.recoverySource == .signatureScan }.count
        let filteredCandidateCount = max(0, detectedCandidateCount - retainedSignatureCandidates)
        await progress(await reporter.addRecoveredFiles(allFiles, total: total))
        RecoveryStaging.removeUnretainedFiles(in: stagingDirectory, keeping: allFiles)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - scanStart) / 1_000_000_000
        let mibPerSecond = elapsed > 0 ? Double(total) / elapsed / 1_048_576 : 0
        GoldfishLog.write("Parallel scan completed: \(allFiles.count) candidate(s) retained, \(filteredCandidateCount) contained match(es) filtered, \(String(format: "%.1f", elapsed))s, \(String(format: "%.1f", mibPerSecond)) MiB/s")
        return allFiles
    }

    private nonisolated static func fileSize(at path: String) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private struct RangeResultPlaceholder: Sendable { let start: UInt64; let end: UInt64 }

    private nonisolated static func mergedImageRanges(in files: [RecoveredFile]) -> [ScannedRange] {
        var ranges: [ScannedRange] = []
        for file in files where file.kind == .image {
            let end = file.offset.addingReportingOverflow(file.size)
            let range = ScannedRange(start: file.offset, end: end.overflow ? UInt64.max : end.partialValue)
            if let last = ranges.last, range.start < last.end {
                ranges[ranges.count - 1] = ScannedRange(start: last.start, end: max(last.end, range.end))
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    private nonisolated static func isStrictlyContained(_ offset: UInt64, in ranges: [ScannedRange]) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].start < offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return false }
        let range = ranges[low - 1]
        return offset > range.start && offset < range.end
    }

    /// Finds all signature markers in one pass over the bytes. The previous
    /// implementation asked Data to scan the same block once per file type.
    private nonisolated static func signatureMatches(in data: Data, baseOffset: UInt64) -> [(signatureIndex: Int, offset: UInt64)] {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var matches: [(signatureIndex: Int, offset: UInt64)] = []
            var index = 0
            while index < bytes.count {
                let signatureIndex: Int?
                switch bytes[index] {
                case 0xFF: signatureIndex = 0
                case 0x49: signatureIndex = 1
                case 0x4D: signatureIndex = 2
                case 0x89: signatureIndex = 3
                case 0x47: signatureIndex = 4
                case 0x25: signatureIndex = 5
                case 0x1A: signatureIndex = 6
                case 0x66: signatureIndex = 7
                default: signatureIndex = nil
                }
                if let signatureIndex {
                    let marker = signatures[signatureIndex].marker
                    if index + marker.count <= bytes.count {
                        var markerIndex = 1
                        while markerIndex < marker.count, bytes[index + markerIndex] == marker[markerIndex] {
                            markerIndex += 1
                        }
                        if markerIndex == marker.count {
                            matches.append((signatureIndex, baseOffset + UInt64(index)))
                        }
                    }
                }
                index += 1
            }
            return matches
        }
    }

    private nonisolated static func scanRange(path: String, start: UInt64, end: UInt64, total: UInt64, stagingDirectory: URL?, onReadError: @escaping @Sendable (ScannedRange) async -> Void, onProgress: @escaping @Sendable (UInt64, UInt64) async -> Void, onCandidate: @escaping @Sendable (RecoveredFile) async -> Void) async throws -> RangeResult {
        let device = try RawDevice(path: path, total: path.hasPrefix("/dev/") ? total : 0)
        let blockSize = 4 * 1024 * 1024
        var offset = start
        let lookbehindCount = Int(min(UInt64(signatureOverlap), start))
        var overlap = Data()
        if lookbehindCount > 0 {
            do {
                overlap = try device.read(at: start - UInt64(lookbehindCount), count: lookbehindCount)
            } catch {
                await onReadError(ScannedRange(start: start - UInt64(lookbehindCount), end: start))
                GoldfishLog.write("Range lookbehind read failed at offset \(start - UInt64(lookbehindCount)): \(error.localizedDescription)")
            }
        }
        var found: [RecoveredFile] = []
        var seenOffsets = Set<UInt64>()
        var embeddedJPEGOffsets = Set<UInt64>()

        func process(_ matches: [(signatureIndex: Int, offset: UInt64)]) async {
            for match in matches {
                let signature = signatures[match.signatureIndex]
                guard match.offset >= signature.startAdjustment else { continue }
                let absolute = match.offset - signature.startAdjustment
                if !seenOffsets.contains(absolute) {
                    seenOffsets.insert(absolute)
                    if !embeddedJPEGOffsets.contains(absolute) {
                        do {
                            if let file = try carve(device: device, signature: signature, offset: absolute, maxRead: min(signature.maxSize, total > absolute ? total - absolute : signature.maxSize), stagingDirectory: stagingDirectory) {
                                found.append(file)
                                if let thumbnailOffset = file.embeddedThumbnailOffset {
                                    embeddedJPEGOffsets.insert(thumbnailOffset)
                                }
                                await onCandidate(file)
                            }
                        } catch {
                            GoldfishLog.write("Candidate carve failed at offset \(absolute): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        func processBlock(_ block: Data, at blockOffset: UInt64) async {
            if !overlap.isEmpty {
                let prefixCount = min(signatureOverlap, block.count)
                let boundary = overlap + block.prefix(prefixCount)
                let boundaryStart = blockOffset - UInt64(overlap.count)
                let crossing = signatureMatches(in: boundary, baseOffset: boundaryStart).filter { match in
                    let markerLength = signatures[match.signatureIndex].marker.count
                    return match.offset < blockOffset && match.offset + UInt64(markerLength) > blockOffset
                }
                await process(crossing)
            }
            await process(signatureMatches(in: block, baseOffset: blockOffset))
            overlap = Data(block.suffix(signatureOverlap))
        }

        while offset < end {
            try Task.checkCancellation()
            let requested = Int(min(UInt64(blockSize), end - offset))
            let block: Data
            do {
                block = try device.read(at: offset, count: requested)
            } catch {
                GoldfishLog.write("Range read failed at offset \(offset); retrying in smaller blocks: \(error.localizedDescription)")
                let blockEnd = offset + UInt64(requested)
                var retryOffset = offset
                let retrySize = 64 * 1024
                overlap.removeAll(keepingCapacity: true)
                while retryOffset < blockEnd {
                    try Task.checkCancellation()
                    let retryCount = Int(min(UInt64(retrySize), blockEnd - retryOffset))
                    var pending: [(UInt64, Int)] = [(retryOffset, retryCount)]
                    while let (partOffset, partCount) = pending.popLast() {
                        try Task.checkCancellation()
                        do {
                            let part = try device.read(at: partOffset, count: partCount)
                            guard !part.isEmpty else { throw RecoveryError.cannotRead }
                            await processBlock(part, at: partOffset)
                            await onProgress(partOffset, UInt64(part.count))
                        } catch {
                            if partCount > 512 {
                                let firstCount = (partCount / 2 / 512) * 512
                                let split = max(512, firstCount)
                                if split < partCount {
                                    pending.append((partOffset + UInt64(split), partCount - split))
                                    pending.append((partOffset, split))
                                    continue
                                }
                            }
                            let failedEnd = partOffset + UInt64(partCount)
                            await onReadError(ScannedRange(start: partOffset, end: failedEnd))
                            GoldfishLog.write("Read error at offset \(partOffset), length \(partCount): \(error.localizedDescription)")
                            overlap.removeAll(keepingCapacity: true)
                        }
                    }
                    retryOffset += UInt64(retryCount)
                }
                offset = blockEnd
                continue
            }
            guard !block.isEmpty else {
                await onReadError(ScannedRange(start: offset, end: end))
                overlap.removeAll(keepingCapacity: true)
                break
            }
            await processBlock(block, at: offset)
            let blockOffset = offset
            offset += UInt64(block.count)
            await onProgress(blockOffset, UInt64(block.count))
        }
        return RangeResult(files: found)
    }

    private nonisolated static func carve(device: RawDevice, signature: Signature, offset: UInt64, maxRead: UInt64, stagingDirectory: URL?) throws -> RecoveredFile? {
        guard maxRead >= signature.minSize else { return nil }

        if signature.ext == "jpg" {
            let reader = CarveReader(device: device, base: offset, limit: maxRead)
            guard let size = jpegSize(reader), size >= signature.minSize else { return nil }
            let metadataLength = Int(min(size, 2 * 1024 * 1024))
            let metadata = try device.read(at: offset, count: metadataLength)
            let thumbnail = exifJPEGThumbnail(in: metadata)
            let payload = try RecoveryStaging.store(device: device, offset: offset, size: size, in: stagingDirectory)
            return RecoveredFile(name: "Recovered_\(String(format: "%06d", Int(offset)))", kind: .image, offset: offset, size: size, recoverySource: .signatureScan, fileExtension: "jpg", payload: payload, metadata: PhotoMetadataExtractor.extract(from: metadata), embeddedThumbnailData: thumbnail?.data, embeddedThumbnailOffset: thumbnail.map { offset + UInt64($0.offset) })
        }

        let reader = CarveReader(device: device, base: offset, limit: maxRead)
        let size: UInt64?
        switch signature.ext {
        case "png":
            size = pngSize(reader)
        case "gif":
            size = gifSize(reader)
        case "pdf":
            size = pdfSize(reader)
        case "mkv":
            size = matroskaSize(reader)
        case "mp4":
            size = mp4Size(reader)
        case "raw":
            size = tiffSize(reader)
        default:
            size = nil
        }
        guard let size, size >= signature.minSize, size <= maxRead else { return nil }
        let payload = try RecoveryStaging.store(device: device, offset: offset, size: size, in: stagingDirectory)
        let metadata: [String: String]
        if signature.kind == .image || signature.kind == .raw {
            let prefix = try? device.read(at: offset, count: Int(min(size, 2 * 1024 * 1024)))
            metadata = prefix.map(PhotoMetadataExtractor.extract(from:)) ?? [:]
        } else {
            metadata = [:]
        }
        return RecoveredFile(name: "Recovered_\(String(format: "%06d", Int(offset)))", kind: signature.kind, offset: offset, size: size, recoverySource: .signatureScan, fileExtension: signature.ext, payload: payload, metadata: metadata)
    }

    private nonisolated static func pngSize(_ reader: CarveReader) -> UInt64? {
        guard reader.read(0, 8) == Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]) else { return nil }
        var cursor: UInt64 = 8
        var chunkCount = 0
        var sawHeader = false
        while cursor + 12 <= reader.limit, chunkCount < 1_000_000 {
            guard let header = reader.read(cursor, 8), let length = bigEndianUInt32(header, 0) else { return nil }
            let type = Array(header[4..<8])
            let chunkSize = UInt64(length) + 12
            guard chunkSize >= 12, chunkSize <= reader.limit - cursor else { return nil }
            if chunkCount == 0 {
                guard type == Array("IHDR".utf8), length == 13 else { return nil }
                sawHeader = true
            }
            cursor += chunkSize
            chunkCount += 1
            if type == Array("IEND".utf8) {
                return sawHeader && length == 0 ? cursor : nil
            }
        }
        return nil
    }

    private nonisolated static func gifSize(_ reader: CarveReader) -> UInt64? {
        guard let header = reader.read(0, 13),
              header.prefix(6) == Data("GIF87a".utf8) || header.prefix(6) == Data("GIF89a".utf8) else { return nil }
        var cursor: UInt64 = 13
        let packed = header[10]
        if packed & 0x80 != 0 {
            cursor += UInt64(3 * (1 << (Int(packed & 0x07) + 1)))
        }

        func skipSubBlocks(from start: UInt64) -> UInt64? {
            var position = start
            var blocks = 0
            while position < reader.limit, blocks < 10_000_000 {
                guard let length = reader.byte(position) else { return nil }
                position += 1
                if length == 0 { return position }
                guard UInt64(length) <= reader.limit - position else { return nil }
                position += UInt64(length)
                blocks += 1
            }
            return nil
        }

        var records = 0
        while cursor < reader.limit, records < 1_000_000 {
            guard let marker = reader.byte(cursor) else { return nil }
            switch marker {
            case 0x3B:
                return cursor + 1
            case 0x21:
                guard cursor + 2 <= reader.limit else { return nil }
                guard let end = skipSubBlocks(from: cursor + 2) else { return nil }
                cursor = end
            case 0x2C:
                guard let descriptor = reader.read(cursor, 10) else { return nil }
                cursor += 10
                if descriptor[9] & 0x80 != 0 {
                    cursor += UInt64(3 * (1 << (Int(descriptor[9] & 0x07) + 1)))
                }
                guard cursor < reader.limit, reader.byte(cursor) != nil else { return nil }
                cursor += 1 // LZW minimum code size
                guard let end = skipSubBlocks(from: cursor) else { return nil }
                cursor = end
            default:
                return nil
            }
            records += 1
        }
        return nil
    }

    private nonisolated static func pdfSize(_ reader: CarveReader) -> UInt64? {
        guard let header = reader.read(0, 8), header.prefix(5) == Data("%PDF-".utf8),
              header[5] >= 0x31, header[5] <= 0x39, header[6] == 0x2E else { return nil }
        let marker = Data("%%EOF".utf8)
        let chunkSize = 1 * 1024 * 1024
        var cursor: UInt64 = 0
        var overlap = Data()
        while cursor < reader.limit {
            let count = Int(min(UInt64(chunkSize), reader.limit - cursor))
            guard let block = reader.read(cursor, count), !block.isEmpty else { return nil }
            let window = overlap + block
            if let match = window.range(of: marker) {
                let windowStart = cursor - UInt64(overlap.count)
                var end = windowStart + UInt64(match.upperBound - window.startIndex)
                if let trailing = reader.read(end, Int(min(2, reader.limit - end))) {
                    if trailing.first == 0x0D { end += 1; if trailing.count > 1, trailing[1] == 0x0A { end += 1 } }
                    else if trailing.first == 0x0A { end += 1 }
                }
                return end
            }
            overlap = Data(window.suffix(marker.count - 1))
            cursor += UInt64(block.count)
        }
        return nil
    }

    private nonisolated static func mp4Size(_ reader: CarveReader) -> UInt64? {
        let knownTypes = Set(["ftyp", "free", "skip", "wide", "mdat", "moov", "pnot", "uuid", "moof", "mfra", "sidx", "styp", "prft", "pdin", "meta"])
        var cursor: UInt64 = 0
        var boxes = 0
        var sawMedia = false
        var sawStructure = false
        while cursor + 8 <= reader.limit, boxes < 1_000_000 {
            guard let header = reader.read(cursor, 8), let size32 = bigEndianUInt32(header, 0),
                  let type = String(data: header[4..<8], encoding: .ascii) else { return nil }
            if boxes == 0, type != "ftyp" { return nil }
            guard knownTypes.contains(type) else {
                return sawMedia && sawStructure ? cursor : nil
            }
            let headerSize: UInt64
            let boxSize: UInt64
            if size32 == 1 {
                guard let extendedData = reader.read(cursor + 8, 8),
                      let extended = bigEndianUInt64(extendedData, 0), extended >= 16 else { return nil }
                headerSize = 16; boxSize = extended
            } else if size32 == 0 {
                return nil
            } else {
                headerSize = 8; boxSize = UInt64(size32)
            }
            guard boxSize >= headerSize, boxSize <= reader.limit - cursor else { return nil }
            if type == "mdat" { sawMedia = true }
            if type == "moov" || type == "moof" { sawStructure = true }
            cursor += boxSize
            boxes += 1
        }
        return sawMedia && sawStructure ? cursor : nil
    }

    private nonisolated static func matroskaSize(_ reader: CarveReader) -> UInt64? {
        guard reader.read(0, 4) == Data([0x1A,0x45,0xDF,0xA3]),
              let ebmlSize = ebmlVariableInteger(reader, at: 4) else { return nil }
        let segmentOffset = UInt64(4 + ebmlSize.length) + ebmlSize.value
        guard segmentOffset + 5 <= reader.limit,
              reader.read(segmentOffset, 4) == Data([0x18,0x53,0x80,0x67]),
              let segmentSize = ebmlVariableInteger(reader, at: segmentOffset + 4), !segmentSize.unknown else { return nil }
        let total = segmentOffset + 4 + UInt64(segmentSize.length) + segmentSize.value
        return total <= reader.limit ? total : nil
    }

    private nonisolated static func ebmlVariableInteger(_ reader: CarveReader, at offset: UInt64) -> (value: UInt64, length: Int, unknown: Bool)? {
        guard let first = reader.byte(offset), first != 0 else { return nil }
        var mask: UInt8 = 0x80
        var length = 1
        while first & mask == 0, length < 8 { mask >>= 1; length += 1 }
        guard let bytes = reader.read(offset, length) else { return nil }
        var value = UInt64(first & (mask - 1))
        for index in 1..<length { value = (value << 8) | UInt64(bytes[index]) }
        let unknownValue = length == 8 ? UInt64.max >> 8 : (UInt64(1) << UInt64(7 * length)) - 1
        return (value, length, value == unknownValue)
    }

    private nonisolated static func tiffSize(_ reader: CarveReader) -> UInt64? {
        guard let header = reader.read(0, 8) else { return nil }
        let littleEndian: Bool
        if header[0] == 0x49, header[1] == 0x49 { littleEndian = true }
        else if header[0] == 0x4D, header[1] == 0x4D { littleEndian = false }
        else { return nil }
        guard readTIFFUInt16(header, at: 2, littleEndian: littleEndian) == 42,
              let firstIFD = readTIFFUInt32(header, at: 4, littleEndian: littleEndian), firstIFD >= 8 else { return nil }

        var pending = [UInt64(firstIFD)]
        var visited = Set<UInt64>()
        var maximumEnd: UInt64 = 8
        while let ifdOffset = pending.popLast(), visited.insert(ifdOffset).inserted, visited.count <= 256 {
            guard let countData = reader.read(ifdOffset, 2),
                  let entryCount = readTIFFUInt16(countData, at: 0, littleEndian: littleEndian), entryCount <= 4096 else { return nil }
            let tableSize = 2 + Int(entryCount) * 12 + 4
            guard let table = reader.read(ifdOffset, tableSize) else { return nil }
            maximumEnd = max(maximumEnd, ifdOffset + UInt64(tableSize))
            var valuesByTag: [UInt16: [UInt64]] = [:]
            for index in 0..<Int(entryCount) {
                let entry = 2 + index * 12
                guard let tag = readTIFFUInt16(table, at: entry, littleEndian: littleEndian),
                      let type = readTIFFUInt16(table, at: entry + 2, littleEndian: littleEndian),
                      let count = readTIFFUInt32(table, at: entry + 4, littleEndian: littleEndian),
                      let typeSize = tiffTypeSize(type) else { continue }
                let byteCount = UInt64(count) * UInt64(typeSize)
                guard byteCount <= reader.limit else { return nil }
                let valueData: Data
                if byteCount <= 4 {
                    valueData = Data(table[(entry + 8)..<(entry + 12)])
                } else {
                    guard let valueOffset = readTIFFUInt32(table, at: entry + 8, littleEndian: littleEndian),
                          UInt64(valueOffset) <= reader.limit, byteCount <= reader.limit - UInt64(valueOffset),
                          byteCount <= UInt64(Int.max), let external = reader.read(UInt64(valueOffset), Int(byteCount)) else { return nil }
                    maximumEnd = max(maximumEnd, UInt64(valueOffset) + byteCount)
                    valueData = external
                }
                if type == 3 || type == 4 || type == 13 {
                    var values: [UInt64] = []
                    let stride = type == 3 ? 2 : 4
                    let valueCount = min(Int(count), valueData.count / stride)
                    for valueIndex in 0..<valueCount {
                        if type == 3, let value = readTIFFUInt16(valueData, at: valueIndex * 2, littleEndian: littleEndian) { values.append(UInt64(value)) }
                        else if let value = readTIFFUInt32(valueData, at: valueIndex * 4, littleEndian: littleEndian) { values.append(UInt64(value)) }
                    }
                    valuesByTag[tag] = values
                    if tag == 330 || tag == 34665 || tag == 34853 { pending.append(contentsOf: values.filter { $0 >= 8 }) }
                }
            }
            let nextOffsetLocation = 2 + Int(entryCount) * 12
            if let next = readTIFFUInt32(table, at: nextOffsetLocation, littleEndian: littleEndian), next >= 8 { pending.append(UInt64(next)) }
            for (offsetTag, countTag) in [(UInt16(273), UInt16(279)), (UInt16(324), UInt16(325)), (UInt16(513), UInt16(514))] {
                guard let offsets = valuesByTag[offsetTag], let counts = valuesByTag[countTag] else { continue }
                for (dataOffset, dataCount) in zip(offsets, counts) {
                    guard dataOffset <= reader.limit, dataCount <= reader.limit - dataOffset else { return nil }
                    maximumEnd = max(maximumEnd, dataOffset + dataCount)
                }
            }
        }
        return maximumEnd >= 256 ? maximumEnd : nil
    }

    private nonisolated static func tiffTypeSize(_ type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: nil
        }
    }

    private nonisolated static func bigEndianUInt32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private nonisolated static func bigEndianUInt64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }

    private nonisolated static func jpegSize(_ reader: CarveReader) -> UInt64? {
        guard reader.read(0, 2) == Data([0xFF, 0xD8]) else { return nil }
        var cursor: UInt64 = 2
        var sawFrame = false
        var sawScan = false
        var markerCount = 0
        while cursor + 2 <= reader.limit, markerCount < 100_000 {
            guard var markerBytes = reader.read(cursor, 2), markerBytes[0] == 0xFF else { return nil }
            while markerBytes[1] == 0xFF {
                cursor += 1
                guard let next = reader.read(cursor, 2) else { return nil }
                markerBytes = next
            }
            let marker = markerBytes[1]
            if marker == 0xD9 { return sawFrame && sawScan ? cursor + 2 : nil }
            if marker == 0x00 { return nil }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                cursor += 2
                markerCount += 1
                continue
            }
            guard let lengthBytes = reader.read(cursor + 2, 2) else { return nil }
            let length = UInt64(lengthBytes[0]) << 8 | UInt64(lengthBytes[1])
            guard length >= 2, length <= reader.limit - cursor - 2 else { return nil }
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { sawFrame = true }
            let segmentEnd = cursor + 2 + length
            if marker == 0xDA {
                sawScan = true
                guard let nextMarker = nextJPEGMarker(reader, from: segmentEnd) else { return nil }
                cursor = nextMarker.offset
            } else {
                cursor = segmentEnd
            }
            markerCount += 1
        }
        return nil
    }

    private nonisolated static func nextJPEGMarker(_ reader: CarveReader, from start: UInt64) -> (offset: UInt64, marker: UInt8)? {
        var cursor = start
        var pendingMarkerOffset: UInt64?
        let chunkSize = 1 * 1024 * 1024
        while cursor < reader.limit {
            let count = Int(min(UInt64(chunkSize), reader.limit - cursor))
            guard let block = reader.read(cursor, count), !block.isEmpty else { return nil }
            for index in block.indices {
                let byte = block[index]
                let absolute = cursor + UInt64(index)
                if let markerOffset = pendingMarkerOffset {
                    if byte == 0x00 || (0xD0...0xD7).contains(byte) {
                        pendingMarkerOffset = nil
                    } else if byte != 0xFF {
                        return (markerOffset, byte)
                    }
                } else if byte == 0xFF {
                    pendingMarkerOffset = absolute
                }
            }
            cursor += UInt64(block.count)
        }
        return nil
    }

    private nonisolated static func exifJPEGThumbnail(in jpeg: Data) -> (data: Data, offset: Int)? {
        var markerIndex = 2
        while markerIndex + 1 < jpeg.count {
            guard jpeg[markerIndex] == 0xFF else { return nil }
            while markerIndex < jpeg.count && jpeg[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < jpeg.count else { return nil }
            let marker = jpeg[markerIndex]
            if marker == 0xDA || marker == 0xD9 { return nil }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { markerIndex += 1; continue }
            guard markerIndex + 2 < jpeg.count else { return nil }
            let segmentLength = Int(jpeg[markerIndex + 1]) << 8 | Int(jpeg[markerIndex + 2])
            guard segmentLength >= 2, markerIndex + 1 + segmentLength <= jpeg.count else { return nil }

            let payloadStart = markerIndex + 3
            if marker == 0xE1, payloadStart + 14 <= markerIndex + 1 + segmentLength,
               jpeg[payloadStart] == 0x45, jpeg[payloadStart + 1] == 0x78,
               jpeg[payloadStart + 2] == 0x69, jpeg[payloadStart + 3] == 0x66,
               jpeg[payloadStart + 4] == 0, jpeg[payloadStart + 5] == 0 {
                let tiffStart = payloadStart + 6
                let littleEndian: Bool
                if jpeg[tiffStart] == 0x49 && jpeg[tiffStart + 1] == 0x49 {
                    littleEndian = true
                } else if jpeg[tiffStart] == 0x4D && jpeg[tiffStart + 1] == 0x4D {
                    littleEndian = false
                } else {
                    markerIndex += 1 + segmentLength
                    continue
                }
                guard readTIFFUInt16(jpeg, at: tiffStart + 2, littleEndian: littleEndian) == 42,
                      let ifd0Offset = readTIFFUInt32(jpeg, at: tiffStart + 4, littleEndian: littleEndian) else {
                    markerIndex += 1 + segmentLength
                    continue
                }
                let ifd0 = tiffStart + Int(ifd0Offset)
                guard let entryCount = readTIFFUInt16(jpeg, at: ifd0, littleEndian: littleEndian) else {
                    markerIndex += 1 + segmentLength
                    continue
                }
                let nextIFDLocation = ifd0 + 2 + Int(entryCount) * 12
                guard let ifd1Offset = readTIFFUInt32(jpeg, at: nextIFDLocation, littleEndian: littleEndian), ifd1Offset != 0 else {
                    markerIndex += 1 + segmentLength
                    continue
                }
                let ifd1 = tiffStart + Int(ifd1Offset)
                guard let thumbnailEntryCount = readTIFFUInt16(jpeg, at: ifd1, littleEndian: littleEndian) else {
                    markerIndex += 1 + segmentLength
                    continue
                }
                var thumbnailOffset: UInt32?
                var thumbnailLength: UInt32?
                for entry in 0..<Int(thumbnailEntryCount) {
                    let location = ifd1 + 2 + entry * 12
                    guard let tag = readTIFFUInt16(jpeg, at: location, littleEndian: littleEndian) else { break }
                    if tag == 0x0201 { thumbnailOffset = readTIFFUInt32(jpeg, at: location + 8, littleEndian: littleEndian) }
                    if tag == 0x0202 { thumbnailLength = readTIFFUInt32(jpeg, at: location + 8, littleEndian: littleEndian) }
                }
                if let thumbnailOffset, let thumbnailLength, thumbnailLength >= 128 {
                    let thumbnailStart = tiffStart + Int(thumbnailOffset)
                    let length = Int(thumbnailLength)
                    if thumbnailStart >= 0, length <= jpeg.count - thumbnailStart {
                        let candidate = jpeg.subdata(in: thumbnailStart..<(thumbnailStart + length))
                        if let end = jpegEnd(in: candidate), end > 128 {
                            return (Data(candidate.prefix(end)), thumbnailStart)
                        }
                    }
                }
            }
            markerIndex += 1 + segmentLength
        }
        return nil
    }

    private nonisolated static func readTIFFUInt16(_ data: Data, at index: Int, littleEndian: Bool) -> UInt16? {
        guard index >= 0, index + 2 <= data.count else { return nil }
        let first = UInt16(data[index]), second = UInt16(data[index + 1])
        return littleEndian ? first | (second << 8) : (first << 8) | second
    }

    private nonisolated static func readTIFFUInt32(_ data: Data, at index: Int, littleEndian: Bool) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        let bytes = (0..<4).map { UInt32(data[index + $0]) }
        if littleEndian {
            return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
        }
        return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
    }

    private nonisolated static func jpegEnd(in data: Data) -> Int? {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var index = 2
        while index + 1 < data.count {
            guard data[index] == 0xFF else { index += 1; continue }
            var markerIndex = index + 1
            while markerIndex < data.count && data[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < data.count else { return nil }
            let marker = data[markerIndex]
            if marker == 0xD9 { return markerIndex + 1 }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { index = markerIndex + 1; continue }
            guard markerIndex + 2 < data.count else { return nil }
            let length = Int(data[markerIndex + 1]) << 8 | Int(data[markerIndex + 2])
            guard length >= 2, markerIndex + 1 + length <= data.count else { return nil }
            let segmentEnd = markerIndex + 1 + length
            if marker == 0xDA {
                var scan = segmentEnd
                while scan + 1 < data.count {
                    guard data[scan] == 0xFF else { scan += 1; continue }
                    if data[scan + 1] == 0x00 || (0xD0...0xD7).contains(data[scan + 1]) { scan += 2; continue }
                    if data[scan + 1] == 0xD9 { return scan + 2 }
                    index = scan
                    break
                }
                if scan + 1 >= data.count { return nil }
            } else {
                index = segmentEnd
            }
        }
        return nil
    }

}
