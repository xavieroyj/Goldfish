import Foundation
import Testing
@testable import Goldfish

// Each parser must return the exact size of a well-formed file, ignore bytes
// after it, and reject truncated or inconsistent structures instead of
// guessing, since a wrong size exports a corrupt file.

private func tiffHeader(bigEndian: Bool, entries: [(tag: UInt16, type: UInt16, count: UInt32, value: UInt32)], nextIFD: UInt32 = 0, size: Int = 328) -> Data {
    var data = Data(repeating: 0, count: size)
    func u16(_ value: UInt16) -> Data { bigEndian ? be16(value) : Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    func u32(_ value: UInt32) -> Data { bigEndian ? be32(value) : Data(be32(value).reversed()) }
    data.put((bigEndian ? Data("MM".utf8) : Data("II".utf8)) + u16(42) + u32(8), at: 0)
    var table = u16(UInt16(entries.count))
    for entry in entries { table += u16(entry.tag) + u16(entry.type) + u32(entry.count) + u32(entry.value) }
    table += u32(nextIFD)
    data.put(table, at: 8)
    return data
}

// MARK: JPEG

@Test func jpegSizeStopsAtEndOfImage() throws {
    let jpeg = minimalJPEG()
    #expect(try carvedSize(.jpeg, jpeg + noise(count: 300, seed: 10)) == UInt64(jpeg.count))
}

@Test func jpegScanDataMayContainStuffedBytesAndRestartMarkers() throws {
    var scan = Data(repeating: 0x20, count: 50)
    scan += Data([0xFF, 0x00])                      // stuffed 0xFF
    scan += Data(repeating: 0x21, count: 50)
    scan += Data([0xFF, 0xD0])                      // restart marker
    scan += Data(repeating: 0x22, count: 50)
    scan += Data([0xFF, 0xFF, 0xD1])                // fill byte, then restart marker
    scan += Data(repeating: 0x23, count: 10)
    let jpeg = minimalJPEG(scanData: scan)
    #expect(try carvedSize(.jpeg, jpeg + Data(count: 64)) == UInt64(jpeg.count))
}

@Test func jpegWithoutEndOfImageIsRejected() throws {
    let jpeg = minimalJPEG()
    #expect(try carvedSize(.jpeg, jpeg.dropLast(2)) == nil)
}

@Test func jpegWithoutFrameHeaderIsRejected() throws {
    let sos = Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
    #expect(try carvedSize(.jpeg, Data([0xFF, 0xD8]) + sos + Data(repeating: 0x20, count: 200) + Data([0xFF, 0xD9])) == nil)
}

@Test func jpegSegmentLongerThanTheDataIsRejected() throws {
    let app = Data([0xFF, 0xE1, 0xFF, 0xF0]) + Data(repeating: 0, count: 20)
    #expect(try carvedSize(.jpeg, Data([0xFF, 0xD8]) + app) == nil)
}

@Test func exifThumbnailSearchSurvivesEveryTruncation() throws {
    // Photo headers are cut at 2 MB, so the thumbnail parser sees partial files.
    let thumbnail = minimalJPEG()
    let exif = Data("Exif".utf8) + Data([0, 0])
        + Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        + Data([0x00, 0x00, 0x0E, 0x00, 0x00, 0x00])
        + Data([0x02, 0x00])
        + Data([0x01, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00])
        + Data([0x02, 0x02, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, UInt8(thumbnail.count), 0x00, 0x00, 0x00])
        + Data([0x00, 0x00, 0x00, 0x00]) + thumbnail
    let app1 = Data([0xFF, 0xE1]) + be16(UInt16(exif.count + 2)) + exif
    let photo = Data([0xFF, 0xD8]) + app1 + minimalJPEG().dropFirst(2)

    #expect(FormatCarvers.exifJPEGThumbnail(in: photo)?.data == thumbnail)
    for length in 0..<photo.count {
        let result = FormatCarvers.exifJPEGThumbnail(in: Data(photo.prefix(length)))
        #expect(result == nil || result?.data == thumbnail, "prefix \(length)")
    }
}

// MARK: PNG

@Test func pngSizeStopsAtEndChunk() throws {
    let png = minimalPNG()
    #expect(try carvedSize(.png, png + noise(count: 100, seed: 11)) == UInt64(png.count))
}

@Test func pngWithoutEndChunkIsRejected() throws {
    let png = minimalPNG()
    #expect(try carvedSize(.png, png.dropLast(12) + Data(count: 100)) == nil)
}

@Test func pngNotStartingWithHeaderChunkIsRejected() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        + pngChunk("IDAT", payload: Data(count: 13)) + pngChunk("IEND", payload: Data())
    #expect(try carvedSize(.png, png) == nil)
}

@Test func pngChunkLongerThanTheDataIsRejected() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        + pngChunk("IHDR", payload: Data(count: 13)) + be32(0x7FFF_FFFF) + Data("IDAT".utf8) + Data(count: 50)
    #expect(try carvedSize(.png, png) == nil)
}

// MARK: GIF

@Test func gifWithColorTablesAndImageIsSizedToTrailer() throws {
    let gif = Data("GIF89a".utf8) + Data([0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00]) + Data(count: 6)
        + Data([0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80]) + Data(count: 6)
        + Data([0x02, 0x02, 0xAA, 0xBB, 0x00])
        + Data([0x3B])
    #expect(try carvedSize(.gif, gif + noise(count: 64, seed: 12)) == UInt64(gif.count))
}

@Test func gifWithoutTrailerOrWithUnknownVersionIsRejected() throws {
    let body = Data([0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x21, 0xFE, 0x03, 0x41, 0x41, 0x41, 0x00])
    #expect(try carvedSize(.gif, Data("GIF89a".utf8) + body + Data([0x3B])) == UInt64(6 + body.count + 1))
    #expect(try carvedSize(.gif, Data("GIF89a".utf8) + body) == nil)
    #expect(try carvedSize(.gif, Data("GIF88a".utf8) + body + Data([0x3B])) == nil)
}

// MARK: PDF

@Test func pdfSizeIncludesTheLineEndingAfterEndMarker() throws {
    let body = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x20, count: 40) + Data("%%EOF".utf8)
    #expect(try carvedSize(.pdf, body + Data("\r\nJUNK".utf8)) == UInt64(body.count + 2))
    #expect(try carvedSize(.pdf, body + Data("\nJUNK".utf8)) == UInt64(body.count + 1))
    #expect(try carvedSize(.pdf, body) == UInt64(body.count))
}

@Test func pdfEndMarkerSplitAcrossReadBlocksIsFound() throws {
    // The parser reads 1 MiB at a time; put "%%EOF" across that boundary.
    let prefix = Data("%PDF-1.7\n".utf8)
    let body = prefix + Data(repeating: 0x20, count: 1024 * 1024 - prefix.count - 2) + Data("%%EOF".utf8)
    #expect(try carvedSize(.pdf, body + Data(count: 10)) == UInt64(body.count))
}

@Test func pdfWithoutEndMarkerOrVersionIsRejected() throws {
    #expect(try carvedSize(.pdf, Data("%PDF-1.4\n".utf8) + Data(repeating: 0x20, count: 200)) == nil)
    #expect(try carvedSize(.pdf, Data("%PDF-x.4\n%%EOF\n".utf8)) == nil)
}

// MARK: MP4

private func box(_ type: String, _ payload: Data) -> Data { be32(UInt32(8 + payload.count)) + Data(type.utf8) + payload }
private let ftyp = box("ftyp", Data("isom".utf8) + be32(0) + Data("isommp41".utf8))

@Test func mp4SizeEndsAfterLastKnownBox() throws {
    let mp4 = ftyp + box("mdat", Data(repeating: 0x22, count: 500)) + box("moov", Data(count: 20))
    #expect(try carvedSize(.mp4, mp4) == UInt64(mp4.count))
    // An unknown box after media and structure marks the end of the file.
    #expect(try carvedSize(.mp4, mp4 + Data("\u{0}\u{0}\u{0}\u{10}junkjunkjunk".utf8)) == UInt64(mp4.count))
}

@Test func mp4WithLargeSizeBoxIsSized() throws {
    let mdat = be32(1) + Data("mdat".utf8) + be64(16 + 300) + Data(repeating: 0x33, count: 300)
    let mp4 = ftyp + box("moov", Data(count: 8)) + mdat
    #expect(try carvedSize(.mp4, mp4) == UInt64(mp4.count))
}

@Test func incompleteMP4IsRejected() throws {
    // No movie structure, so the media cannot be played.
    #expect(try carvedSize(.mp4, ftyp + box("mdat", Data(count: 100))) == nil)
    // Does not start with ftyp.
    #expect(try carvedSize(.mp4, box("mdat", Data(count: 100)) + box("moov", Data(count: 8))) == nil)
    // A zero size means "to the end of the file", which a carve cannot know.
    #expect(try carvedSize(.mp4, ftyp + be32(0) + Data("mdat".utf8) + Data(count: 100)) == nil)
    // A box claims more bytes than exist.
    #expect(try carvedSize(.mp4, ftyp + be32(10_000) + Data("mdat".utf8) + Data(count: 100)) == nil)
}

// MARK: Matroska

@Test func matroskaSegmentOfUnknownOrExcessiveSizeIsRejected() throws {
    let header = Data([0x1A, 0x45, 0xDF, 0xA3, 0x80, 0x18, 0x53, 0x80, 0x67])
    #expect(try carvedSize(.matroska, header + Data([0x44, 0x4C]) + Data(count: 1100)) == 1111)
    #expect(try carvedSize(.matroska, header + Data([0xFF]) + Data(count: 1100)) == nil)
    #expect(try carvedSize(.matroska, header + Data([0x44, 0x4C]) + Data(count: 500)) == nil)
}

// MARK: TIFF / RAW

@Test func bigEndianTIFFIsSized() throws {
    let tiff = tiffHeader(bigEndian: true, entries: [(273, 4, 1, 128), (279, 4, 1, 200)])
    #expect(try carvedSize(.tiff, tiff + noise(count: 64, seed: 13)) == 328)
}

@Test func tiffWhoseDirectoriesLoopIsStillSized() throws {
    let tiff = tiffHeader(bigEndian: false, entries: [(273, 4, 1, 128), (279, 4, 1, 200)], nextIFD: 8)
    #expect(try carvedSize(.tiff, tiff) == 328)
}

@Test func tiffPointingPastTheDataOrTooSmallIsRejected() throws {
    let pastEnd = tiffHeader(bigEndian: false, entries: [(273, 4, 1, 128), (279, 4, 1, 100_000)])
    #expect(try carvedSize(.tiff, pastEnd) == nil)
    let tooSmall = tiffHeader(bigEndian: false, entries: [(273, 4, 1, 40), (279, 4, 1, 10)])
    #expect(try carvedSize(.tiff, tooSmall) == nil)
}

// MARK: All formats

@Test(arguments: [SignatureFormat.jpeg, .tiff, .png, .gif, .pdf, .matroska, .mp4])
func parsersRejectEmptyAndRandomData(format: SignatureFormat) throws {
    #expect(try carvedSize(format, Data()) == nil)
    for seed in UInt64(1)...20 {
        #expect(try carvedSize(format, noise(count: 4096, seed: seed)) == nil, "seed \(seed)")
    }
}
