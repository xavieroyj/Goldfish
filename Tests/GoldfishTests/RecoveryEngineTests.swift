import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import Goldfish

private actor ProgressRecorder {
    private(set) var latest: ScanProgress?
    func record(_ progress: ScanProgress) { latest = progress }
}

private actor CandidateRecorder {
    private(set) var offsets: [UInt64] = []
    func record(_ file: RecoveredFile) { offsets.append(file.offset) }
}

@Test func scanProgressSeparatesCandidatesReadErrorsAndUnscannedRanges() {
    let progress = ScanProgress(
        bytesRead: 40,
        total: 100,
        found: 1,
        scannedRanges: [ScannedRange(start: 0, end: 40)],
        candidateRanges: [ScannedRange(start: 10, end: 20)],
        readErrors: [ScannedRange(start: 40, end: 50)]
    )
    #expect(progress.scannedWithoutCandidates == [ScannedRange(start: 0, end: 10), ScannedRange(start: 20, end: 40)])
    #expect(progress.unscannedRanges == [ScannedRange(start: 50, end: 100)])
}

@Test func scanFindsJPEGInTemporaryVolume() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-test-\(UUID().uuidString)")
    let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xD9])
    let appPayload = thumbnail
    let appLength = UInt16(appPayload.count + 2)
    let app = Data([0xFF, 0xE1, UInt8(appLength >> 8), UInt8(appLength & 0xFF)]) + appPayload
    let sof = Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
    let sos = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    let jpeg = Data([0xFF, 0xD8]) + app + sof + sos + Data(repeating: 0x20, count: 220) + Data([0xFF, 0xD9])
    try jpeg.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let recorder = ProgressRecorder()
    let result = try await RecoveryEngine().scan(device: Device(id: file.path, name: "Test", path: file.path, isRemovable: true, isReadOnly: true)) { progress in
        await recorder.record(progress)
    }
    #expect(result.count == 1)
    #expect(result.first?.kind == .image)
    #expect(result.first?.data == jpeg)
    let latest = await recorder.latest
    #expect(latest?.scannedRanges == [ScannedRange(start: 0, end: UInt64(jpeg.count))])
    #expect(latest?.candidateRanges == [ScannedRange(start: 0, end: UInt64(jpeg.count))])
    #expect(latest?.readErrors.isEmpty == true)
    #expect(latest?.scannedWithoutCandidates.isEmpty == true)
    #expect(latest?.unscannedRanges.isEmpty == true)
}

@Test func FAT32DirectoryMetadataMapsOriginalFilenameToFirstCluster() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("fat32-name-test-\(UUID().uuidString)")
    var volume = Data(repeating: 0, count: 2048)
    func put16(_ value: UInt16, at offset: Int) {
        volume[offset] = UInt8(value & 0xFF)
        volume[offset + 1] = UInt8(value >> 8)
    }
    func put32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 { volume[offset + byte] = UInt8((value >> (byte * 8)) & 0xFF) }
    }

    // Minimal FAT32 geometry: one 512-byte FAT sector, cluster 2 is root,
    // and cluster 3 (offset 1536) contains the file data.
    put16(512, at: 11)
    volume[13] = 1
    put16(1, at: 14)
    volume[16] = 1
    put32(1, at: 36)
    put32(2, at: 44)
    volume[510] = 0x55
    volume[511] = 0xAA
    put32(0x0FFFFFFF, at: 512 + 2 * 4)
    put32(0x0FFFFFFF, at: 512 + 3 * 4)
    let entry = 1024
    for (index, byte) in Array("PIC0001 JPG".utf8).enumerated() { volume[entry + index] = byte }
    volume[entry + 11] = 0x20
    put16(0, at: entry + 20)
    put16(3, at: entry + 26)
    put32(350, at: entry + 28)
    try volume.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let names = FileSystemNameIndex.namesByOffset(path: file.path, total: UInt64(volume.count))
    #expect(names[1536] == "PIC0001.JPG")
}

@Test func deletedFAT32EntryRecoversSignaturelessContiguousFile() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("fat32-deleted-test-\(UUID().uuidString)")
    var volume = Data(repeating: 0, count: 2560)
    func put16(_ value: UInt16, at offset: Int) {
        volume[offset] = UInt8(value & 0xFF)
        volume[offset + 1] = UInt8(value >> 8)
    }
    func put32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 { volume[offset + byte] = UInt8((value >> (byte * 8)) & 0xFF) }
    }
    put16(512, at: 11)
    volume[13] = 1
    put16(1, at: 14)
    volume[16] = 1
    put32(1, at: 36)
    put32(2, at: 44)
    volume[510] = 0x55
    volume[511] = 0xAA
    put32(0x0FFFFFFF, at: 512 + 2 * 4)
    let entry = 1024
    volume[entry] = 0xE5
    for (index, byte) in Array("ILE0001TXT".utf8).enumerated().dropFirst() { volume[entry + index + 1] = byte }
    volume[entry + 11] = 0x20
    put16(0, at: entry + 20)
    put16(3, at: entry + 26)
    let original = Data(repeating: 0x4B, count: 600)
    put32(UInt32(original.count), at: entry + 28)
    volume.replaceSubrange(1536..<(1536 + original.count), with: original)
    try volume.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = try await RecoveryEngine().scan(
        device: Device(id: file.path, name: "FAT32 test", path: file.path, isRemovable: true, isReadOnly: true),
        progress: { _ in }
    )
    #expect(result.count == 1)
    #expect(result[0].data == original)
    #expect(result[0].fileExtension == "txt")
    #expect(result[0].recoverySource == .filesystemContiguousEstimate)
}

@Test func deletedExFATEntryRecoversSignaturelessContiguousFile() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("exfat-deleted-test-\(UUID().uuidString)")
    var volume = Data(repeating: 0, count: 2048)
    func put32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 { volume[offset + byte] = UInt8((value >> (byte * 8)) & 0xFF) }
    }
    func put64(_ value: UInt64, at offset: Int) {
        for byte in 0..<8 { volume[offset + byte] = UInt8((value >> (byte * 8)) & 0xFF) }
    }
    volume.replaceSubrange(3..<11, with: Data("EXFAT   ".utf8))
    volume[108] = 9
    volume[109] = 0
    put32(1, at: 80)
    put32(2, at: 88)
    put32(2, at: 96)
    put32(0xFFFFFFFF, at: 512 + 2 * 4)
    let entry = 1024
    volume[entry] = 0x05
    volume[entry + 1] = 2
    let stream = entry + 32
    volume[stream] = 0x40
    volume[stream + 1] = 0x02
    let filename = Array("PIC0001.TXT".utf16)
    volume[stream + 3] = UInt8(filename.count)
    put32(3, at: stream + 20)
    let original = Data("restored from exFAT metadata".utf8)
    put64(UInt64(original.count), at: stream + 24)
    let names = entry + 64
    volume[names] = 0x41
    for (index, unit) in filename.enumerated() {
        volume[names + 2 + index * 2] = UInt8(unit & 0xFF)
        volume[names + 3 + index * 2] = UInt8(unit >> 8)
    }
    volume.replaceSubrange(1536..<(1536 + original.count), with: original)
    try volume.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = try await RecoveryEngine().scan(
        device: Device(id: file.path, name: "exFAT test", path: file.path, isRemovable: true, isReadOnly: true),
        progress: { _ in }
    )
    #expect(result.count == 1)
    #expect(result[0].name == "PIC0001")
    #expect(result[0].fileExtension == "txt")
    #expect(result[0].data == original)
    #expect(result[0].recoverySource == .deletedFileRecord)
}

@Test func deletedFAT32EntryUsesSurvivingFragmentChain() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("fat32-fragmented-test-\(UUID().uuidString)")
    var volume = Data(repeating: 0, count: 3072)
    func put16(_ value: UInt16, at offset: Int) {
        volume[offset] = UInt8(value & 0xFF)
        volume[offset + 1] = UInt8(value >> 8)
    }
    func put32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 { volume[offset + byte] = UInt8((value >> (byte * 8)) & 0xFF) }
    }
    put16(512, at: 11)
    volume[13] = 1
    put16(1, at: 14)
    volume[16] = 1
    put32(1, at: 36)
    put32(2, at: 44)
    volume[510] = 0x55
    volume[511] = 0xAA
    put32(0x0FFFFFFF, at: 512 + 2 * 4)
    put32(5, at: 512 + 3 * 4)
    put32(0x0FFFFFFF, at: 512 + 5 * 4)
    let entry = 1024
    volume[entry] = 0xE5
    for (index, byte) in Array("AGMENTEDBIN".utf8).enumerated().dropFirst() { volume[entry + index + 1] = byte }
    volume[entry + 11] = 0x20
    put16(0, at: entry + 20)
    put16(3, at: entry + 26)
    let original = Data(repeating: 0x31, count: 512) + Data("tail!!".utf8)
    put32(UInt32(original.count), at: entry + 28)
    volume.replaceSubrange(1536..<2048, with: original.prefix(512))
    volume.replaceSubrange(2560..<2566, with: original.suffix(6))
    try volume.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let recorder = ProgressRecorder()
    let result = try await RecoveryEngine().scan(
        device: Device(id: file.path, name: "FAT32 fragmented test", path: file.path, isRemovable: true, isReadOnly: true),
        progress: { await recorder.record($0) }
    )
    #expect(result.count == 1)
    #expect(result[0].size == UInt64(original.count))
    #expect(result[0].data == original)
    #expect(result[0].isFragmented == true)
    #expect(result[0].physicalRanges == [ScannedRange(start: 1536, end: 2048), ScannedRange(start: 2560, end: 2566)])
    #expect(result[0].recoverySource == .deletedFileRecord)
    #expect(await recorder.latest?.candidateRanges == result[0].physicalRanges)
}

@Test func photoMetadataExtractorReadsAvailableEXIFFields() throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test Camera", kCGImagePropertyTIFFModel: "Model One"],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:09:25 12:00:00",
            kCGImagePropertyExifLensModel: "Test Lens",
            kCGImagePropertyExifFocalLength: 35.0,
            kCGImagePropertyExifFNumber: 2.8,
            kCGImagePropertyExifExposureTime: 0.01,
            kCGImagePropertyExifISOSpeedRatings: [100]
        ]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let metadata = PhotoMetadataExtractor.extract(from: output as Data)
    #expect(metadata["Camera make"] == "Test Camera")
    #expect(metadata["Camera model"] == "Model One")
    #expect(metadata["Lens"] == "Test Lens")
    #expect(metadata["Dimensions"] == "1 × 1")
}

@Test func scanFindsJPEGWhoseEndIsPastInitialRead() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-test-\(UUID().uuidString)")
    let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xD9])
    let appLength = UInt16(thumbnail.count + 2)
    let app = Data([0xFF, 0xE1, UInt8(appLength >> 8), UInt8(appLength & 0xFF)]) + thumbnail
    let sof = Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
    let sos = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    let jpeg = Data([0xFF, 0xD8]) + app + sof + sos + Data(repeating: 0x20, count: 1_100_000) + Data([0xFF, 0xD9])
    try jpeg.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = try await RecoveryEngine().scan(device: Device(id: file.path, name: "Test", path: file.path, isRemovable: true, isReadOnly: true)) { _ in }
    #expect(result.count == 1)
    #expect(result.first?.size == UInt64(jpeg.count))
    #expect(result.first?.data == jpeg)
}

@Test func exifThumbnailIsAttachedToParentInsteadOfRecoveredSeparately() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-test-\(UUID().uuidString)")
    let thumbnail = Data([0xFF, 0xD8])
        + Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
        + Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
        + Data(repeating: 0x20, count: 220) + Data([0xFF, 0xD9])

    let exifPayload = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        + Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        + Data([0x00, 0x00, 0x0E, 0x00, 0x00, 0x00])
        + Data([0x02, 0x00])
        + Data([0x01, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00])
        + Data([0x02, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, UInt8(thumbnail.count), 0x00, 0x00, 0x00])
        + Data([0x00, 0x00, 0x00, 0x00]) + thumbnail
    let segmentLength = UInt16(exifPayload.count + 2)
    let app1 = Data([0xFF, 0xE1, UInt8(segmentLength >> 8), UInt8(segmentLength & 0xFF)]) + exifPayload
    let sof = Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
    let sos = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    let jpeg = Data([0xFF, 0xD8]) + app1 + sof + sos + Data(repeating: 0x20, count: 220) + Data([0xFF, 0xD9])
    try jpeg.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = try await RecoveryEngine().scan(device: Device(id: file.path, name: "Test", path: file.path, isRemovable: true, isReadOnly: true)) { _ in }
    #expect(result.count == 1)
    #expect(result.first?.data == jpeg)
    #expect(result.first?.embeddedThumbnailData == thumbnail)
}

@Test func scanFindsSignatureCrossingWorkerRangeBoundary() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-boundary-test-\(UUID().uuidString)")
    let sof = Data([0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
    let sos = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    let jpeg = Data([0xFF, 0xD8]) + sof + sos + Data(repeating: 0x20, count: 220) + Data([0xFF, 0xD9])
    let boundary = UInt64(64 * 1024 * 1024)
    let expectedOffset = boundary - 2

    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: boundary + UInt64(jpeg.count))
    try handle.seek(toOffset: expectedOffset)
    try handle.write(contentsOf: jpeg)
    try handle.close()
    defer { try? FileManager.default.removeItem(at: file) }

    let candidates = CandidateRecorder()
    let result = try await RecoveryEngine().scan(
        device: Device(id: file.path, name: "Boundary", path: file.path, isRemovable: true, isReadOnly: true),
        progress: { _ in },
        onCandidate: { await candidates.record($0) }
    )

    #expect(result.map(\.offset) == [expectedOffset])
    #expect(await candidates.offsets == [expectedOffset])
}

@Test func formatAwareCarversRecoverExactFileSizes() async throws {
    func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    func pngChunk(_ type: String, payload: Data) -> Data {
        be32(UInt32(payload.count)) + Data(type.utf8) + payload + Data(repeating: 0, count: 4)
    }
    let png = Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A])
        + pngChunk("IHDR", payload: Data(repeating: 0, count: 13))
        + pngChunk("IDAT", payload: Data(repeating: 0x31, count: 100))
        + pngChunk("IEND", payload: Data())
    let gif = Data("GIF89a".utf8) + Data([0x01,0x00,0x01,0x00,0x00,0x00,0x00, 0x21,0xFE,50])
        + Data(repeating: 0x41, count: 50) + Data([0x00,0x3B])
    let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: 80) + Data("%%EOF\n".utf8)
    let ftyp = be32(24) + Data("ftyp".utf8) + Data("isom".utf8) + be32(0) + Data("isommp41".utf8)
    let mdat = be32(1_000) + Data("mdat".utf8) + Data(repeating: 0x22, count: 992)
    let moov = be32(8) + Data("moov".utf8)
    let mp4 = ftyp + mdat + moov
    let mkv = Data([0x1A,0x45,0xDF,0xA3,0x80, 0x18,0x53,0x80,0x67,0x44,0x4C]) + Data(repeating: 0, count: 1_100)

    var tiff = Data(repeating: 0, count: 328)
    tiff.replaceSubrange(0..<8, with: Data([0x49,0x49,0x2A,0x00,0x08,0x00,0x00,0x00]))
    tiff[8] = 2
    // StripOffsets = 128.
    tiff.replaceSubrange(10..<22, with: Data([0x11,0x01,0x04,0x00,0x01,0x00,0x00,0x00,0x80,0x00,0x00,0x00]))
    // StripByteCounts = 200.
    tiff.replaceSubrange(22..<34, with: Data([0x17,0x01,0x04,0x00,0x01,0x00,0x00,0x00,0xC8,0x00,0x00,0x00]))

    let samples: [(String, Data)] = [("png", png), ("gif", gif), ("pdf", pdf), ("mp4", mp4), ("mkv", mkv), ("raw", tiff)]
    var volume = Data()
    var expected: [(offset: UInt64, ext: String, data: Data)] = []
    for sample in samples {
        volume.append(Data(repeating: 0, count: 64))
        expected.append((UInt64(volume.count), sample.0, sample.1))
        volume.append(sample.1)
    }

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("format-carver-test-\(UUID().uuidString)")
    try volume.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let result = try await RecoveryEngine().scan(device: Device(id: file.path, name: "Formats", path: file.path, isRemovable: true, isReadOnly: true)) { _ in }

    #expect(result.count == expected.count)
    for item in expected {
        let recovered = result.first { $0.offset == item.offset }
        #expect(recovered?.fileExtension == item.ext)
        #expect(recovered?.size == UInt64(item.data.count))
        #expect(recovered?.data == item.data)
    }
}
