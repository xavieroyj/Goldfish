import Foundation
import Testing
@testable import Goldfish

private func index(_ bytes: Data) throws -> FileSystemIndex {
    let image = try TemporaryImage(bytes)
    return FileSystemIndex.load(from: try image.rawDevice())
}

private func isEmpty(_ index: FileSystemIndex) -> Bool {
    index.namesByOffset.isEmpty && index.liveOffsets.isEmpty && index.deletedOffsets.isEmpty && index.deletedFiles.isEmpty
}

// MARK: Unrecognised volumes

@Test func unrecognisedVolumesGiveAnEmptyIndex() throws {
    #expect(isEmpty(try index(Data())))
    #expect(isEmpty(try index(Data(count: 100))))
    #expect(isEmpty(try index(Data(count: 4096))))
    for seed in UInt64(1)...10 {
        #expect(isEmpty(try index(noise(count: 4096, seed: seed))), "seed \(seed)")
    }
}

@Test func fat32BootSectorWithImpossibleGeometryIsIgnored() throws {
    var image = FAT32Image(clusters: 4)
    image.bytes.putLE(UInt16(300), at: 11)          // not a valid sector size
    #expect(isEmpty(try index(image.bytes)))

    image = FAT32Image(clusters: 4)
    image.bytes[13] = 3                              // sectors per cluster must be a power of two
    #expect(isEmpty(try index(image.bytes)))

    image = FAT32Image(clusters: 4)
    image.bytes.putLE(UInt16(512), at: 17)          // FAT12/16 root entry count
    #expect(isEmpty(try index(image.bytes)))
}

// MARK: FAT32

@Test func fat32LongFilenamesAreUsed() throws {
    var image = FAT32Image(clusters: 4)
    image.setFAT(3, 0x0FFF_FFFF)
    image.putLongNameEntry(at: FAT32Image.offset(ofCluster: 2), name: "Holiday photo 2026-09-25.jpeg", shortName: "HOLIDA~1JPE", cluster: 3, size: 100)
    let result = try index(image.bytes)
    let offset = UInt64(FAT32Image.offset(ofCluster: 3))
    #expect(result.namesByOffset[offset] == "Holiday photo 2026-09-25.jpeg")
    #expect(result.status(at: offset) == .stillOnCard)
}

@Test func fat32SubdirectoriesAreWalked() throws {
    var image = FAT32Image(clusters: 5)
    let root = FAT32Image.offset(ofCluster: 2)
    let dcim = FAT32Image.offset(ofCluster: 4)
    image.setFAT(4, 0x0FFF_FFFF)
    image.setFAT(5, 0x0FFF_FFFF)
    image.putShortEntry(at: root, shortName: "DCIM       ", attributes: 0x10, cluster: 4, size: 0)
    // "." and ".." point back at this folder and the root; they must not loop.
    image.putShortEntry(at: dcim, shortName: ".          ", attributes: 0x10, cluster: 4, size: 0)
    image.putShortEntry(at: dcim + 32, shortName: "..         ", attributes: 0x10, cluster: 2, size: 0)
    image.putShortEntry(at: dcim + 64, shortName: "DSCF0001JPG", cluster: 5, size: 300)
    let result = try index(image.bytes)
    #expect(result.namesByOffset[UInt64(FAT32Image.offset(ofCluster: 5))] == "DSCF0001.JPG")
}

@Test func fat32DirectoryChainThatLoopsIsReadOnce() throws {
    var image = FAT32Image(clusters: 4)
    image.setFAT(2, 3)
    image.setFAT(3, 2)                               // root: 2 → 3 → 2 → …
    image.putShortEntry(at: FAT32Image.offset(ofCluster: 2), shortName: "LOOP    TXT", cluster: 4, size: 10)
    image.setFAT(4, 0x0FFF_FFFF)
    let result = try index(image.bytes)
    #expect(result.namesByOffset[UInt64(FAT32Image.offset(ofCluster: 4))] == "LOOP.TXT")
}

@Test func deletedFat32FileWithLoopingChainIsNotRecovered() throws {
    var image = FAT32Image(clusters: 6)
    image.setFAT(3, 4)
    image.setFAT(4, 3)                               // 3 → 4 → 3 → …
    image.putShortEntry(at: FAT32Image.offset(ofCluster: 2), shortName: "XLOOPS  BIN", cluster: 3, size: 1500, deleted: true)
    let result = try index(image.bytes)
    #expect(result.deletedFiles.isEmpty)
    #expect(result.status(at: UInt64(FAT32Image.offset(ofCluster: 3))) == .deleted)
}

@Test func deletedFat32FileLargerThanTheCardIsNotRecovered() throws {
    var image = FAT32Image(clusters: 4)
    image.putShortEntry(at: FAT32Image.offset(ofCluster: 2), shortName: "XHUGE   MOV", cluster: 3, size: 50_000_000, deleted: true)
    #expect(try index(image.bytes).deletedFiles.isEmpty)
}

@Test func deletedFat32FileKeepsOnlyItsExtension() throws {
    var image = FAT32Image(clusters: 4)
    image.putShortEntry(at: FAT32Image.offset(ofCluster: 2), shortName: "XIC0001 JPG", cluster: 3, size: 1000, deleted: true)
    let record = try #require(try index(image.bytes).deletedFiles.first)
    let offset = UInt64(FAT32Image.offset(ofCluster: 3))
    #expect(record.name == RecoveredFile.generatedName(offset: offset))
    #expect(record.fileExtension == "jpg")
    #expect(record.isContiguousEstimate)
}

// MARK: exFAT

@Test func exFATLiveFilesAreNamedAndMarkedStillOnCard() throws {
    var image = ExFATImage(clusters: 4)
    image.setFAT(3, 0xFFFF_FFFF)
    image.putFileSet(at: ExFATImage.offset(ofCluster: 2), name: "DSCF0001.JPG", cluster: 3, length: 400)
    let result = try index(image.bytes)
    let offset = UInt64(ExFATImage.offset(ofCluster: 3))
    #expect(result.namesByOffset[offset] == "DSCF0001.JPG")
    #expect(result.status(at: offset) == .stillOnCard)
    #expect(result.deletedFiles.isEmpty)
}

@Test func deletedExFATFileFollowsItsFATChain() throws {
    var image = ExFATImage(clusters: 5)
    image.setFAT(3, 5)
    image.setFAT(5, 0xFFFF_FFFF)
    image.putFileSet(at: ExFATImage.offset(ofCluster: 2), name: "CLIP.MP4", cluster: 3, length: 700, deleted: true, contiguous: false)
    let record = try #require(try index(image.bytes).deletedFiles.first)
    let third = UInt64(ExFATImage.offset(ofCluster: 3)), fifth = UInt64(ExFATImage.offset(ofCluster: 5))
    #expect(record.extents == [ScannedRange(start: third, end: third + 512), ScannedRange(start: fifth, end: fifth + 188)])
    #expect(record.filename == "CLIP.mp4")
    #expect(!record.isContiguousEstimate)
}

@Test func exFATSubdirectoriesAreWalked() throws {
    var image = ExFATImage(clusters: 4)
    image.setFAT(3, 0xFFFF_FFFF)
    image.setFAT(4, 0xFFFF_FFFF)
    image.putFileSet(at: ExFATImage.offset(ofCluster: 2), name: "DCIM", cluster: 3, length: 512, directory: true)
    image.putFileSet(at: ExFATImage.offset(ofCluster: 3), name: "DSCF0002.RAF", cluster: 4, length: 100)
    #expect(try index(image.bytes).namesByOffset[UInt64(ExFATImage.offset(ofCluster: 4))] == "DSCF0002.RAF")
}

@Test(arguments: [".", "..", "", "/"])
func deletedExFATFileWithUnusableNameGetsGeneratedName(name: String) throws {
    var image = ExFATImage(clusters: 4)
    image.putFileSet(at: ExFATImage.offset(ofCluster: 2), name: name, cluster: 3, length: 100, deleted: true)
    let record = try #require(try index(image.bytes).deletedFiles.first)
    #expect(record.name == RecoveredFile.generatedName(offset: UInt64(ExFATImage.offset(ofCluster: 3))))
    #expect(record.fileExtension == "")
}

@Test func liveFileReusingDeletedFilesSpaceOwnsTheName() throws {
    var image = ExFATImage(clusters: 4)
    image.setFAT(3, 0xFFFF_FFFF)
    let next = image.putFileSet(at: ExFATImage.offset(ofCluster: 2), name: "OLD.MOV", cluster: 3, length: 400, deleted: true)
    image.putFileSet(at: next, name: "NEW.JPG", cluster: 3, length: 400)
    let result = try index(image.bytes)
    let offset = UInt64(ExFATImage.offset(ofCluster: 3))
    #expect(result.namesByOffset[offset] == "NEW.JPG")
    #expect(result.status(at: offset) == .stillOnCard)
    #expect(result.deletedFiles.isEmpty)
}
