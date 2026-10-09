import AppKit

// Paddock's half of the in-app updater: the ONLY file that ties the generic updater in
// Sources/PaddockApp/Update/ (copied unchanged from SheepTerm 5.0 via LabDC, 9 Oct 2026) to this
// app. Releases come from the public repository's latest GitHub Release: `Paddock-<mv>-<b>.zip`
// plus its Ed25519 `.zip.sig`, both made by the Sheep-family release.sh (/ship) from `.ship.conf`.

extension UpdateConfig {
    /// The Ed25519 key whose private half is in the release Mac's login Keychain (service
    /// `signingKeychainService`, account `ed25519`, made once by SheepTerm's Tools/update-keygen.sh
    /// on 9 Oct 2026). `.ship.conf` carries the same value as UPDATE_SIGN_PUBLIC_KEY,
    /// and UpdaterTests fails when the two differ. Not SheepTerm's key: one key per app.
    static let paddock = UpdateConfig(
        appName: "Paddock",
        repository: "bestonehxh/Paddock",
        tagScheme: .build,
        publicKeyBase64: "MUAD01u4IRzqo5oNMQADsrHdV3jjGcpA9UVHLhk5rKA=",
        signingKeychainService: "Bestchaan.Paddock.update-signing"
    )
}

@MainActor
enum AppUpdater {
    /// Install & Relaunch is the only question: Paddock does not ask on ⌘Q either (open consoles
    /// simply close, and the VMs keep running on their hosts), so no extra quit hook.
    static let shared = Updater(config: .paddock, hooks: UpdateHooks())
}
