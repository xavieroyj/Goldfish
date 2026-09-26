import SwiftUI
import AppKit

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

@MainActor enum AppBrand {
    static let logo: NSImage? = {
        if let url = Bundle.main.url(forResource: "GoldfishWhite", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        if let url = Bundle.module.url(forResource: "GoldfishWhite", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return nil
    }()
}
