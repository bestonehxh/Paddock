import LabDockCore
import SwiftUI

/// Address / User / Password → Connect shows the certificate's subject and SHA-1 thumbprint,
/// then "Trust this certificate and warn if it changes" and Cancel / Connect.
struct AddHostSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var user = "root"
    @State private var password = ""
    @State private var probing = false
    @State private var probe: HostProbe?
    /// Ticked: the thumbprint is pinned and a change is reported. Unticked: the host is added
    /// without a pin; the first poll records what it sees.
    @State private var trust = true
    @State private var failure: String?

    var body: some View {
        QuietSheet(title: "Add host",
                   subtitle: probe == nil ? "The password goes into the Keychain and nowhere else." : nil,
                   failure: failure) {
            if let probe {
                VStack(alignment: .leading, spacing: 14) {
                    SheetField("Host") {
                        Text(probe.product.isEmpty ? address : probe.product)
                            .font(Theme.body).foregroundStyle(Theme.ink)
                    }
                    SheetField("Certificate subject") {
                        Text(probe.certificateSubject ?? "—")
                            .font(Theme.body).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                    SheetField("SHA-1 thumbprint", note: "LabDock reconnects only when the certificate matches this; if it changes you are asked again.") {
                        Text(probe.thumbprintSHA1)
                            .font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                    SheetField("SHA-256 thumbprint", note: "The same certificate, the stronger hash: once LabDock has seen it, this is the match it requires.") {
                        Text(probe.thumbprintSHA256)
                            .font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                    }
                    Toggle("Trust this certificate and warn if it changes", isOn: $trust)
                        .toggleStyle(.quiet)
                    if !trust {
                        Text("Unticked, the host is added without a pinned certificate; the first connection records whatever it presents.")
                            .font(Theme.caption).foregroundStyle(Theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                SheetField("Address", note: "The host name or IP as ESXi answers on 443.") {
                    QuietTextField("Address", text: $address, prompt: "192.168.1.10")
                }
                SheetField("User") {
                    QuietTextField("User", text: $user, prompt: "root")
                }
                SheetField("Password") {
                    QuietTextField("Password", text: $password, prompt: "", secure: true)
                }
            }
        } actions: {
            if probing {
                Text("Connecting…").font(Theme.caption).foregroundStyle(Theme.faint)
            }
            SheetButtons("Connect", disabled: !inputOK || probing, action: nextStep)
        }
        .onSubmit { if inputOK && !probing { nextStep() } }
    }

    private var inputOK: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private func nextStep() {
        let host = address.trimmingCharacters(in: .whitespaces)
        let name = user.trimmingCharacters(in: .whitespaces)
        if let probe {
            do {
                try model.addHost(address: host, user: name, password: password, probe: probe, pin: trust)
                dismiss()
            } catch {
                // Stays open: a duplicate, a refused Keychain or an unreadable hosts.json is
                // said here, where the user can still change something.
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            // No need to go to the network for a host that is already listed.
            if model.hosts.contains(where: { $0.address == host }) {
                failure = "\(host) is already in the sidebar"
                return
            }
            probing = true
            failure = nil
            Task {
                do {
                    probe = try await model.probe(address: host, user: name, password: password)
                } catch {
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                probing = false
            }
        }
    }
}
