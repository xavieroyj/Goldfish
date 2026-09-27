import Foundation
import Testing
@testable import Goldfish

// MARK: - RawDevice

@Test func rawDeviceReadsAreShortenedOnlyAtTheEnd() throws {
    let bytes = noise(count: 1000, seed: 1)
    let device = try TemporaryImage(bytes).rawDevice()
    #expect(try device.read(at: 100, count: 50) == bytes[100..<150])
    #expect(try device.read(at: 990, count: 50) == bytes[990..<1000])
    #expect(try device.read(at: 1000, count: 10).isEmpty)
    #expect(try device.read(at: 5000, count: 10).isEmpty)
    #expect(try device.read(at: 10, count: 0).isEmpty)
}

@Test func rawDeviceReportsMissingDeviceAsAccessProblem() {
    let error = #expect(throws: RecoveryError.self) {
        _ = try RawDevice(path: "/dev/goldfish-missing-\(UUID().uuidString)", total: 512)
    }
    guard case .rawAccessRequired = error else {
        Issue.record("Expected rawAccessRequired, got \(String(describing: error))")
        return
    }
}

@Test func copyNeverReplacesAnExistingFile() throws {
    let device = try TemporaryImage(noise(count: 512, seed: 2)).rawDevice()
    let folder = try TemporaryFolder()
    let destination = folder.url.appendingPathComponent("existing.jpg")
    let original = Data("keep me".utf8)
    try original.write(to: destination)

    #expect(throws: RecoveryError.self) {
        try device.copy([ScannedRange(start: 0, end: 512)], size: 512, to: destination)
    }
    #expect(try Data(contentsOf: destination) == original)
}

@Test func copyThatEndsEarlyLeavesNoPartialFile() throws {
    let device = try TemporaryImage(noise(count: 512, seed: 3)).rawDevice()
    let folder = try TemporaryFolder()
    let destination = folder.url.appendingPathComponent("partial.jpg")

    #expect(throws: RecoveryError.self) {
        try device.copy([ScannedRange(start: 256, end: 1024)], size: 768, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func copyJoinsRangesInFileOrder() throws {
    let bytes = noise(count: 10 * 1024 * 1024, seed: 4)
    let device = try TemporaryImage(bytes).rawDevice()
    let folder = try TemporaryFolder()
    let destination = folder.url.appendingPathComponent("joined.bin")
    // Larger than the 4 MiB copy chunk, and stored out of order on the device.
    let ranges = [ScannedRange(start: 6_000_000, end: 10_000_000), ScannedRange(start: 100, end: 1_000_100)]

    try device.copy(ranges, size: 5_000_000, to: destination)

    #expect(try Data(contentsOf: destination) == bytes[6_000_000..<10_000_000] + bytes[100..<1_000_100])
}

// MARK: - ChunkCache and CarveReader

@Test func chunkCacheReturnsTheSameBytesAsTheDevice() throws {
    let chunk = Int(ChunkCache.chunkSize)
    let bytes = noise(count: 2 * chunk + 1000, seed: 5)
    let device = try TemporaryImage(bytes).rawDevice()
    let cache = ChunkCache(device: device)
    let reads: [(offset: Int, count: Int)] = [
        (0, 100),
        (chunk - 10, 20),                // across one chunk boundary
        (100, 2 * chunk),                // across two boundaries
        (0, chunk),                      // exactly one whole chunk
        (2 * chunk + 900, 500),          // runs past the end
    ]
    for read in reads {
        let expected = bytes[read.offset..<min(bytes.count, read.offset + read.count)]
        #expect(try cache.read(at: UInt64(read.offset), count: read.count) == expected, "offset \(read.offset), count \(read.count)")
    }
    #expect(try cache.read(at: UInt64(bytes.count), count: 10).isEmpty)

    // Discarded chunks are read again from the device when needed.
    cache.discard(below: UInt64(2 * chunk))
    #expect(try cache.read(at: 10, count: 10) == bytes[10..<20])
}

@Test func chunkCacheStaysCorrectAfterEvictingChunks() throws {
    // Twelve chunks, more than the cache keeps, each tagged at its start.
    let chunk = ChunkCache.chunkSize
    let writes = (0..<12).map { (offset: UInt64($0) * chunk, data: Data([UInt8($0 + 1), 0xAB])) }
    let image = try TemporaryImage(size: 12 * chunk, writes: writes)
    let cache = ChunkCache(device: try image.rawDevice())
    for index in 0..<12 {
        #expect(try cache.read(at: UInt64(index) * chunk, count: 2) == Data([UInt8(index + 1), 0xAB]))
    }
    #expect(try cache.read(at: 0, count: 2) == Data([1, 0xAB]))
}

@Test func carveReaderRefusesReadsPastItsLimit() throws {
    let bytes = noise(count: 4096, seed: 6)
    let cache = ChunkCache(device: try TemporaryImage(bytes).rawDevice())
    let reader = CarveReader(cache: cache, base: 1000, limit: 100)
    #expect(reader.read(0, 100) == bytes[1000..<1100])
    #expect(reader.read(50, 51) == nil)
    #expect(reader.read(101, 0) == nil)
    #expect(reader.byte(99) == bytes[1099])
    #expect(reader.byte(100) == nil)
}

// MARK: - RecoveredFile

private func recovered(_ device: RawDevice, ranges: [ScannedRange]) -> RecoveredFile {
    RecoveredFile(name: "file", kind: .unknown, offset: ranges[0].start, size: ranges.reduce(0) { $0 + $1.end - $1.start }, recoverySource: .deletedFileRecord, status: .deleted, fileExtension: "bin", device: device, metadata: [:], physicalRanges: ranges)
}

@Test func fragmentedFileReadsAcrossItsRanges() throws {
    let bytes = noise(count: 100, seed: 7)
    let device = try TemporaryImage(bytes).rawDevice()
    let file = recovered(device, ranges: [ScannedRange(start: 10, end: 20), ScannedRange(start: 50, end: 55)])
    let content = Data(bytes[10..<20]) + Data(bytes[50..<55])

    #expect(file.isFragmented)
    #expect(try file.readData() == content)
    #expect(try file.read(at: 8, count: 4) == content[8..<12])
    #expect(try file.read(at: 14, count: 10) == content[14..<15])
    #expect(try file.read(at: 15, count: 10).isEmpty)

    let folder = try TemporaryFolder()
    let destination = folder.url.appendingPathComponent("out.bin")
    try file.write(to: destination)
    #expect(try Data(contentsOf: destination) == content)
}

@Test func fileRunningPastTheDeviceFailsToRead() throws {
    let device = try TemporaryImage(noise(count: 100, seed: 8)).rawDevice()
    let file = recovered(device, ranges: [ScannedRange(start: 90, end: 120)])
    #expect(throws: RecoveryError.self) { try file.readData() }
}

@Test func generatedNamesUseTheHexOffset() {
    #expect(RecoveredFile.generatedName(offset: 0x1A) == "Recovered_00001A")
    #expect(RecoveredFile.generatedName(offset: 0x10F30C0) == "Recovered_10F30C0")
}

@Test(arguments: [
    ("PIC0001.JPG", "PIC0001", "jpg"),
    ("archive.tar.GZ", "archive.tar", "gz"),
    ("README", "README", "bin"),
    ("../../private/etc/evil.JPG", "evil", "jpg"),
    ("DCIM/100FUJI/DSCF0001.RAF", "DSCF0001", "raf"),
    ("..", "file", "bin"),
    (".", "file", "bin"),
    ("", "file", "bin"),
])
func originalFilenamesCannotEscapeTheExportFolder(filename: String, name: String, fileExtension: String) throws {
    var file = recovered(try TemporaryImage(Data(count: 16)).rawDevice(), ranges: [ScannedRange(start: 0, end: 16)])
    file.applyOriginalFilename(filename)
    #expect(file.name == name)
    #expect(file.fileExtension == fileExtension)
}

// MARK: - Models

@Test(arguments: [
    ("JPG", FileKind.image), ("heic", .image), ("MOV", .video), ("mkv", .video),
    ("pdf", .document), ("flac", .audio), ("NEF", .raw), ("dng", .raw),
    ("xyz", .unknown), ("", .unknown),
])
func fileKindsFollowExtensions(fileExtension: String, kind: FileKind) {
    #expect(FileKind.from(fileExtension: fileExtension) == kind)
}

@Test func mediaErrorsAreSkippedButAccessErrorsStopTheScan() {
    // Skippable: the card returned bad data for some sectors.
    #expect(RecoveryError.readFailed("/dev/rdisk4s1", EIO).isMediaError)
    #expect(RecoveryError.readFailed("/dev/rdisk4s1", 9999).isMediaError)
    #expect(RecoveryError.incompleteRead("/dev/rdisk4s1", offset: 0).isMediaError)
    // Not skippable: every further read would fail the same way.
    for code in [EINVAL, EACCES, EPERM, EBADF, ENXIO, ENODEV, ENOTSUP] {
        #expect(!RecoveryError.readFailed("/dev/rdisk4s1", code).isMediaError, "errno \(code)")
    }
    #expect(!RecoveryError.deviceDisconnected("/dev/rdisk4s1").isMediaError)
    #expect(!RecoveryError.rawAccessRequired("/dev/rdisk4s1").isMediaError)
    #expect(!RecoveryError.cannotRead.isMediaError)
}

// MARK: - Scan progress

@Test func progressReporterMergesRangesAndClipsToTheDevice() async {
    let reporter = ScanProgressReporter(total: 100)
    _ = await reporter.addBytes(10, at: 20)
    _ = await reporter.addBytes(10, at: 0)
    _ = await reporter.addBytes(10, at: 10)   // joins both neighbours
    _ = await reporter.addBytes(5, at: 50)
    let progress = await reporter.addBytes(20, at: 90)  // runs past the end
    #expect(progress.scannedRanges == [ScannedRange(start: 0, end: 30), ScannedRange(start: 50, end: 55), ScannedRange(start: 90, end: 100)])
    #expect(progress.bytesRead <= progress.total)
}

@Test func progressReporterCountsEachCandidateOnce() async throws {
    let device = try TemporaryImage(Data(count: 100)).rawDevice()
    let reporter = ScanProgressReporter(total: 100)
    let first = recovered(device, ranges: [ScannedRange(start: 10, end: 20)])
    let sameOffset = recovered(device, ranges: [ScannedRange(start: 10, end: 20)])
    let other = recovered(device, ranges: [ScannedRange(start: 40, end: 50)])

    #expect(await reporter.addCandidate(first)?.found == 1)
    #expect(await reporter.addCandidate(sameOffset) == nil)
    let final = await reporter.addRecoveredFiles([first, other])
    #expect(final.found == 2)
    #expect(final.candidateRanges == [ScannedRange(start: 10, end: 20), ScannedRange(start: 40, end: 50)])
}

@Test func progressReporterTracksReadErrors() async {
    let reporter = ScanProgressReporter(total: 100)
    #expect(await reporter.hasReadErrors == false)
    let progress = await reporter.addReadError(ScannedRange(start: 30, end: 40))
    #expect(await reporter.hasReadErrors == true)
    #expect(progress.readErrors == [ScannedRange(start: 30, end: 40)])
}

@Test func progressSeparatesScannedErrorAndUnscannedSpace() {
    let progress = ScanProgress(
        bytesRead: 50, total: 100, found: 1,
        scannedRanges: [ScannedRange(start: 0, end: 30), ScannedRange(start: 60, end: 80)],
        candidateRanges: [ScannedRange(start: 25, end: 65)],
        readErrors: [ScannedRange(start: 30, end: 40)]
    )
    #expect(progress.fraction == 0.5)
    #expect(progress.scannedWithoutCandidates == [ScannedRange(start: 0, end: 25), ScannedRange(start: 65, end: 80)])
    #expect(progress.unscannedRanges == [ScannedRange(start: 40, end: 60), ScannedRange(start: 80, end: 100)])
    #expect(ScanProgress.empty.fraction == 0)
}
