import SwiftUI
import AppKit

@MainActor final class RecoveryModel: ObservableObject {
    private static let sourceVolumeDestinationError = "Choose a folder outside the selected source volume. Goldfish must not write recovered files back to the card being scanned."
    private static let updateCoalescingDelay: Duration = .milliseconds(80)

    @Published var devices: [Device] = []
    @Published var selected: Device?
    /// Everything the last scan found, including files still on the card.
    @Published private var scannedFiles: [RecoveredFile] = []
    /// Files still on the card need no recovery, so they are hidden unless asked for.
    @Published var showFilesStillOnCard = false {
        didSet { selectedFileIDs.formIntersection(files.map(\.id)) }
    }
    @Published var selectedFileIDs: Set<UUID> = []
    @Published var progress = ScanProgress.empty
    @Published var scanning = false
    @Published var message = "Ready to scan"
    @Published var filter: FileKind?
    @Published var permissionHelp = false
    @Published var deviceAccessGranted = false
    @Published var diagnostic = ""
    @Published var isRefreshingDevices = false
    @Published var exportDestination: URL?
    @Published var exportDestinationError: String?
    /// The files shown and exported.
    var files: [RecoveredFile] {
        showFilesStillOnCard ? scannedFiles : scannedFiles.filter { $0.status != .stillOnCard }
    }
    var filesStillOnCardCount: Int { scannedFiles.filter { $0.status == .stillOnCard }.count }
    var isPrivileged: Bool { getuid() == 0 }
    var hasReadAccess: Bool { isPrivileged || deviceAccessGranted }

    private let engine = RecoveryEngine()
    private var task: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Identifies the running scan so late callbacks from a stopped scan are ignored.
    private var currentScanID: UUID?
    private var pendingCandidates: [RecoveredFile] = []
    private var candidateFlushTask: Task<Void, Never>?
    private var pendingProgress: ScanProgress?
    private var progressFlushTask: Task<Void, Never>?

    init() { refresh() }

    func refresh() {
        let selectedID = selected?.id
        refreshTask?.cancel()
        isRefreshingDevices = true
        refreshTask = Task { [weak self] in
            let updated = await Task.detached(priority: .userInitiated) { DeviceProvider().devices() }.value
            guard !Task.isCancelled, let self else { return }
            devices = updated
            selected = selectedID.flatMap { id in updated.first { $0.id == id && !$0.isInternal } }
                ?? updated.first(where: { $0.isRemovable && !$0.isInternal })
                ?? updated.first(where: { !$0.isInternal })
            isRefreshingDevices = false
        }
    }

    func start() {
        guard let selected, !selected.isInternal, !scanning else { return }
        let scanID = UUID()
        currentScanID = scanID
        discardPendingUpdates()
        scannedFiles = []
        selectedFileIDs = []
        progress = .empty
        scanning = true
        message = "Reading card safely…"
        GoldfishLog.write("Selected device: \(selected.name), path=\(selected.path), identifier=\(selected.identifier), size=\(selected.size)")
        task = Task { [weak self, engine] in
            do {
                let result = try await engine.scan(device: selected) { [weak self] update in
                    await self?.receive(progress: update, scanID: scanID)
                } onCandidate: { [weak self] file in
                    await self?.receive(candidate: file, scanID: scanID)
                }
                self?.finishScan(scanID, result: result)
            } catch {
                self?.failScan(scanID, error: error)
            }
        }
    }

    func stop() {
        task?.cancel()
        currentScanID = nil
        discardPendingUpdates()
        scanning = false
        message = "Scan cancelled"
    }

    private func finishScan(_ scanID: UUID, result: [RecoveredFile]) {
        guard currentScanID == scanID else { return }
        if let pendingProgress { progress = pendingProgress }
        discardPendingUpdates()
        scannedFiles = result
        selectedFileIDs.formIntersection(files.map(\.id))
        scanning = false
        message = result.isEmpty ? "No file candidates found" : "Scan complete · \(result.count) potential file candidates"
    }

    private func failScan(_ scanID: UUID, error: Error) {
        guard currentScanID == scanID else { return }
        discardPendingUpdates()
        scanning = false
        if error is CancellationError {
            message = "Scan cancelled"
            return
        }
        let details = error.localizedDescription
        diagnostic = details
        if case .rawAccessRequired = error as? RecoveryError {
            permissionHelp = true
            message = details
        } else {
            message = "Scan stopped: \(details)"
        }
        GoldfishLog.write("Scan failed: \(details)")
    }

    private func discardPendingUpdates() {
        candidateFlushTask?.cancel()
        candidateFlushTask = nil
        pendingCandidates.removeAll(keepingCapacity: true)
        progressFlushTask?.cancel()
        progressFlushTask = nil
        pendingProgress = nil
    }

    private func receive(progress update: ScanProgress, scanID: UUID) {
        let baseline = pendingProgress ?? progress
        guard currentScanID == scanID,
              update.bytesRead >= baseline.bytesRead,
              update.found >= baseline.found else { return }
        pendingProgress = update
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.updateCoalescingDelay)
            guard !Task.isCancelled, let self else { return }
            if let pendingProgress {
                progress = pendingProgress
                message = "Scanning selected card…"
                self.pendingProgress = nil
            }
            progressFlushTask = nil
        }
    }

    private func receive(candidate: RecoveredFile, scanID: UUID) {
        guard currentScanID == scanID else { return }
        pendingCandidates.append(candidate)
        guard candidateFlushTask == nil else { return }
        candidateFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.updateCoalescingDelay)
            guard !Task.isCancelled, let self else { return }
            scannedFiles.append(contentsOf: pendingCandidates)
            pendingCandidates.removeAll(keepingCapacity: true)
            candidateFlushTask = nil
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func requestDeviceReadAccess() {
        guard let selected, !selected.isInternal else { return }
        let command = "dseditgroup -o edit -a \(shellQuote(NSUserName())) -t user operator"
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo == nil, (result.stringValue ?? "").isEmpty {
            let readCheck = Self.readDeviceHeader(of: selected)
            let succeeded = (try? readCheck.get()) != nil
            let outcome = switch readCheck {
            case .success(let bytes): "SUCCESS (\(bytes) bytes)"
            case .failure(let error): "FAILED — \(error.localizedDescription)"
            }
            deviceAccessGranted = succeeded
            diagnostic = "Added \(NSUserName()) to the macOS operator group. Raw read check for \(selected.path): \(outcome)."
            permissionHelp = !succeeded
            message = succeeded ? "Raw read access verified. You can scan this card now." : "Authorization completed, but the raw device still cannot be read."
        } else {
            let details = errorInfo.map { "\($0)" } ?? "Unknown authorization error"
            diagnostic = "Operator-group authorization failed: \(details)"
            permissionHelp = true
            message = "Administrator authorization was not completed."
        }
        GoldfishLog.write(diagnostic)
    }

    /// Reads the first sector of the device, returning the number of bytes read.
    private static func readDeviceHeader(of device: Device) -> Result<Int, Error> {
        Result {
            let header = try RawDevice(path: device.path, total: device.size).read(at: 0, count: Int(RawDevice.sectorSize))
            guard !header.isEmpty else { throw RecoveryError.incompleteRead(device.path, offset: 0) }
            return header.count
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    var selectedFiles: [RecoveredFile] { files.filter { selectedFileIDs.contains($0.id) } }

    func toggleSelection(for file: RecoveredFile) {
        if !selectedFileIDs.insert(file.id).inserted { selectedFileIDs.remove(file.id) }
    }

    func toggleSelection(for files: [RecoveredFile]) {
        let ids = Set(files.map(\.id))
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedFileIDs) {
            selectedFileIDs.subtract(ids)
        } else {
            selectedFileIDs.formUnion(ids)
        }
    }

    func export() {
        guard !files.isEmpty else { return }
        if exportDestination == nil { chooseExportDestination() }
        guard let folder = exportDestination else { return }
        guard !isOnSelectedSourceVolume(folder) else {
            exportDestinationError = Self.sourceVolumeDestinationError
            return
        }
        let exportFiles = selectedFiles.isEmpty ? files : selectedFiles
        message = "Exporting \(exportFiles.count) file(s)…"
        Task { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) { Self.write(exportFiles, to: folder) }.value
            let exported = exportFiles.count - failures.count
            self?.message = failures.isEmpty
                ? "Exported \(exported) file(s) to \(folder.lastPathComponent)"
                : "Exported \(exported) of \(exportFiles.count) file(s) to \(folder.lastPathComponent) · \(failures.count) failed (see log)"
        }
    }

    /// Writes each file into a per-kind folder, never replacing an existing
    /// file. Returns a description of each failure.
    private nonisolated static func write(_ files: [RecoveredFile], to folder: URL) -> [String] {
        var failures: [String] = []
        for file in files {
            do {
                let directory = folder.appendingPathComponent(file.kind.rawValue, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try file.write(to: availableDestination(in: directory, name: file.name, fileExtension: file.fileExtension))
            } catch {
                let failure = "Export of \(file.name).\(file.fileExtension) failed: \(error.localizedDescription)"
                GoldfishLog.write(failure)
                failures.append(failure)
            }
        }
        return failures
    }

    /// `name.ext`, or `name (n).ext` for the first `n` that is not taken.
    private nonisolated static func availableDestination(in directory: URL, name: String, fileExtension: String) -> URL {
        func candidate(_ stem: String) -> URL {
            let base = directory.appendingPathComponent(stem)
            return fileExtension.isEmpty ? base : base.appendingPathExtension(fileExtension)
        }
        var url = candidate(name)
        var suffix = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate("\(name) (\(suffix))")
            suffix += 1
        }
        return url
    }

    func chooseExportDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose a separate recovery folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = exportDestination
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard !isOnSelectedSourceVolume(folder) else {
            exportDestinationError = Self.sourceVolumeDestinationError
            return
        }
        exportDestinationError = nil
        exportDestination = folder
    }

    private func isOnSelectedSourceVolume(_ folder: URL) -> Bool {
        guard let selected else { return false }
        let destinationPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePath = URL(fileURLWithPath: selected.mountPath).standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        return destinationPath == sourcePath || destinationPath.hasPrefix(sourcePrefix)
    }
}
