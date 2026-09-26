import Foundation

public struct Device: Identifiable, Hashable, Sendable {
    /// Where the volume is mounted, e.g. `/Volumes/CARD`.
    public let mountPath: String
    public let name: String
    /// The raw device node that is scanned, e.g. `/dev/rdisk4s1`.
    public let path: String
    public let isRemovable: Bool
    public let isInternal: Bool
    public let identifier: String
    public let size: UInt64
    public var id: String { mountPath }

    public init(mountPath: String, name: String, path: String, isRemovable: Bool, isInternal: Bool, identifier: String, size: UInt64) {
        self.mountPath = mountPath
        self.name = name
        self.path = path
        self.isRemovable = isRemovable
        self.isInternal = isInternal
        self.identifier = identifier
        self.size = size
    }

    public var sizeDescription: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

public enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case image = "Photos", video = "Videos", document = "Documents", audio = "Audio", raw = "Camera RAW", unknown = "Other"
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .image: "photo"; case .video: "film"; case .document: "doc.text"; case .audio: "waveform"; case .raw: "camera.aperture"; case .unknown: "doc" }
    }
    var hasPhotoMetadata: Bool { self == .image || self == .raw }

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

/// What the card's directory says about a recovered file.
public enum FileStatus: Sendable {
    /// A deleted directory entry points to the file.
    case deleted
    /// A live directory entry points to the file, so it can simply be copied.
    case stillOnCard
    /// No directory entry points to the file, e.g. after the card was formatted.
    case noRecord

    var label: String {
        switch self {
        case .deleted: "Deleted"
        case .stillOnCard: "Still on card"
        case .noRecord: "No file record"
        }
    }
}

public enum RecoveryError: LocalizedError {
    case cannotRead
    case rawAccessRequired(String)
    case readFailed(String, Int32)
    case incompleteRead(String, offset: UInt64)
    case deviceDisconnected(String)

    public var errorDescription: String? {
        switch self {
        case .cannotRead: "The selected storage could not be opened."
        case .rawAccessRequired(let path): "macOS still cannot open the SD-card device at \(path). The card was not changed. Full Disk Access and device permissions are separate."
        case .readFailed(let path, let code): "Reading \(path) failed with system error \(code) (\(String(cString: strerror(code)))). The card was not changed."
        case .incompleteRead(let path, let offset): "Reading \(path) ended early at offset \(offset). The card was not changed."
        case .deviceDisconnected(let path): "The card at \(path) is no longer connected. Reconnect it and scan again to export these files."
        }
    }
}
