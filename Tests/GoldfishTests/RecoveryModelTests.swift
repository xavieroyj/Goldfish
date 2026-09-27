import Foundation
import Testing
@testable import Goldfish

private func volume(_ name: String, removable: Bool = true, isInternal: Bool = false) -> Device {
    Device(mountPath: "/Volumes/\(name)", name: name, path: "/dev/rdisk9s1", isRemovable: removable, isInternal: isInternal, identifier: "disk9", size: 1)
}

@Test func selectionKeepsPreviousScannableDevice() {
    let devices = [volume("CARD A"), volume("CARD B")]
    #expect(RecoveryModel.preferredDevice(in: devices, previouslySelectedID: "/Volumes/CARD B")?.name == "CARD B")
}

@Test func selectionPrefersRemovableCardOverOtherVolumes() {
    let devices = [volume("Macintosh HD", removable: false, isInternal: true), volume("Backup", removable: false), volume("Untitled")]
    #expect(RecoveryModel.preferredDevice(in: devices, previouslySelectedID: nil)?.name == "Untitled")
    // A previous selection that has since gone is replaced the same way.
    #expect(RecoveryModel.preferredDevice(in: devices, previouslySelectedID: "/Volumes/Gone")?.name == "Untitled")
}

@Test func selectionNeverPicksInternalDisk() {
    let devices = [volume("Macintosh HD", removable: false, isInternal: true), volume("Backup", removable: false)]
    #expect(RecoveryModel.preferredDevice(in: devices, previouslySelectedID: "/Volumes/Macintosh HD")?.name == "Backup")
    #expect(RecoveryModel.preferredDevice(in: [volume("Macintosh HD", removable: false, isInternal: true)], previouslySelectedID: nil) == nil)
}

@Test(arguments: [
    ("/Volumes/Untitled", true),
    ("/Volumes/Untitled/", true),
    ("/Volumes/Untitled/DCIM/Recovered", true),
    ("/Volumes/Other/../Untitled/Recovered", true),
    ("/Volumes/Untitled 2", false),
    ("/Volumes/UntitledBackup/Recovered", false),
    ("/Users/Shared/Recovered", false),
])
func exportFolderOnSourceCardIsDetected(folder: String, onSource: Bool) {
    #expect(RecoveryModel.isFolder(URL(fileURLWithPath: folder), onVolumeMountedAt: "/Volumes/Untitled") == onSource)
}

@Test func exportFolderReachedThroughSymlinkIsDetected() throws {
    let root = try TemporaryFolder()
    let card = root.url.appendingPathComponent("CARD", isDirectory: true)
    try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
    let link = root.url.appendingPathComponent("Shortcut")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: card)
    #expect(RecoveryModel.isFolder(link.appendingPathComponent("DCIM"), onVolumeMountedAt: card.path))
}

@Test func exportNamesNeverReplaceExistingFiles() throws {
    let folder = try TemporaryFolder()
    let first = RecoveryModel.availableDestination(in: folder.url, name: "IMG_0001", fileExtension: "jpg")
    #expect(first.lastPathComponent == "IMG_0001.jpg")
    try Data().write(to: first)
    let second = RecoveryModel.availableDestination(in: folder.url, name: "IMG_0001", fileExtension: "jpg")
    #expect(second.lastPathComponent == "IMG_0001 (1).jpg")
    try Data().write(to: second)
    #expect(RecoveryModel.availableDestination(in: folder.url, name: "IMG_0001", fileExtension: "jpg").lastPathComponent == "IMG_0001 (2).jpg")
    #expect(RecoveryModel.availableDestination(in: folder.url, name: "README", fileExtension: "").lastPathComponent == "README")
}

@Test func exportWritesEachFileIntoItsKindFolderAndReportsFailures() throws {
    let photo = minimalJPEG()
    let document = Data("%PDF-1.7\n%%EOF\n".utf8)
    let image = try TemporaryImage(photo + document)
    let device = try image.rawDevice()
    func file(_ name: String, _ kind: FileKind, _ ext: String, _ range: ScannedRange) -> RecoveredFile {
        RecoveredFile(name: name, kind: kind, offset: range.start, size: range.end - range.start, recoverySource: .signatureScan, status: .noRecord, fileExtension: ext, device: device, metadata: [:], physicalRanges: [range])
    }
    let photoRange = ScannedRange(start: 0, end: UInt64(photo.count))
    let files = [
        file("IMG", .image, "jpg", photoRange),
        file("IMG", .image, "jpg", photoRange),
        file("Notes", .document, "pdf", ScannedRange(start: UInt64(photo.count), end: UInt64(photo.count + document.count))),
        // Points past the end of the card, so it cannot be read in full.
        file("Broken", .video, "mp4", ScannedRange(start: image.size - 4, end: image.size + 100)),
    ]
    let folder = try TemporaryFolder()

    let failures = RecoveryModel.write(files, to: folder.url)

    #expect(failures.count == 1)
    #expect(failures.first?.contains("Broken.mp4") == true)
    #expect(try Data(contentsOf: folder.url.appendingPathComponent("Photos/IMG.jpg")) == photo)
    #expect(try Data(contentsOf: folder.url.appendingPathComponent("Photos/IMG (1).jpg")) == photo)
    #expect(try Data(contentsOf: folder.url.appendingPathComponent("Documents/Notes.pdf")) == document)
    #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Videos/Broken.mp4").path))
}

// MARK: - Scan lifecycle

@MainActor private func waitForScanToFinish(_ model: RecoveryModel) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while model.scanning {
        guard ContinuousClock.now < deadline else {
            Issue.record("Scan did not finish")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A FAT32 card with a photo still on the card (cluster 3), a deleted photo
/// (cluster 5) and a photo no directory entry points to (cluster 6).
@MainActor private func scannedCardWithEveryStatus() async throws -> (RecoveryModel, TemporaryImage) {
    var volume = FAT32Image(clusters: 5)
    let jpeg = minimalJPEG()
    volume.setFAT(3, 0x0FFF_FFFF)
    volume.putShortEntry(at: FAT32Image.offset(ofCluster: 2), shortName: "PIC0001 JPG", cluster: 3, size: jpeg.count)
    volume.putShortEntry(at: FAT32Image.offset(ofCluster: 2) + 32, shortName: "PIC0002 JPG", cluster: 5, size: jpeg.count, deleted: true)
    for cluster in [3, 5, 6] { volume.bytes.put(jpeg, at: FAT32Image.offset(ofCluster: cluster)) }
    let image = try TemporaryImage(volume.bytes)
    let model = RecoveryModel(refreshDevices: false)
    model.selected = image.device()
    model.start()
    try await waitForScanToFinish(model)
    return (model, image)
}

@MainActor @Test func callbacksFromAnotherScanAreIgnored() async throws {
    let card = try TemporaryImage(size: 1 << 30, writes: [])   // still scanning when the checks run
    let photo = try TemporaryImage(minimalJPEG())
    let staleFile = try #require(try await RecoveryEngine().scan(device: photo.device()) { _ in }.first)
    let model = RecoveryModel(refreshDevices: false)
    model.selected = card.device()
    model.start()
    defer { model.stop() }

    let staleID = UUID()
    model.receive(candidate: staleFile, scanID: staleID)
    model.receive(progress: ScanProgress(bytesRead: 1, total: 1, found: 1), scanID: staleID)
    model.finishScan(staleID, result: [staleFile])
    model.failScan(staleID, error: RecoveryError.cannotRead)
    try await Task.sleep(for: .milliseconds(200))              // past the 80 ms update batching

    #expect(model.scanning)
    #expect(model.files.isEmpty)
    #expect(model.progress.found == 0)
    #expect(model.diagnostic.isEmpty)
}

@MainActor @Test func stoppingThenScanningAgainShowsOnlyTheNewCard() async throws {
    let first = try TemporaryImage(Data(count: 4096) + minimalJPEG() + Data(count: 4096))
    let second = try TemporaryImage(Data(count: 8192) + minimalJPEG() + Data(count: 4096))
    let model = RecoveryModel(refreshDevices: false)

    model.selected = first.device(name: "First")
    model.start()
    model.stop()
    #expect(!model.scanning)
    #expect(model.message == "Scan cancelled")

    model.selected = second.device(name: "Second")
    model.start()
    try await waitForScanToFinish(model)
    // Give any late callbacks from the stopped scan time to arrive.
    try await Task.sleep(for: .milliseconds(200))

    #expect(model.files.map(\.offset) == [8192])
    #expect(model.message == "Scan complete · 1 potential file candidates")
}

@MainActor @Test func filesStillOnCardAreHiddenAndDeselectedUnlessShown() async throws {
    let (model, _) = try await scannedCardWithEveryStatus()
    #expect(model.filesStillOnCardCount == 1)
    #expect(model.files.map(\.status) == [.deleted, .noRecord])

    model.showFilesStillOnCard = true
    #expect(model.files.map(\.status) == [.stillOnCard, .deleted, .noRecord])
    model.toggleSelection(for: model.files)
    #expect(model.selectedFiles.count == 3)

    // Hidden files must not be exported, so they leave the selection too.
    model.showFilesStillOnCard = false
    #expect(model.selectedFiles.map(\.status) == [.deleted, .noRecord])
    #expect(model.selectedFileIDs.count == 2)
}

@MainActor @Test func selectionTogglesAndResetsForANewScan() async throws {
    let (model, _) = try await scannedCardWithEveryStatus()
    let files = model.files
    model.toggleSelection(for: files[0])
    #expect(model.selectedFileIDs == [files[0].id])
    // With only some selected, "select all" selects the rest…
    model.toggleSelection(for: files)
    #expect(model.selectedFileIDs == Set(files.map(\.id)))
    // …and with all selected, it clears them.
    model.toggleSelection(for: files)
    #expect(model.selectedFileIDs.isEmpty)
    model.toggleSelection(for: files[1])
    model.toggleSelection(for: files[1])
    #expect(model.selectedFileIDs.isEmpty)

    model.toggleSelection(for: files)
    model.start()
    #expect(model.selectedFileIDs.isEmpty)
    #expect(model.files.isEmpty)
    try await waitForScanToFinish(model)
}

@MainActor @Test func scanWithNothingFoundSaysSo() async throws {
    let image = try TemporaryImage(Data(count: 64 * 1024))
    let model = RecoveryModel(refreshDevices: false)
    model.selected = image.device()
    model.start()
    try await waitForScanToFinish(model)
    #expect(model.files.isEmpty)
    #expect(model.message == "No file candidates found")
}

@MainActor @Test func unreadableDeviceOpensPermissionHelp() async throws {
    let model = RecoveryModel(refreshDevices: false)
    model.selected = Device(mountPath: "/Volumes/Gone", name: "Gone", path: "/dev/goldfish-missing-\(UUID().uuidString)", isRemovable: true, isInternal: false, identifier: "gone", size: 1024)
    model.start()
    try await waitForScanToFinish(model)
    #expect(model.permissionHelp)
    #expect(model.message.contains("cannot open the SD-card device"))
    #expect(model.files.isEmpty)
}

@MainActor @Test func internalDiskIsNeverScanned() {
    let model = RecoveryModel(refreshDevices: false)
    model.selected = volume("Macintosh HD", removable: false, isInternal: true)
    model.start()
    #expect(!model.scanning)
    #expect(model.message == "Ready to scan")
}

@Test func progressNeverMovesBackwards() {
    let current = ScanProgress(bytesRead: 100, total: 1000, found: 5)
    #expect(RecoveryModel.canReplace(current, with: ScanProgress(bytesRead: 200, total: 1000, found: 5)))
    #expect(RecoveryModel.canReplace(current, with: ScanProgress(bytesRead: 100, total: 1000, found: 5)))
    #expect(!RecoveryModel.canReplace(current, with: ScanProgress(bytesRead: 90, total: 1000, found: 6)))
    #expect(!RecoveryModel.canReplace(current, with: ScanProgress(bytesRead: 300, total: 1000, found: 4)))
}
