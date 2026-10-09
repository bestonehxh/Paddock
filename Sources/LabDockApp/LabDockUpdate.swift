import AppKit

// LabDock's half of the in-app updater: the ONLY file that ties the generic updater in
// Sources/LabDockApp/Update/ (copied unchanged from SheepTerm 5.0 via LabDC, 9 Oct 2026) to this
// app. Releases come from the public repository's latest GitHub Release: `LabDock-<mv>-<b>.zip`
// plus its Ed25519 `.zip.sig`, both made by the Sheep-family release.sh (/ship) from `.ship.conf`.

extension UpdateConfig {
    /// The Ed25519 key whose private half is in the release Mac's login Keychain (service
    /// `signingKeychainService`, account `ed25519`, made once by SheepTerm's Tools/update-keygen.sh
    /// on 9 Oct 2026). `.ship.conf` carries the same value as UPDATE_SIGN_PUBLIC_KEY,
    /// and UpdaterTests fails when the two differ. Not SheepTerm's key: one key per app.
    static let labDock = UpdateConfig(
        appName: "LabDock",
        repository: "bestonehxh/LabDock",
        tagScheme: .build,
        publicKeyBase64: "9XTm9c/3t5E6zg+wOk1eN9q2lOpT2Gt+NfWZ2gogfiY=",
        signingKeychainService: "Bestchaan.LabDock.update-signing"
    )
}

@MainActor
enum AppUpdater {
    /// Install & Relaunch is the only question: LabDock does not ask on ⌘Q either (open consoles
    /// simply close, and the VMs keep running on their hosts), so no extra quit hook.
    static let shared = Updater(config: .labDock, hooks: UpdateHooks())
}
