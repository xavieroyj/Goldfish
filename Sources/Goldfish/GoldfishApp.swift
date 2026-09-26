import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ImageIO

enum GoldfishLog {
    static func write(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Goldfish", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: directory.appendingPathComponent("debug.log")) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else if let data = line.data(using: .utf8) {
            try? data.write(to: directory.appendingPathComponent("debug.log"), options: .atomic)
        }
    }
}

@main struct GoldfishApp: App {
    @NSApplicationDelegateAdaptor(GoldfishAppDelegate.self) private var appDelegate
    @StateObject private var model = RecoveryModel()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 720)
        }
    }
}

@MainActor
final class GoldfishAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor private enum AppBrand {
    static let logo: NSImage? = {
        if let url = Bundle.main.url(forResource: "GoldfishWhite", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        if let url = Bundle.module.url(forResource: "GoldfishWhite", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return nil
    }()
}

@MainActor final class RecoveryModel: ObservableObject {
    @Published var devices: [Device] = []; @Published var selected: Device?; @Published var files: [RecoveredFile] = []
    @Published var selectedFileIDs: Set<UUID> = []
    @Published var progress = ScanProgress(bytesRead: 0, total: 0, found: 0); @Published var scanning = false; @Published var message = "Ready to scan"; @Published var filter: FileKind?; @Published var permissionHelp = false
    @Published var deviceAccessGranted = false
    @Published var diagnostic = ""
    @Published var isRefreshingDevices = false
    @Published var exportDestination: URL?
    @Published var exportDestinationError: String?
    var isPrivileged: Bool { getuid() == 0 }
    var hasReadAccess: Bool { isPrivileged || deviceAccessGranted }
    private let engine = RecoveryEngine(); private var task: Task<Void, Never>?; private var refreshTask: Task<Void, Never>?
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
    func logSelectedDevice() { if let selected { GoldfishLog.write("Selected device: \(selected.name), path=\(selected.path), identifier=\(selected.identifier), size=\(selected.size)") } }
    func start() {
        guard let selected, !selected.isInternal, !scanning else { return }
        candidateFlushTask?.cancel(); candidateFlushTask = nil; pendingCandidates.removeAll(keepingCapacity: true)
        progressFlushTask?.cancel(); progressFlushTask = nil; pendingProgress = nil
        files = []; selectedFileIDs = []; progress = ScanProgress(bytesRead: 0, total: 0, found: 0); scanning = true; message = "Reading card safely…"
        logSelectedDevice()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.scan(device: selected) { [weak self] p in
                    await self?.receive(progress: p)
                } onCandidate: { [weak self] file in
                    await self?.receive(candidate: file)
                }
                candidateFlushTask?.cancel(); candidateFlushTask = nil; pendingCandidates.removeAll(keepingCapacity: true)
                progressFlushTask?.cancel(); progressFlushTask = nil
                if let pendingProgress { progress = pendingProgress }
                pendingProgress = nil
                files = result
                selectedFileIDs.formIntersection(Set(result.map(\.id)))
                scanning = false
                message = result.isEmpty ? "No file candidates found" : "Scan complete · \(result.count) potential file candidates"
            } catch {
                candidateFlushTask?.cancel(); candidateFlushTask = nil; pendingCandidates.removeAll(keepingCapacity: true)
                progressFlushTask?.cancel(); progressFlushTask = nil; pendingProgress = nil
                scanning = false
                if Task.isCancelled {
                    message = "Scan cancelled"
                    return
                }
                let recoveryError = error as? RecoveryError
                let isPermissionError: Bool
                if let recoveryError, case .rawAccessRequired = recoveryError {
                    isPermissionError = true
                } else {
                    isPermissionError = false
                }
                if isPermissionError { permissionHelp = true }
                let details = error.localizedDescription
                diagnostic = details
                message = isPermissionError ? details : "Scan stopped: \(details)"
                GoldfishLog.write("Scan failed: \(details)")
            }
        }
    }

    private func receive(progress update: ScanProgress) {
        let baseline = pendingProgress ?? progress
        guard scanning,
              update.bytesRead >= baseline.bytesRead,
              update.found >= baseline.found else { return }
        pendingProgress = update
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            flushProgress()
        }
    }

    private func receive(candidate: RecoveredFile) {
        guard scanning else { return }
        pendingCandidates.append(candidate)
        guard candidateFlushTask == nil else { return }
        candidateFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            flushCandidates()
        }
    }

    private func flushProgress() {
        if let pendingProgress {
            progress = pendingProgress
            message = "Scanning selected card…"
            self.pendingProgress = nil
        }
        progressFlushTask = nil
    }

    private func flushCandidates() {
        if !pendingCandidates.isEmpty {
            files.append(contentsOf: pendingCandidates)
            pendingCandidates.removeAll(keepingCapacity: true)
        }
        candidateFlushTask = nil
    }
    func stop() {
        task?.cancel(); Task { await engine.cancel() }
        candidateFlushTask?.cancel(); candidateFlushTask = nil; pendingCandidates.removeAll(keepingCapacity: true)
        progressFlushTask?.cancel(); progressFlushTask = nil; pendingProgress = nil
        scanning = false; message = "Scan cancelled"
    }
    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestDeviceReadAccess() {
        guard let selected, !selected.isInternal else { return }
        let command = "dseditgroup -o edit -a \(shellQuote(NSUserName())) -t user operator"
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo == nil, (result.stringValue ?? "").isEmpty {
            let readResult = Self.readDeviceHeader(at: selected.path)
            deviceAccessGranted = readResult.success
            diagnostic = "Added \(NSUserName()) to the macOS operator group. Raw read check for \(selected.path): \(readResult.success ? "SUCCESS (\(readResult.bytes) bytes)" : "FAILED — \(readResult.error))")."
            permissionHelp = !readResult.success
            message = readResult.success ? "Raw read access verified. You can scan this card now." : "Authorization completed, but the raw device still cannot be read."
            GoldfishLog.write(diagnostic)
        } else {
            let details = errorInfo.map { "\($0)" } ?? "Unknown authorization error"
            diagnostic = "Operator-group authorization failed: \(details)"
            permissionHelp = true
            message = "Administrator authorization was not completed."
            GoldfishLog.write(diagnostic)
        }
    }

    private static func readDeviceHeader(at path: String) -> (success: Bool, bytes: Int, error: String) {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 512), !data.isEmpty else { return (false, 0, "device returned no data") }
            return (true, data.count, "")
        } catch {
            return (false, 0, error.localizedDescription)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    var visibleFiles: [RecoveredFile] { filter.map { kind in files.filter { $0.kind == kind } } ?? files }
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
            exportDestinationError = "Choose a folder outside the selected source volume. Goldfish must not write recovered files back to the card being scanned."
            return
        }
        let exportFiles = selectedFiles.isEmpty ? files : selectedFiles
        message = "Exporting \(exportFiles.count) file(s)…"
        Task { [weak self] in
            let count = await Task.detached(priority: .userInitiated) {
                var count = 0
                for file in exportFiles {
                    let dir = folder.appendingPathComponent(file.kind.rawValue, isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let out = dir.appendingPathComponent(file.name).appendingPathExtension(file.fileExtension)
                    if (try? file.write(to: out)) != nil { count += 1 }
                }
                return count
            }.value
            self?.message = "Exported \(count) file(s) to \(folder.lastPathComponent)"
        }
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
            exportDestinationError = "Choose a folder outside the selected source volume. Goldfish must not write recovered files back to the card being scanned."
            return
        }
        exportDestinationError = nil
        exportDestination = folder
    }

    private func isOnSelectedSourceVolume(_ folder: URL) -> Bool {
        guard let selected else { return false }
        let destinationPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePath = URL(fileURLWithPath: selected.id).standardizedFileURL.resolvingSymlinksInPath().path
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        return destinationPath == sourcePath || destinationPath.hasPrefix(sourcePrefix)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: RecoveryModel
    @State private var searchText = ""
    @State private var focusedFileID: UUID?
    @State private var showingQueue = false
    @State private var sortColumn: SortColumn = .offset
    @State private var sortAscending = true
    private let paneHeaderHeight: CGFloat = 43

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar.frame(width: 248)
                Rectangle().fill(Color.border).frame(width: 1)
                VStack(spacing: 0) {
                    topBar.frame(height: 85)
                    scanOverview.frame(height: 199)
                    HStack(spacing: 0) {
                        resultsPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Rectangle().fill(Color.border).frame(width: 1)
                        previewPanel.frame(width: 352)
                    }
                }
            }
            if model.permissionHelp {
                accessDialog
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(Color.canvas)
        .animation(.easeInOut(duration: 0.18), value: model.permissionHelp)
        .preferredColorScheme(.dark)
        .onChange(of: model.files.count) { _, _ in
            if focusedFileID == nil { focusedFileID = displayedFiles.first?.id }
        }
        .alert("Choose a separate destination", isPresented: Binding(
            get: { model.exportDestinationError != nil },
            set: { if !$0 { model.exportDestinationError = nil } }
        )) {
            Button("OK", role: .cancel) { model.exportDestinationError = nil }
        } message: {
            Text(model.exportDestinationError ?? "")
        }
    }

    private var accessDialog: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.68)
                    .ignoresSafeArea()
                    .onTapGesture { model.permissionHelp = false }

                VStack(spacing: 0) {
                    accessDialogHeader
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            accessErrorDetails
                            accessExplanation
                            accessSteps
                            readOnlyNotice
                        }
                        .padding(24)
                    }
                    .scrollIndicators(.visible)
                    accessDialogFooter
                }
                .frame(width: min(600, geometry.size.width - 40))
                .frame(maxHeight: min(660, geometry.size.height - 48))
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 32, x: 0, y: 18)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private var accessDialogHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.amber)
                .frame(width: 40, height: 40)
                .background(Color.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.amber.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text("SD card access needed")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.ink)
                Text("Goldfish found your card, but macOS is blocking raw read access to the device. Nothing on the card was changed.")
                    .font(.system(size: 12)).lineSpacing(3).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { model.permissionHelp = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close access dialog")
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
    }

    private var accessErrorDetails: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.coral)
                Text("Couldn’t open device for reading")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.coral)
                Spacer()
                Button {
                    let details = model.diagnostic.isEmpty ? "Couldn’t open device for reading: \(model.selected?.path ?? "no device selected")" : model.diagnostic
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details, forType: .string)
                    model.message = "Access error details copied"
                } label: {
                    Label("Copy details", systemImage: "doc.on.doc").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.coral.opacity(0.07))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.coral.opacity(0.15)).frame(height: 1) }

            VStack(spacing: 7) {
                accessDetailRow("Device", model.selected?.path ?? "No device selected", monospaced: true)
                accessDetailRow("Requested", "Read-only access")
                accessDetailRow("Blocked by", "macOS raw-device permissions")
                if !model.diagnostic.isEmpty {
                    Text(model.diagnostic)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.coral.opacity(0.2), lineWidth: 1))
    }

    private func accessDetailRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 9)).foregroundStyle(Color.muted).frame(width: 72, alignment: .leading)
            Text(value).font(monospaced ? .system(size: 9, design: .monospaced) : .system(size: 9, weight: .medium))
                .foregroundStyle(Color.ink).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessExplanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why Full Disk Access isn’t enough")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink)
            Text("Full Disk Access covers files on your Mac. Reading an SD card’s raw device node (such as /dev/disk*) is a separate permission that may require administrator approval.")
                .font(.system(size: 11)).lineSpacing(3).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            accessStep(1, "Authorize device access", "Approve the macOS administrator prompt. Goldfish will verify read access afterward.")
            accessStep(2, "Try the scan again", "Once access is available, start the read-only scan again from this window.")
            accessStep(3, "If access still isn’t available", "Sign out and back in so macOS can apply the updated group membership, then reopen Goldfish.")
        }
    }

    private func accessStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.ink)
                .frame(width: 20, height: 20).background(Color.raised, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink)
                Text(detail).font(.system(size: 9)).lineSpacing(2).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readOnlyNotice: some View {
        Label("Read-only: Goldfish only opens the card for reading and never writes to it.", systemImage: "checkmark.shield.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.mint)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.mint.opacity(0.16), lineWidth: 1))
    }

    private var accessDialogFooter: some View {
        HStack(spacing: 10) {
            Button { model.openFullDiskAccessSettings() } label: {
                Label("Open Full Disk Access", systemImage: "gearshape")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.muted)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Button {
                model.permissionHelp = false
                model.start()
            } label: {
                Label("Try scan again", systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Color.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(model.selected == nil)
            Button { model.requestDeviceReadAccess() } label: {
                Label("Authorize device access", systemImage: "lock.open")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.canvas)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Color.mint, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).disabled(model.selected == nil || model.isPrivileged)
            .help(model.isPrivileged ? "Device access is already running with administrator privileges" : "Request read access to the selected device")
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
        .background(Color.canvas)
        .overlay(alignment: .top) { Rectangle().fill(Color.border).frame(height: 1) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let logo = AppBrand.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Salvage").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink)
                    Text("SD Recovery Studio").font(.system(size: 10)).foregroundStyle(Color.muted)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 28)

            HStack {
                Text("DEVICES").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Color.muted)
                Spacer()
                Button { model.refresh() } label: {
                    Group {
                        if model.isRefreshingDevices {
                            ProgressView().controlSize(.small).tint(Color.mint).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.muted).disabled(model.isRefreshingDevices)
                .help(model.isRefreshingDevices ? "Checking connected volumes…" : "Refresh connected volumes")
                .accessibilityLabel("Refresh connected volumes")
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.devices) { device in
                        Button { if !device.isInternal { model.selected = device } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: device.isInternal ? "internaldrive.fill" : "sdcard.fill")
                                    .font(.system(size: 16)).foregroundStyle(device.isInternal ? Color.muted.opacity(0.7) : (model.selected == device ? Color.mint : Color.muted))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(device.isInternal ? Color.muted : Color.ink).lineLimit(1)
                                    Text(device.isInternal ? "Internal · not supported · \(device.sizeDescription)" : "\(device.sizeDescription) · \(device.identifier.isEmpty ? device.path : device.identifier)")
                                        .font(.system(size: 9)).foregroundStyle(Color.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                 if device.isInternal {
                                     Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.muted.opacity(0.7))
                                 }
                            }
                            .padding(.horizontal, 10).frame(height: 48)
                            .background(model.selected == device ? Color.mint.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(device.isInternal)
                        .help(device.isInternal ? "Internal macOS volumes are not supported yet" : "Select \(device.name)")
                    }
                    if model.devices.isEmpty {
                        Text("Connect a card to begin")
                            .font(.system(size: 10)).foregroundStyle(Color.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: 260)

            Text("WORKSPACE").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Color.muted)
                .padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 10)
            VStack(spacing: 4) {
                sidebarItem("Scan results", icon: "viewfinder", count: model.files.count, active: !showingQueue) { showingQueue = false }
                sidebarItem("Recovery queue", icon: "tray", count: model.selectedFileIDs.count, active: showingQueue) { showingQueue = true }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                Label("Read-only mode", systemImage: "checkmark.shield.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.mint)
                Text("Nothing is written to the card. Export recovered files to a separate drive.")
                    .font(.system(size: 9)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.mint.opacity(0.16), lineWidth: 1))
            .padding(14)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.surface)
    }

    private func sidebarItem(_ title: String, icon: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 11, weight: active ? .semibold : .regular))
                Spacer()
                if count > 0 { Text(count.formatted()).font(.system(size: 9, design: .monospaced)).foregroundStyle(active ? Color.mint : Color.muted) }
            }
            .foregroundStyle(active ? Color.ink : Color.muted)
            .padding(.horizontal, 10).frame(height: 33)
            .background(active ? Color.raised : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) { if active { RoundedRectangle(cornerRadius: 2).fill(Color.mint).frame(width: 2, height: 18) } }
        }
        .buttonStyle(.plain).padding(.horizontal, 12)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(model.selected?.name ?? "No device selected").foregroundStyle(Color.muted)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.muted.opacity(0.75))
                    Text("Read-only scan").foregroundStyle(Color.muted)
                }
                .font(.system(size: 10))
                HStack(spacing: 10) {
                    Text(showingQueue ? "Recovery queue" : "Scan results").font(.system(size: 21, weight: .semibold)).foregroundStyle(Color.ink)
                    HStack(spacing: 6) {
                        Circle().fill(model.scanning ? Color.mint : Color.muted).frame(width: 6, height: 6)
                        Text(model.scanning ? "Scanning · \(Int(model.progress.fraction * 100))%" : model.message)
                            .font(.system(size: 9, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(model.scanning ? Color.mint : Color.muted)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.raised, in: Capsule())
                }
            }
            Spacer(minLength: 12)
            if model.scanning {
                Button { model.stop() } label: { Label("Stop scan", systemImage: "stop.fill") }
                    .buttonStyle(StudioButtonStyle(kind: .danger))
            } else if !model.files.isEmpty {
                Button { model.start() } label: { Label("Scan again", systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle(kind: .secondary))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .frame(height: 85)
        .background(Color.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
    }

    private var scanOverview: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan progress").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                        Text(model.scanning ? "\(ByteCountFormatter.string(fromByteCount: Int64(model.progress.bytesRead), countStyle: .file)) read of \(ByteCountFormatter.string(fromByteCount: Int64(model.progress.total), countStyle: .file))" : "Read-only scan of the selected volume")
                            .font(.system(size: 9)).foregroundStyle(Color.muted)
                    }
                    Spacer()
                    Text("\(Int(model.progress.fraction * 100))%")
                        .font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Color.mint)
                }
                SectorMapView(progress: model.progress)
                    .frame(height: 58)
                HStack(spacing: 14) {
                    legendDot(Color.blue, "Possible file found")
                    legendDot(Color.mint, "No known file found")
                    legendDot(Color.coral, "Read error")
                    legendDot(Color.raised, "Not scanned yet")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text("FOUND SO FAR").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Color.muted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.files.count.formatted()).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Color.ink)
                    Text("possible files").font(.system(size: 9)).foregroundStyle(Color.muted)
                }
                Rectangle().fill(Color.border).frame(height: 1)
                HStack {
                    Label("Signature scan", systemImage: "viewfinder")
                    Spacer()
                    Text(model.files.filter { $0.recoverySource == .signatureScan }.count.formatted()).monospacedDigit().foregroundStyle(Color.ink)
                }
                HStack {
                    Label("File records", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    Text(model.files.filter { $0.recoverySource != .signatureScan }.count.formatted()).monospacedDigit().foregroundStyle(Color.ink)
                }
                HStack {
                    Label("Read speed", systemImage: "speedometer")
                    Spacer()
                    Text(speedText(model.progress.bytesPerSecond)).monospacedDigit().foregroundStyle(Color.ink)
                }
                HStack {
                    Label("Time remaining", systemImage: "clock")
                    Spacer()
                    Text(etaText(model.progress.estimatedSecondsRemaining)).monospacedDigit().foregroundStyle(Color.ink)
                }
            }
            .font(.system(size: 9)).foregroundStyle(Color.muted)
            .padding(12).frame(width: 260, alignment: .leading)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border, lineWidth: 1))
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .background(Color.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 8)).foregroundStyle(Color.muted)
        }
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            typeTabs.frame(height: paneHeaderHeight)
            resultsToolbar.frame(height: 55)
            tableHeader.frame(height: 34)
            if displayedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.scanning ? "waveform.path" : "doc.text.magnifyingglass").font(.system(size: 23)).foregroundStyle(Color.muted)
                    Text(model.scanning ? "Possible files will appear here as they are found." : (model.files.isEmpty ? "Select a device and start a read-only scan." : "No files match this search."))
                        .font(.system(size: 11)).foregroundStyle(Color.muted).multilineTextAlignment(.center)
                    if model.files.isEmpty && !model.scanning {
                        Button { model.start() } label: { Label("Start safe scan", systemImage: "viewfinder") }
                            .buttonStyle(StudioButtonStyle(kind: .primary)).padding(.top, 6).disabled(model.selected == nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedFiles) { file in resultRow(file) }
                    }
                }
                .background(Color.canvas)
            }
            tableFooter
        }
        .background(Color.canvas)
    }

    private var typeTabs: some View {
        HStack(spacing: 22) {
            tabButton("All", kind: nil, count: filesForTab(nil).count)
            ForEach(FileKind.allCases) { kind in
                tabButton(tabName(kind), kind: kind, count: filesForTab(kind).count)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Color.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
    }

    private func tabButton(_ title: String, kind: FileKind?, count: Int) -> some View {
        let active = model.filter == kind
        return Button { model.filter = kind } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 10, weight: active ? .semibold : .regular))
                Text(count.formatted()).font(.system(size: 8, design: .monospaced)).foregroundStyle(active ? Color.mint : Color.muted)
            }
            .foregroundStyle(active ? Color.ink : Color.muted)
            .frame(height: paneHeaderHeight)
            .overlay(alignment: .bottom) { if active { Rectangle().fill(Color.mint).frame(height: 2) } }
        }
        .buttonStyle(.plain)
    }

    private var resultsToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.muted)
                TextField("Search name, type, or offset", text: $searchText).textFieldStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.ink)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Color.muted) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 31)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.border, lineWidth: 1))
        }
        .padding(.horizontal, 20)
        .background(Color.surface.opacity(0.72))
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Button { model.toggleSelection(for: displayedFiles) } label: {
                Image(systemName: headerSelectionSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(headerSelectionColor)
                    .frame(width: 42, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(displayedFiles.isEmpty)
            .help(headerSelectionHelp)
            Color.clear.frame(width: 40)
            sortHeader("NAME", column: .name)
            sortHeader("TYPE", column: .type, width: 60)
            sortHeader("SIZE", column: .size, width: 76)
            sortHeader("OFFSET", column: .offset, width: 110)
        }
        .padding(.horizontal, 20)
        .background(Color.surface.opacity(0.5))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
    }

    private var headerSelectionSymbol: String {
        if displayedFiles.isEmpty { return "square" }
        let selectedCount = displayedFiles.filter { model.selectedFileIDs.contains($0.id) }.count
        if selectedCount == displayedFiles.count { return "checkmark.square.fill" }
        if selectedCount > 0 { return "minus.square.fill" }
        return "square"
    }

    private var headerSelectionColor: Color {
        headerSelectionSymbol == "square" ? Color.muted : Color.mint
    }

    private var headerSelectionHelp: String {
        guard !displayedFiles.isEmpty else { return "No visible files to select" }
        let allSelected = displayedFiles.allSatisfy { model.selectedFileIDs.contains($0.id) }
        return allSelected ? "Deselect all visible files" : "Select all visible files"
    }

    @ViewBuilder private func sortHeader(_ title: String, column: SortColumn, width: CGFloat? = nil) -> some View {
        let header = Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 6, weight: .bold))
                }
            }
            .font(.system(size: 8, weight: .bold)).tracking(0.7)
            .foregroundStyle(sortColumn == column ? Color.ink : Color.muted)
            .frame(height: 34, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if let width {
            header.frame(width: width, alignment: .leading)
        } else {
            header.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultRow(_ file: RecoveredFile) -> some View {
        let selected = model.selectedFileIDs.contains(file.id)
        let focused = focusedFile?.id == file.id
        return HStack(spacing: 0) {
            Button { model.toggleSelection(for: file) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14)).foregroundStyle(selected ? Color.mint : Color.muted.opacity(0.75))
                    .frame(width: 42, height: 47)
            }
            .buttonStyle(.plain)
            FilePreviewImage(file: file).frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4)).frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(file.name).\(file.fileExtension)").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1)
                Text(file.recoverySource.label)
                    .font(.system(size: 8)).foregroundStyle(file.recoverySource == .filesystemContiguousEstimate ? Color.amber : Color.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
            Text(file.fileExtension.uppercased()).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.muted).frame(width: 60, alignment: .leading)
            Text(file.sizeDescription).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted).frame(width: 76, alignment: .leading)
            Text("0x\(String(file.offset, radix: 16, uppercase: true))").font(.system(size: 8, design: .monospaced)).foregroundStyle(Color.muted)
                .lineLimit(1).frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 20).frame(height: 48)
        .background(focused ? Color.raised.opacity(0.85) : Color.clear)
        .overlay(alignment: .leading) { if focused { Rectangle().fill(Color.mint).frame(width: 2) } }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border.opacity(0.65)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { focusedFileID = file.id }
    }

    private var tableFooter: some View {
        HStack {
            Text("Showing \(displayedFiles.count) of \(filesForTab(model.filter).count) files")
            if model.scanning { Text("· Scan in progress") }
            Spacer()
            Text("\(model.selectedFileIDs.count) selected").foregroundStyle(Color.muted)
        }
        .font(.system(size: 9)).foregroundStyle(Color.muted)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Color.surface)
        .overlay(alignment: .top) { Rectangle().fill(Color.border).frame(height: 1) }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PREVIEW").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Color.muted)
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: paneHeaderHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
            if let file = focusedFile {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if file.kind == .image || file.kind == .raw {
                            ImagePreviewButton(file: file)
                        } else {
                            FilePreviewImage(file: file)
                        }
                    }
                        .frame(maxWidth: .infinity).frame(height: 176)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(alignment: .topLeading) {
                            Label(file.recoverySource.label, systemImage: "info.circle")
                                .font(.system(size: 8, weight: .medium)).foregroundStyle(Color.ink)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.canvas.opacity(0.92), in: Capsule()).padding(8)
                                .allowsHitTesting(false)
                        }
                    Text("\(file.name).\(file.fileExtension)")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1).padding(.top, 14)
                    Text(file.isFragmented == true ? "Data spans multiple card regions" : "Offset 0x\(String(file.offset, radix: 16, uppercase: true))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted).lineLimit(1).padding(.top, 5)
                    VStack(spacing: 0) {
                        metadataRow("Type", file.fileExtension.uppercased())
                        metadataRow("Size", file.sizeDescription)
                        metadataRow("Recovery source", file.recoverySource.label)
                        if file.isFragmented == true { metadataRow("Data regions", "\(file.physicalRanges.count) separated regions") }
                        ForEach(file.metadata.keys.sorted(), id: \.self) { key in metadataRow(key, file.metadata[key] ?? "") }
                    }
                    .padding(.top, 14)
                    Spacer(minLength: 10)
                    if !model.diagnostic.isEmpty {
                        Text(model.diagnostic).font(.system(size: 8)).foregroundStyle(Color.coral).lineLimit(3).padding(.bottom, 8)
                    }
                }
                .padding(18)
                Spacer(minLength: 0)
                Rectangle().fill(Color.border).frame(height: 1)
                Button { model.chooseExportDestination() } label: {
                    HStack(spacing: 10) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 13)).foregroundStyle(Color.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Restore to").font(.system(size: 8)).foregroundStyle(Color.muted)
                        Text(model.exportDestination?.path ?? "Choose a separate folder")
                            .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Color.ink)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(model.exportDestination?.path ?? "Choose an export destination folder")
                .accessibilityLabel("Restore to \(model.exportDestination?.path ?? "Choose a separate folder")")
                .padding(.horizontal, 18).padding(.top, 14)
                Button { model.export() } label: { Label(exportButtonTitle, systemImage: "arrow.down.to.line") }
                    .buttonStyle(StudioButtonStyle(kind: .primary)).frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 18)
                    .disabled(model.files.isEmpty)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "doc.text.viewfinder").font(.system(size: 25)).foregroundStyle(Color.muted)
                    Text("Select a file to inspect its details.").font(.system(size: 10)).foregroundStyle(Color.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.surface)
    }

    private func metadataRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 9)).foregroundStyle(Color.muted)
            Spacer(minLength: 10)
            Text(value).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1).textSelection(.enabled)
        }
        .frame(height: 29)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border.opacity(0.7)).frame(height: 1) }
    }

    private var focusedFile: RecoveredFile? {
        if let focusedFileID, let focused = displayedFiles.first(where: { $0.id == focusedFileID }) { return focused }
        return displayedFiles.first
    }

    private var displayedFiles: [RecoveredFile] {
        var files = filesForTab(model.filter)
        if showingQueue { files = files.filter { model.selectedFileIDs.contains($0.id) } }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            files = files.filter {
                "\($0.name).\($0.fileExtension)".lowercased().contains(query)
                    || $0.fileExtension.lowercased().contains(query)
                    || String($0.offset, radix: 16).contains(query.replacingOccurrences(of: "0x", with: ""))
            }
        }
        switch sortColumn {
        case .name:
            files.sort {
                let result = "\($0.name).\($0.fileExtension)".localizedStandardCompare("\($1.name).\($1.fileExtension)")
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        case .type:
            files.sort {
                let result = $0.fileExtension.localizedStandardCompare($1.fileExtension)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        case .size: files.sort { sortAscending ? $0.size < $1.size : $0.size > $1.size }
        case .offset: files.sort { sortAscending ? $0.offset < $1.offset : $0.offset > $1.offset }
        }
        return files
    }

    private func filesForTab(_ kind: FileKind?) -> [RecoveredFile] {
        let files = kind.map { selectedKind in model.files.filter { $0.kind == selectedKind } } ?? model.files
        return files
    }

    private var exportButtonTitle: String {
        model.selectedFileIDs.isEmpty ? "Export all (\(model.files.count))" : "Export selected (\(model.selectedFileIDs.count))"
    }

    private func tabName(_ kind: FileKind) -> String {
        switch kind {
        case .image: "Photos"
        case .video: "Video"
        case .document: "Documents"
        case .audio: "Audio"
        case .raw: "RAW"
        case .unknown: "Other"
        }
    }

    private func speedText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private func etaText(_ seconds: Double?) -> String {
        guard model.scanning, let seconds, seconds.isFinite else { return "—" }
        if seconds < 60 { return "~\(Int(seconds.rounded())) sec" }
        return "~\(Int((seconds / 60).rounded())) min"
    }

    private enum SortColumn { case name, type, size, offset }
}

private struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let foreground: Color = kind == .primary ? Color.canvas : Color.ink
        let background: Color = {
            switch kind {
            case .primary: Color.mint
            case .secondary: Color.raised
            case .danger: Color.coral.opacity(0.15)
            }
        }()
        return configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(kind == .danger ? Color.coral : foreground)
            .padding(.horizontal, 12).frame(height: 32)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(kind == .secondary ? Color.border : Color.clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

private struct SectorMapView: View {
    let progress: ScanProgress

    var body: some View {
        Canvas { context, size in
            let columns = 64
            let rows = 5
            let horizontalGap: CGFloat = 3
            let verticalGap: CGFloat = 3
            let cellWidth = (size.width - CGFloat(columns - 1) * horizontalGap) / CGFloat(columns)
            let cellHeight = (size.height - CGFloat(rows - 1) * verticalGap) / CGFloat(rows)
            let count = columns * rows
            for index in 0..<count {
                let start = UInt64(Double(progress.total) * Double(index) / Double(count))
                let end = UInt64(Double(progress.total) * Double(index + 1) / Double(count))
                let color: Color
                if overlaps(start, end, progress.readErrors) {
                    color = .coral
                } else if overlaps(start, end, progress.candidateRanges) {
                    color = .blue
                } else if overlaps(start, end, progress.scannedRanges) {
                    color = .mint.opacity(0.66)
                } else {
                    color = .raised
                }
                let x = CGFloat(index % columns) * (cellWidth + horizontalGap)
                let y = CGFloat(index / columns) * (cellHeight + verticalGap)
                let rect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
        .accessibilityLabel("Scan map. Blue shows possible file data, green shows scanned areas, red shows read errors, and dark blocks are not scanned.")
    }

    private func overlaps(_ start: UInt64, _ end: UInt64, _ ranges: [ScannedRange]) -> Bool {
        ranges.contains { $0.start < end && $0.end > start }
    }
}

@MainActor private struct FilePreviewImage: View {
    let file: RecoveredFile
    var contentMode: ContentMode = .fill
    @State private var previewData: Data?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.raised
                if let previewData, let image = PreviewImageCache.image(for: previewData, key: "\(file.id.uuidString)-detail") {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: file.kind.symbol).font(.system(size: min(24, geometry.size.height * 0.4))).foregroundStyle(Color.mint)
                        if file.kind == .image || file.kind == .raw {
                            Text("Preview unavailable").font(.system(size: 8)).foregroundStyle(Color.muted)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .task(id: file.id) {
            guard file.kind == .image || file.kind == .raw else { return }
            if let embedded = file.embeddedThumbnailData {
                previewData = embedded
                return
            }
            previewData = await PreviewLoader.shared.load(file)
        }
    }
}

@MainActor private struct ImagePreviewButton: View {
    let file: RecoveredFile
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            FilePreviewImage(file: file)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.ink)
                        .padding(7).background(Color.canvas.opacity(0.9), in: Circle()).padding(8)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open image preview")
        .accessibilityLabel("Open larger preview of \(file.name).\(file.fileExtension)")
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: file.kind.symbol).foregroundStyle(Color.mint)
                    Text("\(file.name).\(file.fileExtension)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                    Spacer()
                    Button("Close") { isPresented = false }
                        .font(.system(size: 10, weight: .medium)).buttonStyle(.plain).foregroundStyle(Color.muted)
                }
                .padding(.horizontal, 14).frame(height: 42)
                Rectangle().fill(Color.border).frame(height: 1)
                FilePreviewImage(file: file, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.canvas)
                    .padding(12)
                Text("\(file.sizeDescription) · Offset 0x\(String(file.offset, radix: 16, uppercase: true))")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
            }
            .frame(width: 660, height: 520)
            .background(Color.surface)
            .preferredColorScheme(.dark)
        }
    }
}

@MainActor private enum PreviewImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    static func image(for data: Data, key: String) -> NSImage? {
        let cacheKey = key as NSString
        if let image = cache.object(forKey: cacheKey) { return image }
        guard let image = NSImage(data: data) else { return nil }
        let cost = min(Double(Int.max), max(1, image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: cacheKey, cost: Int(cost))
        return image
    }
}

@MainActor private enum PreviewDataCache {
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func data(for key: String) -> Data? { cache.object(forKey: key as NSString) as Data? }
    static func store(_ data: Data, for key: String) { cache.setObject(data as NSData, forKey: key as NSString, cost: data.count) }
}

private func makePreviewData(from file: RecoveredFile) -> Data? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    let source: CGImageSource?
    if let stagedURL = file.stagedFileURL {
        source = CGImageSourceCreateWithURL(stagedURL as CFURL, sourceOptions)
    } else {
        source = CGImageSourceCreateWithData(file.data as CFData, sourceOptions)
    }
    guard let source else { return nil }
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 480,
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

private actor PreviewLoader {
    static let shared = PreviewLoader()
    private let limit = 3
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func load(_ file: RecoveredFile) async -> Data? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) { makePreviewData(from: file) }.value
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private struct ScanMapBar: View {
    let ranges: [ScannedRange]
    let total: UInt64

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.ink.opacity(0.12))
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                    let denominator = Double(max(1, total))
                    let start = min(1, Double(range.start) / denominator)
                    let end = min(1, Double(range.end) / denominator)
                    Rectangle()
                        .fill(Color(red: 0.25, green: 0.52, blue: 0.94))
                        .frame(width: max(1, geometry.size.width * (end - start)))
                        .offset(x: geometry.size.width * start)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityLabel("Scanned storage regions")
        .accessibilityValue("\(ranges.count) scanned region(s)")
    }
}

struct FileCard: View {
    @State private var previewData: Data?
    let file: RecoveredFile
    let isSelected: Bool
    let onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color.lilac.opacity(0.18), Color.mint.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                GeometryReader { geometry in
                    if file.kind == .image, let previewData,
                       let image = PreviewImageCache.image(for: previewData, key: file.id.uuidString) {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Image(systemName: file.kind.symbol).font(.system(size: 38)).foregroundStyle(Color.lilac)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.lilac).padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 135)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(file.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
            HStack { Text(file.kind.rawValue); Text("·"); Text(file.sizeDescription) }.font(.caption).foregroundStyle(Color.muted)
            Text(file.recoverySource.label).font(.caption2).foregroundStyle(Color.muted).lineLimit(1)
        }
        .padding(12).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(isSelected ? Color.lilac : Color.white, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.name), \(file.kind.rawValue), \(file.sizeDescription)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: file.id) {
            guard file.kind == .image else { return }
            let key = file.id.uuidString
            if let cached = PreviewDataCache.data(for: key) {
                previewData = cached
                return
            }
            let result = await PreviewLoader.shared.load(file)
            guard !Task.isCancelled, let result else { return }
            PreviewDataCache.store(result, for: key)
            previewData = result
        }
    }
}

private struct EmbeddedThumbnailCard: View {
    let file: RecoveredFile
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geometry in
                    if let data = file.embeddedThumbnailData,
                       let image = PreviewImageCache.image(for: data, key: "\(file.id.uuidString)-embedded") {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Color.lilac.opacity(0.12))
                    }
                }
                .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("From \(file.name)").font(.caption).foregroundStyle(Color.muted).lineLimit(1)
            }
            .padding(10)
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? Color.lilac : Color.white, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Embedded thumbnail from \(file.name), select parent photo")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
