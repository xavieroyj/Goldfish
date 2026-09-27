import Foundation

public struct ScannedRange: Hashable, Sendable {
    /// Inclusive starting byte offset.
    public let start: UInt64
    /// Exclusive ending byte offset.
    public let end: UInt64

    public init(start: UInt64, end: UInt64) {
        self.start = start
        self.end = end
    }
}

public struct ScanProgress: Sendable {
    public let bytesRead: UInt64
    public let total: UInt64
    public let found: Int
    public let scannedRanges: [ScannedRange]
    public let candidateRanges: [ScannedRange]
    public let readErrors: [ScannedRange]
    public let bytesPerSecond: Double?
    public let estimatedSecondsRemaining: Double?
    public var fraction: Double { total == 0 ? 0 : min(1, Double(bytesRead) / Double(total)) }

    public static let empty = ScanProgress(bytesRead: 0, total: 0, found: 0)

    public var scannedWithoutCandidates: [ScannedRange] {
        var output: [ScannedRange] = []
        for scanned in scannedRanges {
            var cursor = scanned.start
            for candidate in candidateRanges where candidate.end > cursor && candidate.start < scanned.end {
                if candidate.start > cursor { output.append(ScannedRange(start: cursor, end: min(candidate.start, scanned.end))) }
                cursor = max(cursor, candidate.end)
                if cursor >= scanned.end { break }
            }
            if cursor < scanned.end { output.append(ScannedRange(start: cursor, end: scanned.end)) }
        }
        return output
    }

    public var unscannedRanges: [ScannedRange] {
        var covered = scannedRanges + readErrors
        covered.sort { $0.start < $1.start }
        var merged: [ScannedRange] = []
        for range in covered {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = ScannedRange(start: last.start, end: max(last.end, range.end))
            } else if range.end > range.start {
                merged.append(range)
            }
        }
        var output: [ScannedRange] = []
        var cursor: UInt64 = 0
        for range in merged where range.start < total {
            if range.start > cursor { output.append(ScannedRange(start: cursor, end: min(range.start, total))) }
            cursor = max(cursor, min(range.end, total))
        }
        if cursor < total { output.append(ScannedRange(start: cursor, end: total)) }
        return output
    }

    public init(bytesRead: UInt64, total: UInt64, found: Int, scannedRanges: [ScannedRange] = [], candidateRanges: [ScannedRange] = [], readErrors: [ScannedRange] = [], bytesPerSecond: Double? = nil, estimatedSecondsRemaining: Double? = nil) {
        self.bytesRead = bytesRead
        self.total = total
        self.found = found
        self.scannedRanges = scannedRanges
        self.candidateRanges = candidateRanges
        self.readErrors = readErrors
        self.bytesPerSecond = bytesPerSecond
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
    }
}

/// Collects progress from the parallel range workers into one snapshot.
actor ScanProgressReporter {
    private static let speedSampleInterval = 0.25
    private static let speedSmoothing = 0.7

    private let total: UInt64
    private var bytesRead: UInt64 = 0
    private var found = 0
    private var scannedRanges: [ScannedRange] = []
    private var candidateRanges: [ScannedRange] = []
    private var readErrors: [ScannedRange] = []
    private var candidateOffsets = Set<UInt64>()
    private var lastSampleAt = DispatchTime.now().uptimeNanoseconds
    private var lastSampleBytes: UInt64 = 0
    private var smoothedBytesPerSecond: Double?

    init(total: UInt64) {
        self.total = total
    }

    var hasReadErrors: Bool { !readErrors.isEmpty }

    func addBytes(_ bytes: UInt64, at offset: UInt64) -> ScanProgress {
        bytesRead = min(total, bytesRead + bytes)
        insert(ScannedRange(start: offset, end: offset + bytes), into: &scannedRanges)
        updateSpeed()
        return snapshot()
    }

    /// Returns nil when a candidate at the same offset was already reported.
    func addCandidate(_ file: RecoveredFile) -> ScanProgress? {
        guard record(file) else { return nil }
        return snapshot()
    }

    func addReadError(_ range: ScannedRange) -> ScanProgress {
        insert(range, into: &readErrors)
        return snapshot()
    }

    func addRecoveredFiles(_ files: [RecoveredFile]) -> ScanProgress {
        for file in files { record(file) }
        return snapshot()
    }

    @discardableResult private func record(_ file: RecoveredFile) -> Bool {
        guard candidateOffsets.insert(file.offset).inserted else { return false }
        found += 1
        for range in file.physicalRanges { insert(range, into: &candidateRanges) }
        return true
    }

    private func snapshot() -> ScanProgress {
        let eta = smoothedBytesPerSecond.flatMap { rate in
            rate > 0 ? Double(total - bytesRead) / rate : nil
        }
        return ScanProgress(bytesRead: bytesRead, total: total, found: found, scannedRanges: scannedRanges, candidateRanges: candidateRanges, readErrors: readErrors, bytesPerSecond: smoothedBytesPerSecond, estimatedSecondsRemaining: eta)
    }

    /// Inserts `range`, clipped to the device, into a sorted list of disjoint ranges.
    private func insert(_ range: ScannedRange, into target: inout [ScannedRange]) {
        var merged = ScannedRange(start: range.start, end: min(total, range.end))
        guard merged.end > merged.start else { return }
        var output: [ScannedRange] = []
        var inserted = false
        for existing in target {
            if existing.end < merged.start {
                output.append(existing)
            } else if merged.end < existing.start {
                if !inserted { output.append(merged); inserted = true }
                output.append(existing)
            } else {
                merged = ScannedRange(start: min(merged.start, existing.start), end: max(merged.end, existing.end))
            }
        }
        if !inserted { output.append(merged) }
        target = output
    }

    private func updateSpeed() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - lastSampleAt) / 1_000_000_000
        guard elapsed >= Self.speedSampleInterval else { return }
        let rate = Double(bytesRead - lastSampleBytes) / elapsed
        smoothedBytesPerSecond = smoothedBytesPerSecond.map { $0 * Self.speedSmoothing + rate * (1 - Self.speedSmoothing) } ?? rate
        lastSampleAt = now
        lastSampleBytes = bytesRead
    }
}
