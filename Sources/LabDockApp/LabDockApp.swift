import AppKit
import LabDockCore
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        // Dark only (owner, 3 Oct 2026): the whole app, menus and sheets included, regardless
        // of the system appearance.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        RenameMigration.run()   // hosts.json and preferences from the Paddock name, once
        LabDockApp.main()
    }
}

/// The red button folds the window; LabDock stays in the Dock like every other macOS app.
/// A single SwiftUI `Window` scene otherwise terminates the process when its window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // In-app updater (from SheepTerm via LabDC, 9 Oct 2026): checks ~5 s after launch, then daily.
        AppUpdater.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon (or activating the app with no window) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let window = sender.windows.first(where: { $0.title == "LabDock" || $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return false   // the reopen is handled
        }
        return true
    }
}

struct LabDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("LabDock", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 600)
        }
        // No title bar: the traffic lights sit over the sidebar, and the content starts at the top
        // of the window (as LabDC). When the sidebar is hidden the detail bar leaves room for them.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 780)
        .commands {
            // LabDock ▸ Check for Updates…
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkNow() }
            }
        }

        // LabDock ▸ Settings… (⌘,): only the updater's switch for now.
        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}
