import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor struct FilePreviewImage: View {
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

@MainActor struct ImagePreviewButton: View {
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

/// Serves a recovered file to ImageIO straight from the device, one window at
/// a time, so previews never hold the whole file in memory.
private final class RecoveredFileWindowReader {
    private static let windowSize = 1024 * 1024

    private let file: RecoveredFile
    private var windowStart: UInt64 = 0
    private var window = Data()

    init(file: RecoveredFile) {
        self.file = file
    }

    func copyBytes(to buffer: UnsafeMutableRawPointer, at position: UInt64, count: Int) -> Int {
        let windowEnd = windowStart + UInt64(window.count)
        if position < windowStart || position >= windowEnd {
            guard let data = try? file.read(at: position, count: max(count, Self.windowSize)) else { return 0 }
            windowStart = position
            window = data
        }
        let lower = Int(position - windowStart)
        let copied = min(count, window.count - lower)
        window.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + lower, byteCount: copied) }
        return copied
    }

    func makeDataProvider() -> CGDataProvider? {
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                Unmanaged<RecoveredFileWindowReader>.fromOpaque(info!).takeUnretainedValue()
                    .copyBytes(to: buffer, at: UInt64(position), count: count)
            },
            releaseInfo: { info in
                Unmanaged<RecoveredFileWindowReader>.fromOpaque(info!).release()
            }
        )
        return CGDataProvider(directInfo: Unmanaged.passRetained(self).toOpaque(), size: off_t(file.size), callbacks: &callbacks)
    }
}

private func makePreviewData(from file: RecoveredFile) -> Data? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let provider = RecoveredFileWindowReader(file: file).makeDataProvider(),
          let source = CGImageSourceCreateWithDataProvider(provider, sourceOptions) else { return nil }
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
