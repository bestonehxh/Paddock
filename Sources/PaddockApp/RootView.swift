import AppKit
import PaddockCore
import SwiftUI

/// The window: the flat 220 pt sidebar (hosts and their VMs) and the detail (bar + tab page).
/// ⌘\ hides the sidebar so the console fills the window.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAddHost = false
    @State private var dragStart: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView(showingAddHost: $showingAddHost)
                    .frame(width: model.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(Theme.sidebar.ignoresSafeArea())
                    .overlay(alignment: .trailing) {
                        // The edge is a drag handle: long VM names get the room they need.
                        Rectangle().fill(Color.clear).frame(width: 7)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                                model.sidebarWidth = max(220, min(420, model.sidebarWidth + value.translation.width - dragStart))
                                dragStart = value.translation.width
                            }.onEnded { _ in dragStart = 0 })
                    }
            }
            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
        }
        .ignoresSafeArea(.container, edges: .top)   // the content owns the strip where the title bar was
        // Full screen hides the traffic lights: HOSTS and the bar move up (owner, 3 Oct 2026).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            model.windowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            model.windowFullScreen = false
        }
        // Background console streams follow the VMs: a VM that stopped running loses its stream.
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            for host in model.hosts {
                for vm in host.vms {
                    ConsolePool.shared.dropIfNotRunning(key: "\(host.address)/\(vm.ref.value)", running: vm.powerState == .poweredOn)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            ConsolePool.shared.disconnectAll()
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostSheet()
        }
        // ⌘\ anywhere in the window.
        .background {
            Button("Toggle Sidebar") {
                withAnimation(.easeOut(duration: 0.15)) { model.sidebarVisible.toggle() }
            }
            .keyboardShortcut("\\", modifiers: .command)
            .accessibilityHidden(true)
            .opacity(0)
        }
    }
}
