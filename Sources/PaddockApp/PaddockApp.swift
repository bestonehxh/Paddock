import AppKit
import PaddockCore
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        // Dark only (owner, 3 Oct 2026): the whole app, menus and sheets included, regardless
        // of the system appearance.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        PaddockApp.main()
    }
}

struct PaddockApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Paddock", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 600)
        }
        // No title bar: the traffic lights sit over the sidebar, and the content starts at the top
        // of the window (as LabDC). When the sidebar is hidden the detail bar leaves room for them.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 780)
    }
}
