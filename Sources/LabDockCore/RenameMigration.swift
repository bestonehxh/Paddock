import Foundation

/// The app was called Paddock until 9 Oct 2026 (bundle `Bestchaan.Paddock`). On the first launch
/// as LabDock, the old hosts folder and preferences come across once so nothing has to be added
/// again; the Keychain vault follows on its first read (`Keychain.legacyService`).
public enum RenameMigration {
    static let oldBundleIdentifier = "Bestchaan.Paddock"
    static let oldFolderName = "Paddock"

    /// Call before the model loads hosts.json. Does nothing once the LabDock copies exist.
    public static func run() {
        moveHostsFolder()
        copyPreferences()
    }

    /// ~/Library/Application Support/Paddock → …/LabDock, only when LabDock has no folder yet.
    static func moveHostsFolder() {
        let fm = FileManager.default
        let new = HostStore.defaultDirectory
        let old = new.deletingLastPathComponent().appendingPathComponent(oldFolderName, isDirectory: true)
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    /// The old app's UserDefaults domain (sidebar width, folded hosts, console switches, updater
    /// choices), copied when this bundle's own domain is still empty. Only in the real bundle:
    /// `swift run` and tests have other identifiers.
    static func copyPreferences() {
        guard let id = Bundle.main.bundleIdentifier, id != oldBundleIdentifier else { return }
        let defaults = UserDefaults.standard
        guard defaults.persistentDomain(forName: id)?.isEmpty ?? true,
              let old = defaults.persistentDomain(forName: oldBundleIdentifier), !old.isEmpty
        else { return }
        defaults.setPersistentDomain(old, forName: id)
    }
}
