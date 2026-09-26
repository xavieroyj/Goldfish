import Foundation

/// The file formats the signature scan can carve. Each parser walks the
/// format's own structure from the first byte and returns the exact file size,
/// or nil when the bytes do not form a plausible file.
enum SignatureFormat: Sendable {
    case jpeg, tiff, png, gif, pdf, matroska, mp4

    func size(_ reader: CarveReader) -> UInt64? {
        switch self {
        case .jpeg: FormatCarvers.jpegSize(reader)
        case .tiff: FormatCarvers.tiffSize(reader)
        case .png: FormatCarvers.pngSize(reader)
        case .gif: FormatCarvers.gifSize(reader)
        case .pdf: FormatCarvers.pdfSize(reader)
        case .matroska: FormatCarvers.matroskaSize(reader)
        case .mp4: FormatCarvers.mp4Size(reader)
        }
    }
}

enum FormatCarvers {
    static func pngSize(_ reader: CarveReader) -> UInt64? {
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

    static func gifSize(_ reader: CarveReader) -> UInt64? {
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

    static func pdfSize(_ reader: CarveReader) -> UInt64? {
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

    static func mp4Size(_ reader: CarveReader) -> UInt64? {
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

    static func matroskaSize(_ reader: CarveReader) -> UInt64? {
        guard reader.read(0, 4) == Data([0x1A,0x45,0xDF,0xA3]),
              let ebmlSize = ebmlVariableInteger(reader, at: 4) else { return nil }
        let segmentOffset = UInt64(4 + ebmlSize.length) + ebmlSize.value
        guard segmentOffset + 5 <= reader.limit,
              reader.read(segmentOffset, 4) == Data([0x18,0x53,0x80,0x67]),
              let segmentSize = ebmlVariableInteger(reader, at: segmentOffset + 4), !segmentSize.unknown else { return nil }
        let total = segmentOffset + 4 + UInt64(segmentSize.length) + segmentSize.value
        return total <= reader.limit ? total : nil
    }

    private static func ebmlVariableInteger(_ reader: CarveReader, at offset: UInt64) -> (value: UInt64, length: Int, unknown: Bool)? {
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

    static func tiffSize(_ reader: CarveReader) -> UInt64? {
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

    private static func tiffTypeSize(_ type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: nil
        }
    }

    private static func bigEndianUInt32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func bigEndianUInt64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }

    static func jpegSize(_ reader: CarveReader) -> UInt64? {
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

    /// Finds the next marker after entropy-coded scan data: an 0xFF that is
    /// not byte stuffing (0xFF00), a restart marker, or fill (0xFFFF).
    private static func nextJPEGMarker(_ reader: CarveReader, from start: UInt64) -> (offset: UInt64, marker: UInt8)? {
        var cursor = start
        var pendingMarkerOffset: UInt64?
        let chunkSize = 1 * 1024 * 1024
        while cursor < reader.limit {
            let count = Int(min(UInt64(chunkSize), reader.limit - cursor))
            guard let block = reader.read(cursor, count), !block.isEmpty else { return nil }
            let blockStart = cursor
            let found: (offset: UInt64, marker: UInt8)? = block.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return nil }
                let bytes = raw.bindMemory(to: UInt8.self)
                var index = 0
                while index < bytes.count {
                    if let markerOffset = pendingMarkerOffset {
                        let byte = bytes[index]
                        if byte == 0x00 || (0xD0...0xD7).contains(byte) {
                            pendingMarkerOffset = nil
                        } else if byte != 0xFF {
                            return (markerOffset, byte)
                        }
                        index += 1
                    } else {
                        // Scan data is mostly non-0xFF bytes; memchr skips them in bulk.
                        guard let match = memchr(base + index, 0xFF, bytes.count - index) else { break }
                        let matchIndex = base.distance(to: UnsafeRawPointer(match))
                        pendingMarkerOffset = blockStart + UInt64(matchIndex)
                        index = matchIndex + 1
                    }
                }
                return nil
            }
            if let found { return found }
            cursor += UInt64(block.count)
        }
        return nil
    }

    static func exifJPEGThumbnail(in jpeg: Data) -> (data: Data, offset: Int)? {
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

    private static func readTIFFUInt16(_ data: Data, at index: Int, littleEndian: Bool) -> UInt16? {
        guard index >= 0, index + 2 <= data.count else { return nil }
        let first = UInt16(data[index]), second = UInt16(data[index + 1])
        return littleEndian ? first | (second << 8) : (first << 8) | second
    }

    private static func readTIFFUInt32(_ data: Data, at index: Int, littleEndian: Bool) -> UInt32? {
        guard index >= 0, index + 4 <= data.count else { return nil }
        let bytes = (0..<4).map { UInt32(data[index + $0]) }
        if littleEndian {
            return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
        }
        return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
    }

    private static func jpegEnd(in data: Data) -> Int? {
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
