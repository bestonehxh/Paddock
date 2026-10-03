import AppKit
import Carbon.HIToolbox
import Observation

/// The Mac's current keyboard input source, as a short tag ("EN", "TH"), for the detail bar:
/// the console types through a US-layout keyboard, so anything but a Latin layout means the
/// keys won't land in the guest (owner, 3 Oct 2026: "forgot to switch the language").
@MainActor @Observable
final class KeyboardLanguage {
    static let shared = KeyboardLanguage()
    private(set) var tag = "EN"
    private(set) var isLatin = true
    private var observer: NSObjectProtocol?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The notification only fires for this app's own text input contexts; poll lightly so a
        // switch made while the console has the keyboard shows up too.
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(1))
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        var code = "en"
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
            if let first = languages.first { code = first }
        }
        let newTag = String(code.prefix(2)).uppercased()
        let latin = ["en", "de", "fr", "es", "it", "pt", "nl", "sv", "da", "no", "fi", "pl", "cs", "tr", "id", "ms", "vi"].contains(String(code.prefix(2)))
        if newTag != tag || latin != isLatin {
            tag = newTag
            isLatin = latin
        }
    }
}
