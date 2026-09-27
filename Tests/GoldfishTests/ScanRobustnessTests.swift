import Foundation
import Testing
@testable import Goldfish

@Test func scanOfNoiseWithFalseSignaturesStaysWithinTheCard() async throws {
    // Random bytes seeded with every signature marker, plus two real files.
    let markers: [Data] = [
        Data([0xFF, 0xD8, 0xFF]), Data([0x49, 0x49, 0x2A, 0x00]), Data([0x4D, 0x4D, 0x00, 0x2A]),
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), Data("GIF89a".utf8), Data("%PDF-1.".utf8),
        Data([0x1A, 0x45, 0xDF, 0xA3]), Data([0x00, 0x00, 0x00, 0x18]) + Data("ftyp".utf8),
    ]
    var bytes = noise(count: 2 * 1024 * 1024, seed: 42)
    for (index, offset) in stride(from: 4096, to: bytes.count - 64, by: 9_973).enumerated() {
        bytes.put(markers[index % markers.count], at: offset)
    }
    let jpeg = minimalJPEG(), png = minimalPNG()
    let jpegOffset = 100_003, pngOffset = 1_500_007
    bytes.put(Data(count: 16) + jpeg + Data(count: 16), at: jpegOffset - 16)
    bytes.put(Data(count: 16) + png + Data(count: 16), at: pngOffset - 16)
    let image = try TemporaryImage(bytes)

    let files = try await RecoveryEngine().scan(device: image.device()) { _ in }

    let offsets = files.map(\.offset)
    #expect(offsets == offsets.sorted())
    #expect(Set(offsets).count == offsets.count)
    for file in files {
        #expect(file.physicalRanges.allSatisfy { $0.start < $0.end && $0.end <= image.size }, "\(file.name)")
        #expect(try file.readData().count == Int(file.size), "\(file.name)")
    }
    let foundJPEG = try #require(files.first { $0.offset == UInt64(jpegOffset) })
    #expect(try foundJPEG.readData() == jpeg)
    let foundPNG = try #require(files.first { $0.offset == UInt64(pngOffset) })
    #expect(try foundPNG.readData() == png)
}

@Test func fileFoundByBothSignatureAndDeletedEntryIsListedOnceWithItsName() async throws {
    var volume = ExFATImage(clusters: 4)
    let jpeg = minimalJPEG()
    let offset = ExFATImage.offset(ofCluster: 3)
    volume.bytes.put(jpeg, at: offset)
    volume.putFileSet(at: ExFATImage.offset(ofCluster: 2), name: "IMG_0042.JPG", cluster: 3, length: jpeg.count, deleted: true)
    let image = try TemporaryImage(volume.bytes)

    let files = try await RecoveryEngine().scan(device: image.device()) { _ in }

    #expect(files.count == 1)
    let file = try #require(files.first)
    #expect(file.offset == UInt64(offset))
    #expect(file.name == "IMG_0042")
    #expect(file.fileExtension == "jpg")
    #expect(file.status == .deleted)
    #expect(try file.readData() == jpeg)
}

@Test func emptyDeviceCannotBeScanned() async throws {
    let image = try TemporaryImage()
    await #expect(throws: RecoveryError.self) {
        _ = try await RecoveryEngine().scan(device: image.device()) { _ in }
    }
}

@Test func missingDeviceAsksForAccess() async throws {
    let device = Device(mountPath: "/Volumes/Gone", name: "Gone", path: "/dev/goldfish-missing-\(UUID().uuidString)", isRemovable: true, isInternal: false, identifier: "gone", size: 1024)
    let error = await #expect(throws: RecoveryError.self) {
        _ = try await RecoveryEngine().scan(device: device) { _ in }
    }
    guard case .rawAccessRequired = error else {
        Issue.record("Expected rawAccessRequired, got \(String(describing: error))")
        return
    }
}

@Test func cancelledScanStopsWithCancellation() async throws {
    // 1 GiB of sparse space: far too much to finish before the cancel lands.
    let image = try TemporaryImage(size: 1 << 30, writes: [])
    let device = image.device()
    let scan = Task { try await RecoveryEngine().scan(device: device) { _ in } }
    scan.cancel()
    await #expect(throws: CancellationError.self) { _ = try await scan.value }
}
