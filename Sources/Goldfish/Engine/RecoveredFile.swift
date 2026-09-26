import Foundation

/// A file found on the device. It records where its bytes are rather than
/// holding them, and reads them from the device on demand, so the device must
/// stay connected until the file is exported.
public struct RecoveredFile: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public private(set) var name: String
    public let kind: FileKind
    public let offset: UInt64
    public let size: UInt64
    public let recoverySource: RecoverySource
    public let status: FileStatus
    public private(set) var fileExtension: String
    public internal(set) var metadata: [String: String]
    /// Where the file's bytes are on the device, in file order.
    public let physicalRanges: [ScannedRange]
    public let embeddedThumbnailData: Data?
    public let embeddedThumbnailOffset: UInt64?
    /// Held open for the file's lifetime: if the card is removed, reads fail
    /// instead of reaching whatever device later takes over its node.
    let device: RawDevice

    public var isFragmented: Bool { physicalRanges.count > 1 }
    public var sizeDescription: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    init(name: String, kind: FileKind, offset: UInt64, size: UInt64, recoverySource: RecoverySource, status: FileStatus, fileExtension: String, device: RawDevice, metadata: [String: String], physicalRanges: [ScannedRange], embeddedThumbnailData: Data? = nil, embeddedThumbnailOffset: UInt64? = nil) {
        precondition(!physicalRanges.isEmpty, "A recovered file must cover at least one device range")
        precondition(physicalRanges.reduce(0) { $0 + $1.end - $1.start } == size, "Physical ranges must add up to the file size")
        self.name = name
        self.kind = kind
        self.offset = offset
        self.size = size
        self.recoverySource = recoverySource
        self.status = status
        self.fileExtension = fileExtension
        self.device = device
        self.metadata = metadata
        self.physicalRanges = physicalRanges
        self.embeddedThumbnailData = embeddedThumbnailData
        self.embeddedThumbnailOffset = embeddedThumbnailOffset
    }

    static func generatedName(offset: UInt64) -> String {
        String(format: "Recovered_%06llX", offset)
    }

    /// Reads up to `count` bytes starting `position` bytes into the file. The
    /// result is shorter only at the end of the file.
    func read(at position: UInt64, count: Int) throws -> Data {
        precondition(count >= 0, "Negative read count")
        let end = min(size, position + UInt64(count))
        guard position < end else { return Data() }
        var output = Data(capacity: Int(end - position))
        var rangeStartInFile: UInt64 = 0
        for range in physicalRanges {
            let rangeEndInFile = rangeStartInFile + (range.end - range.start)
            if rangeEndInFile > position, rangeStartInFile < end {
                let deviceOffset = range.start + (max(position, rangeStartInFile) - rangeStartInFile)
                let wanted = Int(min(end, rangeEndInFile) - max(position, rangeStartInFile))
                let bytes = try device.read(at: deviceOffset, count: wanted)
                guard bytes.count == wanted else { throw RecoveryError.incompleteRead(device.path, offset: deviceOffset + UInt64(bytes.count)) }
                output.append(bytes)
            }
            rangeStartInFile = rangeEndInFile
        }
        return output
    }

    /// Reads the whole file into memory.
    public func readData() throws -> Data {
        try read(at: 0, count: Int(size))
    }

    /// Streams the file from the device to `destination`, failing if it already exists.
    public func write(to destination: URL) throws {
        try device.copy(physicalRanges, size: size, to: destination)
    }

    mutating func applyOriginalFilename(_ filename: String) {
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { return }
        let originalExtension = (safeName as NSString).pathExtension
        name = (safeName as NSString).deletingPathExtension
        if !originalExtension.isEmpty { fileExtension = originalExtension.lowercased() }
    }

    public static func == (lhs: RecoveredFile, rhs: RecoveredFile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
