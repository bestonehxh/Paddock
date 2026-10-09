import LabDockCore
import SwiftUI
import VimClient

/// The Install-VMware-Tools affordance shown wherever the guest's Tools matter: the Overview
/// row, and the Files / Run tabs when the guest can't take commands. Windows and macOS guests
/// get the installer CD mounted; Linux guests are told to use open-vm-tools instead.
struct ToolsInstallHint: View {
    let host: HostModel
    let vm: VMSummary
    /// The sentence to show after the CD was mounted.
    @State private var note: String?
    @State private var working = false

    /// ESXi can mount an installer ISO for Windows and macOS guests; for Linux there is none.
    private var mountable: Bool { vm.guestFamily == .windows || vm.guestFamily == .darwin }
    private var poweredOn: Bool { vm.powerState == .poweredOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if mountable {
                Button("Install VMware Tools…") { mount() }
                    .buttonStyle(.quietLink)
                    .disabled(!poweredOn || working || busy)
                if working {
                    Text("Mounting the installer CD…").font(Theme.caption).foregroundStyle(Theme.faint)
                }
                if !poweredOn {
                    Text("Power the VM on first.").font(Theme.caption).foregroundStyle(Theme.faint)
                }
            } else {
                Text("For Linux guests, install open-vm-tools with the guest's package manager.")
                    .font(Theme.caption).foregroundStyle(Theme.faint)
            }
            if let note {
                Text(note)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onChange(of: vm.tools.word) { _, _ in
            // Tools came up (or the state moved): the old instruction has served its purpose.
            if vm.tools.isRunning { note = nil }
        }
    }

    private var busy: Bool { host.busyVMs.contains(vm.ref.value) }

    private func mount() {
        working = true
        Task {
            await host.mountTools(vm: vm)
            working = false
            if host.actionError(vm: vm) == nil {
                note = vm.guestFamily == .windows
                    ? "The installer CD is mounted in the guest — open it and run setup64.exe."
                    : "The installer CD is mounted — run “Install VMware Tools” inside the guest."
            }
        }
    }
}
