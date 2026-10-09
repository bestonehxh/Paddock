import SwiftUI

/// LabDock ▸ Settings… (⌘,). LabDock had no preferences before the in-app updater (9 Oct 2026),
/// so this window holds only Updates, in the Quiet rows of the rest of the app.
struct SettingsView: View {
    @AppStorage(UpdateCore.autoCheckKey) private var checkForUpdates = true

    var body: some View {
        QuietSection("Updates") {
            QuietRow(first: true) {
                Toggle(isOn: $checkForUpdates) {
                    SettingsText(title: "Check for updates automatically",
                                 detail: "Looks for a new LabDock on GitHub a few seconds after it opens and once a day while it stays open. Nothing installs without asking.")
                }
                .toggleStyle(.quiet)
                .accessibilityLabel("Check for updates automatically")
            }
            QuietRow {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SettingsText(title: "Version",
                                 detail: "LabDock \(Self.appVersion). Updates are signed; one that does not verify is never installed.")
                    Spacer(minLength: 12)
                    Button("Check Now") { AppUpdater.shared.checkNow() }
                        .buttonStyle(.quietLink)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Theme.background)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }
}

/// A setting's name with a muted line under it.
private struct SettingsText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.body).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
