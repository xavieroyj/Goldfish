import Foundation

private struct Signature: Sendable {
    let marker: [UInt8]
    let format: SignatureFormat
    let kind: FileKind
    let ext: String
    let minSize: UInt64
    let maxSize: UInt64
    /// How far before the marker the file actually starts (the MP4 `ftyp`
    /// marker follows a 4-byte box size).
    let startAdjustment: UInt64
}

public actor RecoveryEngine {
    /// Each worker scans one range with its own descriptor so the card reader
    /// can service independent requests in parallel.
    private static let scanRangeSize: UInt64 = 64 * 1024 * 1024
    private static let scanBlockSize: UInt64 = 4 * 1024 * 1024
    private static let retryBlockSize: UInt64 = 64 * 1024
    private static let maximumWorkers = 4
    /// How much of a photo is read for EXIF metadata and the embedded thumbnail.
    private static let photoHeaderSize: UInt64 = 2 * 1024 * 1024

    private static let signatures: [Signature] = [
        Signature(marker: [0xFF, 0xD8, 0xFF], format: .jpeg, kind: .image, ext: "jpg", minSize: 128, maxSize: 50_000_000, startAdjustment: 0),
        Signature(marker: [0x49, 0x49, 0x2A, 0x00], format: .tiff, kind: .raw, ext: "raw", minSize: 256, maxSize: 200_000_000, startAdjustment: 0),
        Signature(marker: [0x4D, 0x4D, 0x00, 0x2A], format: .tiff, kind: .raw, ext: "raw", minSize: 256, maxSize: 200_000_000, startAdjustment: 0),
        Signature(marker: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], format: .png, kind: .image, ext: "png", minSize: 128, maxSize: 100_000_000, startAdjustment: 0),
        Signature(marker: [0x47, 0x49, 0x46, 0x38], format: .gif, kind: .image, ext: "gif", minSize: 64, maxSize: 100_000_000, startAdjustment: 0),
        Signature(marker: [0x25, 0x50, 0x44, 0x46], format: .pdf, kind: .document, ext: "pdf", minSize: 64, maxSize: 200_000_000, startAdjustment: 0),
        Signature(marker: [0x1A, 0x45, 0xDF, 0xA3], format: .matroska, kind: .video, ext: "mkv", minSize: 1024, maxSize: 4_000_000_000, startAdjustment: 0),
        Signature(marker: [0x66, 0x74, 0x79, 0x70], format: .mp4, kind: .video, ext: "mp4", minSize: 1024, maxSize: 4_000_000_000, startAdjustment: 4)
    ]
    private static let signatureOverlap = signatures.map(\.marker.count).max()! - 1

    /// Maps a marker's first byte to its signature so the scan loop can test
    /// every signature in one pass. Entries are `signatureIndex + 1`; zero
    /// means no signature starts with that byte. A plain byte table keeps the
    /// hot loop fast in debug builds too.
    private static let signatureSlotByFirstByte: [UInt8] = {
        precondition(signatures.count < Int(UInt8.max), "Too many signatures for the byte lookup table")
        var table = [UInt8](repeating: 0, count: 256)
        for (index, signature) in signatures.enumerated() {
            let firstByte = Int(signature.marker[0])
            precondition(table[firstByte] == 0, "Signature markers must start with distinct bytes")
            table[firstByte] = UInt8(index + 1)
        }
        return table
    }()

    public init() {}

    public func scan(device: Device, progress: @escaping @Sendable (ScanProgress) async -> Void, onCandidate: @escaping @Sendable (RecoveredFile) async -> Void = { _ in }) async throws -> [RecoveredFile] {
        let scanStart = DispatchTime.now().uptimeNanoseconds
        let total = device.size
        guard total > 0 else { throw RecoveryError.cannotRead }
        // Every recovered file reads through this descriptor after the scan.
        let sessionDevice = try RawDevice(path: device.path, total: total)

        let ranges = stride(from: UInt64(0), to: total, by: Int(Self.scanRangeSize)).map {
            ScannedRange(start: $0, end: min(total, $0 + Self.scanRangeSize))
        }
        let workerLimit = min(Self.maximumWorkers, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        GoldfishLog.write("Parallel scan starting: \(ranges.count) ranges, worker limit \(workerLimit)")

        let reporter = ScanProgressReporter(total: total)
        var files: [RecoveredFile] = []
        var offsets = Set<UInt64>()
        try await withThrowingTaskGroup(of: [RecoveredFile].self) { group in
            var pending = ranges[...]
            func startNextRange() {
                guard let range = pending.popFirst() else { return }
                group.addTask {
                    try await Self.scanRange(sessionDevice: sessionDevice, range: range) { errorRange in
                        await progress(await reporter.addReadError(errorRange))
                    } onProgress: { offset, bytes in
                        await progress(await reporter.addBytes(bytes, at: offset))
                    } onCandidate: { file in
                        guard let update = await reporter.addCandidate(file) else { return }
                        await progress(update)
                        await onCandidate(file)
                    }
                }
            }
            for _ in 0..<workerLimit { startNextRange() }
            while let rangeFiles = try await group.next() {
                for file in rangeFiles where offsets.insert(file.offset).inserted { files.append(file) }
                startNextRange()
            }
        }
        try Task.checkCancellation()

        let signatureCandidateCount = files.count
        let fileSystem = FileSystemIndex.load(from: sessionDevice)
        for index in files.indices {
            if let originalName = fileSystem.namesByOffset[files[index].offset] {
                files[index].applyOriginalFilename(originalName)
            }
        }
        var fileIndexByOffset = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.offset, $0) })
        for record in fileSystem.deletedFiles {
            if let existing = fileIndexByOffset[record.offset] {
                files[existing].applyOriginalFilename(record.filename)
                continue
            }
            do {
                let file = try Self.recover(record, device: sessionDevice)
                fileIndexByOffset[record.offset] = files.count
                files.append(file)
            } catch {
                GoldfishLog.write("Deleted-file recovery failed at offset \(record.offset): \(error.localizedDescription)")
            }
        }

        files.sort { $0.offset < $1.offset }
        let imageRanges = Self.mergedImageRanges(in: files)
        files.removeAll { Self.isStrictlyContained($0.offset, in: imageRanges) }
        let retainedSignatureCandidates = files.filter { $0.recoverySource == .signatureScan }.count
        await progress(await reporter.addRecoveredFiles(files))

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - scanStart) / 1_000_000_000
        let mibPerSecond = elapsed > 0 ? Double(total) / elapsed / 1_048_576 : 0
        GoldfishLog.write("Parallel scan completed: \(files.count) candidate(s) retained, \(signatureCandidateCount - retainedSignatureCandidates) contained match(es) filtered, \(String(format: "%.1f", elapsed))s, \(String(format: "%.1f", mibPerSecond)) MiB/s")
        return files
    }

    private nonisolated static func recover(_ record: DeletedFileRecord, device: RawDevice) throws -> RecoveredFile {
        let kind = FileKind.from(fileExtension: record.fileExtension)
        var file = RecoveredFile(
            name: record.name,
            kind: kind,
            offset: record.offset,
            size: record.size,
            recoverySource: record.isContiguousEstimate ? .filesystemContiguousEstimate : .deletedFileRecord,
            fileExtension: record.fileExtension,
            device: device,
            metadata: [:],
            physicalRanges: record.extents
        )
        if kind.hasPhotoMetadata {
            let header = try file.read(at: 0, count: Int(min(record.size, photoHeaderSize)))
            file.metadata = PhotoMetadataExtractor.extract(from: header)
        }
        return file
    }

    private nonisolated static func mergedImageRanges(in files: [RecoveredFile]) -> [ScannedRange] {
        var ranges: [ScannedRange] = []
        for file in files where file.kind == .image {
            let range = ScannedRange(start: file.offset, end: file.offset + file.size)
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

    /// Finds all signature markers in one pass over the bytes.
    private nonisolated static func signatureMatches(in data: Data, baseOffset: UInt64) -> [(signatureIndex: Int, offset: UInt64)] {
        signatureSlotByFirstByte.withUnsafeBufferPointer { slotByFirstByte in
            data.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                var matches: [(signatureIndex: Int, offset: UInt64)] = []
                // A `while` loop avoids generic iterator overhead in debug builds.
                var index = 0
                while index < bytes.count {
                    let slot = slotByFirstByte[Int(bytes[index])]
                    if slot != 0 {
                        let signatureIndex = Int(slot) - 1
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
    }

    private nonisolated static func scanRange(sessionDevice: RawDevice, range: ScannedRange, onReadError: @escaping @Sendable (ScannedRange) async -> Void, onProgress: @escaping @Sendable (UInt64, UInt64) async -> Void, onCandidate: @escaping @Sendable (RecoveredFile) async -> Void) async throws -> [RecoveredFile] {
        // Each worker reads through its own descriptor so requests can run in parallel.
        let device = try RawDevice(path: sessionDevice.path, total: sessionDevice.total)
        let total = device.total
        let cache = ChunkCache(device: device)
        var offset = range.start
        let lookbehindStart = range.start - min(UInt64(signatureOverlap), range.start)
        var overlap = Data()
        if lookbehindStart < range.start {
            do {
                overlap = try device.read(at: lookbehindStart, count: Int(range.start - lookbehindStart))
            } catch {
                await onReadError(ScannedRange(start: lookbehindStart, end: range.start))
                GoldfishLog.write("Range lookbehind read failed at offset \(lookbehindStart): \(error.localizedDescription)")
            }
        }
        var found: [RecoveredFile] = []
        var seenOffsets = Set<UInt64>()
        var embeddedJPEGOffsets = Set<UInt64>()

        func process(_ matches: [(signatureIndex: Int, offset: UInt64)]) async {
            for match in matches {
                let signature = signatures[match.signatureIndex]
                guard match.offset >= signature.startAdjustment else { continue }
                let start = match.offset - signature.startAdjustment
                guard seenOffsets.insert(start).inserted, !embeddedJPEGOffsets.contains(start) else { continue }
                do {
                    guard let file = try carve(cache: cache, sessionDevice: sessionDevice, signature: signature, offset: start, maxRead: min(signature.maxSize, total - start)) else { continue }
                    found.append(file)
                    if let thumbnailOffset = file.embeddedThumbnailOffset { embeddedJPEGOffsets.insert(thumbnailOffset) }
                    await onCandidate(file)
                } catch {
                    GoldfishLog.write("Candidate carve failed at offset \(start): \(error.localizedDescription)")
                }
            }
        }

        func processBlock(_ block: Data, at blockOffset: UInt64) async {
            if !overlap.isEmpty {
                let boundary = overlap + block.prefix(signatureOverlap)
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

        while offset < range.end {
            try Task.checkCancellation()
            let requested = Int(min(scanBlockSize, range.end - offset))
            let block: Data
            do {
                block = try cache.read(at: offset, count: requested)
            } catch {
                GoldfishLog.write("Range read failed at offset \(offset); retrying in smaller blocks: \(error.localizedDescription)")
                let blockEnd = offset + UInt64(requested)
                overlap.removeAll(keepingCapacity: true)
                try await rescanInSmallBlocks(device: device, from: offset, to: blockEnd, onReadError: { failed in
                    await onReadError(failed)
                    overlap.removeAll(keepingCapacity: true)
                }, onBlock: { part, partOffset in
                    await processBlock(part, at: partOffset)
                    await onProgress(partOffset, UInt64(part.count))
                })
                offset = blockEnd
                continue
            }
            guard !block.isEmpty else {
                await onReadError(ScannedRange(start: offset, end: range.end))
                break
            }
            await processBlock(block, at: offset)
            await onProgress(offset, UInt64(block.count))
            offset += UInt64(block.count)
            cache.discard(below: offset)
        }
        return found
    }

    /// Re-reads a failed block in 64 KiB pieces, halving any piece that still
    /// fails down to a single sector, so only unreadable sectors are skipped.
    private nonisolated static func rescanInSmallBlocks(device: RawDevice, from start: UInt64, to end: UInt64, onReadError: (ScannedRange) async -> Void, onBlock: (Data, UInt64) async -> Void) async throws {
        let sectorSize = Int(RawDevice.sectorSize)
        var retryOffset = start
        while retryOffset < end {
            try Task.checkCancellation()
            let retryCount = Int(min(retryBlockSize, end - retryOffset))
            var pending: [(offset: UInt64, count: Int)] = [(retryOffset, retryCount)]
            while let (partOffset, partCount) = pending.popLast() {
                try Task.checkCancellation()
                do {
                    let part = try device.read(at: partOffset, count: partCount)
                    guard !part.isEmpty else { throw RecoveryError.incompleteRead(device.path, offset: partOffset) }
                    await onBlock(part, partOffset)
                } catch {
                    let split = max(sectorSize, partCount / 2 / sectorSize * sectorSize)
                    if partCount > sectorSize, split < partCount {
                        pending.append((partOffset + UInt64(split), partCount - split))
                        pending.append((partOffset, split))
                        continue
                    }
                    await onReadError(ScannedRange(start: partOffset, end: partOffset + UInt64(partCount)))
                    GoldfishLog.write("Read error at offset \(partOffset), length \(partCount): \(error.localizedDescription)")
                }
            }
            retryOffset += UInt64(retryCount)
        }
    }

    private nonisolated static func carve(cache: ChunkCache, sessionDevice: RawDevice, signature: Signature, offset: UInt64, maxRead: UInt64) throws -> RecoveredFile? {
        guard maxRead >= signature.minSize else { return nil }
        let reader = CarveReader(cache: cache, base: offset, limit: maxRead)
        guard let size = signature.format.size(reader), size >= signature.minSize, size <= maxRead else { return nil }
        // The parser has just read the start of the file, so the header comes from the cache.
        let needsHeader = signature.kind.hasPhotoMetadata || signature.format == .jpeg
        let header = needsHeader ? try cache.read(at: offset, count: Int(min(size, photoHeaderSize))) : nil
        let thumbnail = signature.format == .jpeg ? header.flatMap(FormatCarvers.exifJPEGThumbnail(in:)) : nil
        return RecoveredFile(
            name: RecoveredFile.generatedName(offset: offset),
            kind: signature.kind,
            offset: offset,
            size: size,
            recoverySource: .signatureScan,
            fileExtension: signature.ext,
            device: sessionDevice,
            metadata: signature.kind.hasPhotoMetadata ? header.map(PhotoMetadataExtractor.extract(from:)) ?? [:] : [:],
            physicalRanges: [ScannedRange(start: offset, end: offset + size)],
            embeddedThumbnailData: thumbnail?.data,
            embeddedThumbnailOffset: thumbnail.map { offset + UInt64($0.offset) }
        )
    }
}
