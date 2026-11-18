import AppKit
import SwiftUI

extension Notification.Name {
    static let pdfScannerOpenURLs = Notification.Name("PDFScannerOpenURLs")
}

@MainActor
enum ExternalOpenURLRouter {
    static var pending: [URL] = []

    static func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(contentsOf: urls)
        NotificationCenter.default.post(name: .pdfScannerOpenURLs, object: nil)
    }

    static func drain() -> [URL] {
        guard !pending.isEmpty else { return [] }
        let items = pending
        pending.removeAll()
        return items
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            ExternalOpenURLRouter.enqueue(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScannerBridge.cleanupTemporaryCaches()
    }
}

@main
struct PDFScannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("PDF Scanner") {
            ContentView()
        }
        .handlesExternalEvents(matching: [])
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
