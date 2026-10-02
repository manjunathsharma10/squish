import AppKit
import SwiftUI

@main
struct SquishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Squish", id: "main") {
            ContentView()
                .environment(AppModel.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { AppModel.shared.isImporting = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(before: .toolbar) {
                // Settings are locked while a batch runs.
                Button("Compress") { if !AppModel.shared.isRunning { AppModel.shared.settings.mode = .compress } }
                    .keyboardShortcut("1")
                Button("Convert") { if !AppModel.shared.isRunning { AppModel.shared.settings.mode = .convert } }
                    .keyboardShortcut("2")
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainActor.assumeIsolated { DebugSnapshot.runIfRequested() }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls) }
    }
}
