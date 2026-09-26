import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: RecoveryModel
    @State private var searchText = ""
    @State private var focusedFileID: UUID?
    @State private var showingQueue = false
    @State private var sortColumn: SortColumn = .offset
    @State private var sortAscending = true
    @State private var sidebarWidth: CGFloat = 248
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var isHoveringSidebarResizeHandle = false
    @State private var isDraggingSidebar = false
    private let paneHeaderHeight: CGFloat = 43
    private let sidebarMinimumWidth: CGFloat = 200
    private let sidebarMaximumWidth: CGFloat = 320

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar.frame(width: sidebarWidth)
                sidebarResizeHandle
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
                AccessDialogView()
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

    private var sidebarResizeHandle: some View {
        ZStack {
            Rectangle().fill(Color.border).frame(width: 1)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(isHoveringSidebarResizeHandle || isDraggingSidebar ? Color.mint : Color.muted)
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: 9, height: 26)
            .background(Color.surface, in: Capsule())
            .overlay(Capsule().stroke(Color.border, lineWidth: 1))
        }
        .frame(width: 9)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    isDraggingSidebar = true
                    if sidebarDragStartWidth == nil {
                        sidebarDragStartWidth = sidebarWidth
                    }
                    guard let startWidth = sidebarDragStartWidth else { return }
                    let boundedWidth = min(
                        max(startWidth + value.translation.width, sidebarMinimumWidth),
                        sidebarMaximumWidth
                    )
                    let scale = NSScreen.main?.backingScaleFactor ?? 1
                    let pixelAlignedWidth = (boundedWidth * scale).rounded() / scale
                    guard pixelAlignedWidth != sidebarWidth else { return }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        sidebarWidth = pixelAlignedWidth
                    }
                }
                .onEnded { _ in
                    sidebarDragStartWidth = nil
                    isDraggingSidebar = false
                }
        )
        .onHover { isHovering in
            isHoveringSidebarResizeHandle = isHovering
            if isHovering { NSCursor.resizeLeftRight.set() }
            else { NSCursor.arrow.set() }
        }
        .accessibilityElement()
        .accessibilityLabel("Resize sidebar")
        .accessibilityValue("\(Int(sidebarWidth)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                sidebarWidth = min(sidebarWidth + 12, sidebarMaximumWidth)
            case .decrement:
                sidebarWidth = max(sidebarWidth - 12, sidebarMinimumWidth)
            @unknown default:
                break
            }
        }
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
                    Text("Goldfish").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink)
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
                                    Text(device.isInternal ? "Internal · not supported · \(device.sizeDescription)" : "\(device.sizeDescription) · \(device.identifier)")
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
            if model.filesStillOnCardCount > 0 {
                Button { model.showFilesStillOnCard.toggle() } label: {
                    Label("\(model.showFilesStillOnCard ? "Hide" : "Show") \(model.filesStillOnCardCount.formatted()) still on card",
                          systemImage: model.showFilesStillOnCard ? "eye.slash" : "eye")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(model.showFilesStillOnCard ? Color.mint : Color.muted)
                        .padding(.horizontal, 10).frame(height: 31)
                        .background(Color.panel, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Files that still have a live entry on the card don't need recovering; you can copy them in Finder.")
            }
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
                Text(rowSubtitle(file))
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
                    Text(file.isFragmented ? "Data spans multiple card regions" : "Offset 0x\(String(file.offset, radix: 16, uppercase: true))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted).lineLimit(1).padding(.top, 5)
                    VStack(spacing: 0) {
                        metadataRow("Type", file.fileExtension.uppercased())
                        metadataRow("Size", file.sizeDescription)
                        metadataRow("Status", file.status.label)
                        metadataRow("Recovery source", file.recoverySource.label)
                        if file.isFragmented { metadataRow("Data regions", "\(file.physicalRanges.count) separated regions") }
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

    /// Signature hits get their directory status; deleted-record sources already say "deleted".
    private func rowSubtitle(_ file: RecoveredFile) -> String {
        file.recoverySource == .signatureScan ? "\(file.status.label) · \(file.recoverySource.label)" : file.recoverySource.label
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
