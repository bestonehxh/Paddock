import AppKit
import os
import LabDockCore
import SwiftUI
import VimClient
import MKSClient

/// The Console tab: the WebMKS stream fills the detail area, a thin row above it carries
/// Ctrl-Alt-Del / Type clipboard / Paste to guest / Send keys…, and (right) the resolution,
/// fps and the connection / capture words. Works without Tools.
struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    let host: HostModel
    let vm: VMSummary

    @State private var session: MKSSession?
    @State private var state: MKSState = .idle
    @State private var frame: MKSFramebuffer?
    @State private var cursor: MKSCursor?
    @State private var captured = false
    @State private var fps = 0
    /// What an action (ticket, paste, typing through the host) said went wrong; the stream's
    /// own disconnect reason is drawn once, centred over the canvas, not here.
    @State private var error: String?
    @State private var note: String?
    @State private var consumeTask: Task<Void, Never>?
    @State private var fpsTask: Task<Void, Never>?
    @State private var framesThisSecond = 0
    /// Bumped by every `open()`: a ticket that arrives for an older open is dropped, so a
    /// Reconnect click during the ticket wait cannot end in two live sessions.
    @State private var openGeneration = 0
    @State private var showingGuestLogin = false
    @State private var pasteAfterLogin = false
    /// Fit / Actual size; kept for the run of the app, not per VM.
    @State private var zoom = ConsoleZoom.remembered

    // MARK: Rewind (owner, 3 Oct 2026: scroll back through a serial console's output)
    /// Key frames of the stream, newest last, captured when a big area changed. Each frame is
    /// stored as JPEG (a 1080p CGImage is ~8 MB raw; JPEG keeps a minute of history to ~20 MB).
    @State private var rewindHistory: [RewindFrame] = []
    /// Where the viewer stands: an index into `rewindHistory`, or the last index = live.
    @State private var rewindPosition: Double = 0
    @State private var decodedRewindImage: CGImage?
    @State private var decodedRewindIndex = -1
    @State private var lastCapture = Date.distantPast
    /// Total PNG bytes in `rewindHistory`, maintained incrementally — re-summing the whole
    /// array for every dropped frame made each capture O(history).
    @State private var rewindBytes = 0
    /// True while a PNG encode is in flight off the main thread; the next big frame waits.
    @State private var rewindEncoding = false
    /// Bumped whenever the history is cleared; an encode landing after that is dropped.
    @State private var rewindGeneration = 0

    struct RewindFrame {
        let date: Date
        /// PNG: lossless, and a text console compresses to a few tens of KB.
        let png: Data
        let width: Int
        let height: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            rewindBar
        }
        .background(Theme.background)
        .onChange(of: model.clipboardSharing) { _, on in
            if on { startClipboardSharing() } else { stopClipboardSharing() }
        }
        .onChange(of: model.consoleRewind) { _, on in
            if !on {
                rewindHistory.removeAll()
                rewindBytes = 0
                rewindGeneration += 1
                rewindPosition = 0
                decodedRewindImage = nil
                decodedRewindIndex = -1
            } else if let frame {
                captureRewind(frame, dirty: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            }
        }
        .onChange(of: model.consoleCommandRequest) { _, request in
            guard let request else { return }
            perform(request.command)
        }
        .onChange(of: state) { _, _ in publishStatus() }
        .onChange(of: fps) { _, _ in publishStatus() }
        .onChange(of: zoom) { _, _ in publishStatus() }
        .onChange(of: note) { _, _ in publishStatus() }
        .onChange(of: error) { _, _ in publishStatus() }
        .onChange(of: frame?.width) { _, _ in publishStatus() }
        .onChange(of: frame?.height) { _, _ in publishStatus() }
        .onChange(of: rewindPosition) { _, _ in updateDecodedRewind() }
        .onChange(of: rewindHistory.count) { _, _ in updateDecodedRewind() }
        .onAppear { publishStatus() }
        // Morefs repeat across hosts (vm-12 on two hosts), so the task is keyed on both.
        .task(id: "\(host.address)/\(vm.id)") { await open() }
        .onDisappear { close() }
        .onChange(of: zoom) { _, new in ConsoleZoom.remembered = new }
        .sheet(isPresented: $showingGuestLogin, onDismiss: {
            guard pasteAfterLogin else { return }
            pasteAfterLogin = false
            if host.guestLogin(vm: vm) != nil { pasteToGuest() }
        }) {
            GuestLoginSheet(host: host, vm: vm)
        }
    }

    // MARK: Pieces

    /// The "Keys ▾" menu in the bar reads this; the console has no rows of its own any more.
    private func publishStatus() {
        var status = AppModel.ConsoleStatus()
        if let frame { status.size = "\(frame.width.formatted()) × \(frame.height.formatted())" }
        status.fps = fps
        status.connected = state == .connected
        status.zoomFit = zoom == .fit
        switch state {
        case .connected: status.state = "connected"
        case .connecting: status.state = "connecting…"
        case .disconnected: status.state = "disconnected"
        case .idle: status.state = ""
        }
        status.note = error ?? note
        if model.consoleStatus != status { model.consoleStatus = status }
    }

    private func perform(_ command: AppModel.ConsoleCommand) {
        switch command {
        case .ctrlAltDel: session?.sendCtrlAltDel()
        case .pasteIntoConsole: typeClipboard()
        case .sendClipboard: pasteToGuest()
        case .windowsKey: sendCombo([(MKSKeyMap.superKey, true), (MKSKeyMap.superKey, false)])
        case .ctrlEsc: sendCombo([(MKSKeyMap.control, true), (0xFF1B, true), (0xFF1B, false), (MKSKeyMap.control, false)])
        case .altTab: sendCombo([(MKSKeyMap.alt, true), (0xFF09, true), (0xFF09, false), (MKSKeyMap.alt, false)])
        case .ctrlShiftEsc:
            sendCombo([(MKSKeyMap.control, true), (MKSKeyMap.shift, true), (0xFF1B, true), (0xFF1B, false), (MKSKeyMap.shift, false), (MKSKeyMap.control, false)])
        case .zoomFit: zoom = .fit
        case .zoomActual: zoom = .actual
        case .reconnect: ConsolePool.shared.drop(poolKey); Task { await open() }
        case .resizeNow: if let size = lastViewport { viewportChanged(size) }
        }
    }

    /// The frame to draw: the live stream, or the decoded history frame while rewound.
    private var shownFrame: MKSFramebuffer? {
        guard let frame else { return nil }
        let maxIndex = rewindHistory.count - 1
        let index = Int(rewindPosition)
        guard index < maxIndex, let image = decodedRewindImage, rewindHistory.indices.contains(index) else { return frame }
        let h = rewindHistory[index]
        return MKSFramebuffer(width: h.width, height: h.height, image: image)
    }

    /// Looking at history, not the live screen: keys and the mouse stay on the Mac.
    private var isRewound: Bool { Int(rewindPosition) < rewindHistory.count - 1 }

    /// "−38 s" while looking back, "live" at the right end.
    private var rewindLabel: String {
        let index = Int(rewindPosition)
        guard index < rewindHistory.count - 1, rewindHistory.indices.contains(index) else { return "live" }
        let back = Date().timeIntervalSince(rewindHistory[index].date)
        return String(format: "−%.0f s", max(0, back))
    }

    /// The thin rewind row under the canvas; hidden until there is a history to scroll.
    @ViewBuilder private var rewindBar: some View {
        if model.consoleRewind, rewindHistory.count > 1, state == .connected {
            HStack(spacing: 12) {
                Text("Rewind").font(Theme.caption).foregroundStyle(Theme.faint)
                Slider(value: $rewindPosition, in: 0...Double(max(rewindHistory.count - 1, 0)))
                    .controlSize(.small)
                Text(rewindLabel)
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(isRewound ? Theme.ink : Theme.faint)
                    .frame(width: 52, alignment: .trailing)
                if isRewound {
                    Text("keys and mouse paused").font(Theme.caption).foregroundStyle(Theme.faint)
                }
                Button("Live") { rewindPosition = Double(rewindHistory.count - 1) }
                    .buttonStyle(.quietLink)
                    .font(Theme.caption)
                    .disabled(Int(rewindPosition) >= rewindHistory.count - 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(height: 30)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .help("Scrolls back through what the console showed. The guest keeps running; drag to the right end (or Live) to return.")
        }
    }

    @ViewBuilder private var canvas: some View {
        switch state {
        case .connected, .connecting:
            if let shownFrame {
                ConsoleCanvas(frame: shownFrame, cursor: cursor, zoom: zoom, captured: $captured, session: session,
                              inputEnabled: !isRewound,
                              onPaste: { pasteFromMac() }, onCopy: { copyToMac() },
                              onViewportSize: { viewportChanged($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(0)
            } else {
                Text("Waiting for the first frame…")
                    .font(Theme.detail).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .idle:
            Text("Opening the console…").font(Theme.detail).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disconnected(let reason):
            // The one place the disconnect sentence is drawn.
            VStack(alignment: .leading, spacing: 8) {
                Text(reason ?? "The console closed.")
                    .font(Theme.detail).foregroundStyle(Theme.attention)
                    .textSelection(.enabled)
                Text("Console tickets are single-use and short-lived; reconnecting takes a new one.")
                    .font(Theme.caption).foregroundStyle(Theme.faint)
                Button("Reconnect") { Task { await open() } }
                    .buttonStyle(.quietLink).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: Session

    private var poolKey: String { "\(host.address)/\(vm.ref.value)" }

    private func open() async {
        openGeneration += 1
        let generation = openGeneration
        close()
        error = nil
        note = nil
        frame = nil
        cursor = nil
        state = .idle
        // No ticket for a VM that has no screen: ESXi answers InvalidState. Say so instead.
        guard vm.powerState == .poweredOn, !vm.inaccessible else {
            ConsolePool.shared.drop(poolKey)
            state = .disconnected(reason: vm.inaccessible
                ? "ESXi can't open this virtual machine, so it has no console."
                : vm.powerState == .suspended ? "The VM is suspended. Power it on (Power ▾) to see its console."
                : "The VM is off. Power it on (Power ▾) to see its console.")
            return
        }
        // A stream kept alive from the last visit: show it at once, no new ticket.
        if let kept = ConsolePool.shared.backend(for: poolKey), kept.isLive {
            attach(kept)
            kept.session.resume()   // frames flow again, starting with a full redraw
            return
        }
        do {
            let ticket = try await host.consoleTicket(vm: vm)
            // The view moved to another VM (the .task was cancelled) or a newer open() took
            // over while the ticket was on its way: this ticket is simply never used.
            guard !Task.isCancelled, generation == openGeneration else { return }
            close()   // whatever connected in the meantime goes away before the new stream starts
            guard let ticketURL = ticket.url else {
                state = .disconnected(reason: "The host sent a console ticket that can't be used.")
                return
            }
            let newSession = MKSSession(url: ticketURL, expectedThumbprint: host.info.thumbprint,
                                        expectedThumbprintSHA256: host.info.thumbprintSHA256)
            let backend = ConsoleBackend(key: poolKey, session: newSession)
            ConsolePool.shared.put(backend)
            attach(backend)
            state = .connecting
            newSession.connect()
        } catch {
            guard !Task.isCancelled, generation == openGeneration else { return }
            state = .disconnected(reason: Self.sentence(for: error))
        }
    }

    /// Binds the view to a backend: its events flow into `handle`, its last frame shows now.
    private func attach(_ backend: ConsoleBackend) {
        session = backend.session
        state = backend.state == .idle ? .connecting : backend.state
        frame = backend.frame
        cursor = backend.cursor
        backend.sink = { event in handle(event) }
        fpsTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                fps = framesThisSecond
                framesThisSecond = 0
            }
        }
        startClipboardSharing()
    }

    private func stopClipboardSharing() {
        clipboardTasks.forEach { $0.cancel() }
        clipboardTasks = []
        if let sync = clipboardSync {
            clipboardSync = nil
            Task { await sync.stop() }
        }
    }

    /// Starts the watcher in the guest and the two polling loops: guest → Mac every second,
    /// Mac → guest whenever the pasteboard's change count moves.
    private static let log = Logger(subsystem: "Bestchaan.LabDock", category: "clipboard")

    private func startClipboardSharing() {
        guard model.clipboardSharing else { Self.log.notice("sharing off"); return }
        guard vm.tools.isRunning else { Self.log.notice("no tools on \(vm.name, privacy: .public)"); return }
        guard clipboardSync == nil else { return }
        guard host.hasGuestLogin(vm: vm) else {
            Self.log.notice("no guest login saved for \(vm.name, privacy: .public) (\(vm.ref.value, privacy: .public))")
            note = "Set a guest login (Overview) to share the clipboard with this guest."
            return
        }
        guard let login = host.guestLogin(vm: vm) else {
            Self.log.notice("guest login saved but unreadable for \(vm.name, privacy: .public): the Keychain refused")
            note = "The Keychain didn't let LabDock read the guest login; click Allow when macOS asks, then reopen the console."
            return
        }
        guard let s = try? host.sessionForGuest() else { Self.log.notice("no host session"); return }
        Self.log.notice("starting clipboard sharing on \(vm.name, privacy: .public)")
        let sync = GuestClipboardSync(session: s, vm: vm.ref, login: login, family: vm.guestFamily)
        clipboardSync = sync
        ignoredPasteboardCount = NSPasteboard.general.changeCount
        clipboardTasks = [
            Task {
                do {
                    try await sync.start()
                    note = "Clipboard sharing is starting in the guest…"
                    if await sync.waitUntilReady(timeout: 30) {
                        if await !sync.guestHasClipboard {
                            Self.log.notice("guest has no clipboard tool; ⌘V types instead")
                            note = "This guest has no clipboard (no X11/Wayland); ⌘V types the text in instead."
                            await sync.stop()
                            clipboardSync = nil
                            return
                        }
                        Self.log.notice("watcher ready")
                        note = "Clipboard sharing on: ⌘C in the guest, ⌘V on the Mac, and back."
                    } else {
                        Self.log.notice("watcher never came up")
                        note = "Clipboard sharing didn't come up in the guest (is the user logged in on its desktop?)."
                    }
                } catch {
                    note = "Clipboard sharing couldn't start: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    return
                }
                while !Task.isCancelled {
                    if let text = try? await sync.pollGuest(), text != lastSharedText {
                        Self.log.notice("guest → mac \(text.count) chars")
                        lastSharedText = text
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ignoredPasteboardCount = NSPasteboard.general.changeCount
                        note = "Guest → Mac: \(text.count) characters on the Mac's clipboard."
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            },
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(700))
                    let count = NSPasteboard.general.changeCount
                    guard count != ignoredPasteboardCount, await sync.started else { continue }
                    ignoredPasteboardCount = count
                    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty, text != lastSharedText else { continue }
                    lastSharedText = text
                    Self.log.notice("mac → guest \(text.count) chars")
                    _ = try? await sync.push(text, timeout: 0.1)   // fire and forget; ⌘V waits for its own ack
                }
            },
        ]
    }

    private func close() {
        stopClipboardSharing()
        if let kept = ConsolePool.shared.backend(for: poolKey), kept.session === session {
            kept.sink = nil           // the stream stays connected in the background…
            kept.session.pause()      // …but asks for no frames until it is shown again
            kept.lastDetached = Date()
        } else {
            session?.disconnect()
        }
        consumeTask?.cancel()
        consumeTask = nil
        fpsTask?.cancel()
        fpsTask = nil
        session = nil
        captured = false
        fps = 0
        framesThisSecond = 0
        rewindHistory = []
        rewindBytes = 0
        rewindGeneration += 1
        rewindPosition = 0
        decodedRewindImage = nil
        decodedRewindIndex = -1
        lastCapture = .distantPast
    }

    // MARK: Rewind

    private static let rewindMaxFrames = 400
    private static let rewindMaxBytes = 48 << 20
    /// A rectangle covering at least this fraction of the screen counts as a moment worth
    /// keeping (a serial console's scroll fills the whole framebuffer; a blinking caret does not).
    private static let rewindAreaFraction = 0.12

    /// Keeps a key frame when a large area changed and the last capture is a second old.
    private func captureRewind(_ f: MKSFramebuffer, dirty: CGRect) {
        guard model.consoleRewind, let image = f.image, f.width > 0, f.height > 0 else { return }
        let area = dirty.width * dirty.height / Double(f.width * f.height)
        let now = Date()
        // A boot log scrolls 20 lines a second: ten captures a second keeps every line
        // (review, 3 Oct 2026; one a second lost most of them).
        guard area >= Self.rewindAreaFraction, now.timeIntervalSince(lastCapture) >= 0.1 else { return }
        // One encode at a time, off the main thread: PNG-ing a 1080p frame costs tens of
        // milliseconds, and ten of those a second on the main actor showed as hitching. A
        // frame during an encode is skipped — the throttle catches up at once.
        guard !rewindEncoding else { return }
        rewindEncoding = true
        let width = f.width, height = f.height, generation = rewindGeneration
        Task {
            let png = await Task.detached(priority: .utility) {
                NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }.value
            rewindEncoding = false
            guard let png else { return }
            appendRewindFrame(png: png, date: now, width: width, height: height, generation: generation)
        }
    }

    /// Lands an encoded key frame in the history; the slider, the ring bound and the byte
    /// count move together.
    private func appendRewindFrame(png: Data, date: Date, width: Int, height: Int, generation: Int) {
        guard model.consoleRewind, generation == rewindGeneration else { return }
        lastCapture = date
        let wasLive = Int(rewindPosition) >= rewindHistory.count - 1
        rewindHistory.append(RewindFrame(date: date, png: png, width: width, height: height))
        rewindBytes += png.count
        // Keep the ring bounded; dropping the oldest shifts what the slider points at.
        var dropped = 0
        var droppedBytes = 0
        while dropped < rewindHistory.count,
              rewindHistory.count - dropped > Self.rewindMaxFrames
                || rewindBytes - droppedBytes > Self.rewindMaxBytes {
            droppedBytes += rewindHistory[dropped].png.count
            dropped += 1
        }
        if dropped > 0 {
            rewindHistory.removeFirst(dropped)
            rewindBytes -= droppedBytes
            if !wasLive { rewindPosition = max(0, rewindPosition - Double(dropped)) }
        }
        rewindPosition = wasLive ? Double(rewindHistory.count - 1) : min(rewindPosition + 1, Double(rewindHistory.count - 1))
        updateDecodedRewind()
    }

    /// Decodes the frame the slider points at; the last index means live (no decode).
    private func updateDecodedRewind() {
        let index = Int(rewindPosition)
        guard rewindHistory.indices.contains(index), index < rewindHistory.count - 1 else {
            decodedRewindImage = nil
            decodedRewindIndex = -1
            return
        }
        guard decodedRewindIndex != index else { return }
        decodedRewindImage = NSBitmapImageRep(data: rewindHistory[index].png)?.cgImage
        decodedRewindIndex = index
    }

    private func handle(_ event: MKSEvent) {
        switch event {
        case .state(let s):
            if case .disconnected(let reason) = s, let reason {
                state = .disconnected(reason: Self.sentence(forDisconnect: reason))
            } else {
                state = s
            }
        case .frame(let f, let dirty):
            frame = f
            framesThisSecond += 1   // the only place frames are counted
            captureRewind(f, dirty: dirty)
        case .cursor(let c):
            cursor = c
        case .cursorPosition, .resized:
            break   // the canvas re-reads the framebuffer on the next frame event
        case .clipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            // The Mac→guest loop must not read this as a fresh Mac-side change and carry the
            // same text straight back.
            lastSharedText = text
            ignoredPasteboardCount = NSPasteboard.general.changeCount
            note = "The guest put \(text.count) characters on the Mac's clipboard."
        case .resizeRefused:
            note = "The guest kept its own screen size (it needs VMware Tools to follow the window)."
        }
    }

    private static func sentence(for error: Error) -> String {
        sentence(forDisconnect: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// The stream's reason as a sentence: POSIX 57 arrives as Foundation's "The operation
    /// couldn't be completed. Socket is not connected".
    private static func sentence(forDisconnect reason: String) -> String {
        if reason.localizedCaseInsensitiveContains("socket is not connected") {
            return "The console connection dropped (socket is not connected)."
        }
        return reason
    }

    private func sendCombo(_ presses: [(UInt32, Bool)]) {
        for (keysym, down) in presses {
            session?.sendKey(keysym: keysym, down: down)
        }
    }

    /// Types the Mac clipboard into the guest as key presses: through the console when it is
    /// connected, otherwise as USB keystrokes through the host (works without Tools; US keys only).
    private func typeClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            note = "The Mac's clipboard holds no text."
            return
        }
        error = nil
        if state == .connected, let session {
            let skipped = session.sendText(text)
            note = typedNote(count: text.count, skipped: skipped.count)
            return
        }
        note = "Typing through the host…"
        Task {
            do {
                let skipped = try await host.sessionForGuest().type(text, vm: vm.ref)
                note = typedNote(count: text.count, skipped: skipped.count)
            } catch {
                note = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func typedNote(count: Int, skipped: Int) -> String {
        skipped == 0
            ? "Typed \(count) characters."
            : "Typed, skipping \(skipped) character(s) the console keyboard can't type."
    }

    // MARK: ⌘V / ⌘C and the window size

    @State private var resizeTask: Task<Void, Never>?
    @State private var lastViewport: CGSize?
    /// Two-way clipboard sharing through Tools (Keys ▾ ▸ Share clipboard).
    @State private var clipboardSync: GuestClipboardSync?
    @State private var clipboardTasks: [Task<Void, Never>] = []
    /// The last text that crossed, in either direction, so it isn't bounced back.
    @State private var lastSharedText: String?
    @State private var ignoredPasteboardCount = 0

    /// ⌘V while captured: with Tools and a saved guest login the text goes to the guest's
    /// clipboard and Ctrl+V is pressed; otherwise it is typed in (works everywhere, US keys).
    private func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            note = "The Mac's clipboard holds no text."
            return
        }
        if let sync = clipboardSync {
            Task {
                lastSharedText = text
                let acked = (try? await sync.push(text, timeout: 3)) ?? false
                if !acked { note = "The guest hasn't taken the clipboard yet; typing it instead."; _ = session?.sendText(text); return }
                pressControl("v")
            }
            return
        }
        if vm.tools.isRunning, let login = host.guestLogin(vm: vm) {
            error = nil
            note = "Pasting through the guest's clipboard…"
            Task {
                do {
                    let s = try host.sessionForGuest()
                    try await s.paste(text, vm: vm.ref, login: login, family: vm.guestFamily)
                    pressControl("v")
                    note = "Pasted \(text.count) characters."
                } catch {
                    // The clipboard route failed (no desktop session, no clipboard tool): type it.
                    let skipped = session?.sendText(text) ?? []
                    note = "Typed instead (\((error as? LocalizedError)?.errorDescription ?? "clipboard unavailable")); " + typedNote(count: text.count, skipped: skipped.count)
                }
            }
        } else {
            // No clipboard route: type it in (the same path as "Paste into console", which also
            // covers a console that isn't streaming by typing through the host).
            typeClipboard()
            if vm.tools.isRunning, let n = note { note = n + " Set a guest login (Overview) to paste through the clipboard instead." }
        }
    }

    /// ⌘C while captured: Ctrl+C has gone to the guest; with Tools and a login the guest's
    /// clipboard is read back a moment later and put on the Mac's.
    private func copyToMac() {
        if clipboardSync != nil { return }   // the watcher picks the copy up within a second
        guard vm.tools.isRunning, let login = host.guestLogin(vm: vm) else {
            note = vm.tools.isRunning ? "Copied in the guest. Set a guest login (Overview) to bring it to the Mac too." : nil
            return
        }
        note = "Reading the guest's clipboard…"
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            do {
                let s = try host.sessionForGuest()
                var interactive = login
                interactive.interactive = true
                let script: String
                switch vm.guestFamily {
                case .windows:
                    script = "$t = Get-Clipboard -Raw -ErrorAction SilentlyContinue; if (-not $t) { Add-Type -AssemblyName System.Windows.Forms; $t = [System.Windows.Forms.Clipboard]::GetText() }; [Console]::Out.Write($t)"
                case .darwin: script = "pbpaste"
                default: script = "if command -v wl-paste >/dev/null 2>&1; then wl-paste -n; elif command -v xclip >/dev/null 2>&1; then DISPLAY=:0 xclip -o -selection clipboard; else xsel -ob; fi"
                }
                let result = try await s.run(script, shell: vm.guestFamily == .windows ? .powershell : .sh, vm: vm.ref,
                                             login: interactive, family: vm.guestFamily, timeout: 30)
                var text = result.output
                if text.hasSuffix("\r\n") { text.removeLast(2) } else if text.hasSuffix("\n") { text.removeLast() }
                guard !text.isEmpty else { note = "The guest's clipboard is empty."; return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                note = "Copied \(text.count) characters from the guest to the Mac's clipboard."
            } catch {
                note = nil
                self.error = "Couldn't read the guest's clipboard: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    /// Ctrl+letter through the stream (a light version of the view's combo; Super isn't held
    /// while a SwiftUI action runs).
    private func pressControl(_ letter: Character) {
        guard let keysym = MKSKeyMap.keysym(for: letter) else { return }
        sendCombo([(MKSKeyMap.control, true), (keysym, true), (keysym, false), (MKSKeyMap.control, false)])
    }

    /// Fit mode follows the window: a settled canvas size becomes the guest's screen size. ESXi's
    /// own console protocol doesn't carry this (checked live on 8.0.2 / 8.0.3), so the request
    /// goes through VMware Tools instead: VMwareResolutionSet.exe on Windows, xrandr on Linux,
    /// run as the saved guest user in the desktop session (owner, 3 Oct 2026). The protocol
    /// request is still sent first for a host that does support it.
    private func viewportChanged(_ size: CGSize) {
        lastViewport = size
        resizeTask?.cancel()
        guard zoom == .fit, model.consoleFollowsWindow, vm.tools.isRunning else { return }
        resizeTask = Task {
            // Wait for the layout to settle (the canvas is laid out small first, then grows to
            // the window): the size must hold for 2 s and be a real console size before it is
            // sent (owner's guest ended up at 638×370, 3 Oct 2026).
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, state == .connected, let session, let settled = lastViewport, settled == size else { return }
            let w = Int(size.width.rounded(.down)) & ~7, h = Int(size.height.rounded(.down)) & ~7
            guard w >= 1024, h >= 640 else {
                Self.log.notice("resize skipped: viewport \(w)×\(h) is too small to be the window")
                return
            }
            if let f = frame, abs(f.width - w) <= 16, abs(f.height - h) <= 16 { return }
            Self.log.notice("resize request \(w)×\(h) for \(vm.name, privacy: .public) (guest is \(frame?.width ?? 0)×\(frame?.height ?? 0))")
            session.requestDesktopSize(width: w, height: h)
            guard let login = host.guestLogin(vm: vm) else { return }
            var interactive = login
            interactive.interactive = true
            do {
                let s = try host.sessionForGuest()
                switch vm.guestFamily {
                case .windows:
                    // 0 = primary display, 1 display in the list, then x y width height.
                    _ = try await s.startProgram(vm: vm.ref, login: interactive,
                                                 program: "C:\\Program Files\\VMware\\VMware Tools\\VMwareResolutionSet.exe",
                                                 arguments: "0 1 , 0 0 \(w) \(h)")
                case .linux, .other:
                    // The X authority file sits at the guest user's home, wherever that is,
                    // and the runtime dir at their uid: resolved in the guest, not assumed.
                    _ = try await s.startProgram(vm: vm.ref, login: interactive, program: "/bin/sh",
                                                 arguments: "-c 'DISPLAY=\"${DISPLAY:-:0}\"; export DISPLAY; XAUTHORITY=\"${XAUTHORITY:-$HOME/.Xauthority}\"; export XAUTHORITY; XDG_RUNTIME_DIR=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}\"; export XDG_RUNTIME_DIR; xrandr -s \(w)x\(h) 2>/dev/null || xrandr --fb \(w)x\(h) 2>/dev/null'")
                case .darwin:
                    break
                }
            } catch {
                note = "Couldn't ask the guest to resize: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    /// Puts the Mac clipboard on the guest's clipboard through Tools (needs a desktop session).
    /// With no guest login saved, asks for one and pastes once it is saved.
    private func pasteToGuest() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            note = "The Mac's clipboard holds no text."
            return
        }
        guard let login = host.guestLogin(vm: vm) else {
            pasteAfterLogin = true
            showingGuestLogin = true
            return
        }
        error = nil
        note = "Copying to the guest's clipboard…"
        Task {
            do {
                let s = try host.sessionForGuest()
                try await s.paste(text, vm: vm.ref, login: login, family: vm.guestFamily)
                note = "The guest's clipboard now holds \(text.count) characters."
            } catch {
                note = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// How the guest screen is sized: aspect-fitted to the canvas, or 1 framebuffer pixel = 1 point
/// inside a scroll view.
enum ConsoleZoom: CaseIterable, Hashable {
    case fit, actual

    var word: String {
        switch self {
        case .fit: "Fit"
        case .actual: "Actual size"
        }
    }

    /// The choice for this run of the app (the view is rebuilt whenever the tab changes).
    @MainActor static var remembered = ConsoleZoom.fit
}

/// The NSView that draws the framebuffer and turns mouse and keyboard events into RFB input.
/// Click to capture the keyboard; ⌘⇧Esc releases.
struct ConsoleCanvas: NSViewRepresentable {
    let frame: MKSFramebuffer
    let cursor: MKSCursor?
    let zoom: ConsoleZoom
    @Binding var captured: Bool
    let session: MKSSession?
    /// False while rewound: nothing goes to the guest.
    var inputEnabled = true
    /// ⌘V / ⌘C while captured: the view decides how the clipboards meet (Tools or typing).
    var onPaste: () -> Void = {}
    var onCopy: () -> Void = {}
    /// The canvas size in points, after every layout (Fit mode asks the guest to follow it).
    var onViewportSize: (CGSize) -> Void = { _ in }

    func makeNSView(context: Context) -> ConsoleHostView {
        let view = ConsoleHostView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ConsoleHostView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ConsoleHostView) {
        view.canvas.capturedBinding = $captured
        view.canvas.update(frame: frame, session: session)
        view.canvas.update(cursor: cursor)
        view.canvas.inputEnabled = inputEnabled
        view.canvas.onPasteShortcut = onPaste
        view.canvas.onCopyShortcut = onCopy
        view.onViewportSize = onViewportSize
        view.update(zoom: zoom)
    }
}

/// The scroll view around the canvas. In Fit the document is the viewport (nothing to scroll,
/// no scrollers); in Actual size it is the framebuffer at 1 px = 1 pt, or the viewport when the
/// framebuffer is smaller (the picture sits centred), with thin overlay scrollers.
final class ConsoleHostView: NSView {
    let canvas = ConsoleNSView()
    private let scrollView = NSScrollView()
    private var zoom = ConsoleZoom.fit

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)
        canvas.onFrameSizeChange = { [weak self] in self?.sizeDocument() }
        applyGroundColour()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    func update(zoom: ConsoleZoom) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
        canvas.zoom = zoom
        let scrolls = zoom == .actual
        scrollView.hasVerticalScroller = scrolls
        scrollView.hasHorizontalScroller = scrolls
        sizeDocument()
    }

    var onViewportSize: ((CGSize) -> Void)?

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        sizeDocument()
        let size = scrollView.contentSize
        if size != lastReportedViewport, size.width > 0, size.height > 0 {
            lastReportedViewport = size
            onViewportSize?(size)
        }
    }
    private var lastReportedViewport = CGSize.zero

    private func sizeDocument() {
        let viewport = scrollView.contentSize
        var size = viewport
        if zoom == .actual, let f = canvas.framebufferSize {
            size = CGSize(width: max(viewport.width, f.width), height: max(viewport.height, f.height))
        }
        if canvas.frame.size != size {
            canvas.frame = CGRect(origin: .zero, size: size)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGroundColour()
    }

    private func applyGroundColour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(Theme.background).cgColor
        }
    }
}

/// Layer-backed; aspect-fits the guest screen and maps pointer events into its pixels.
final class ConsoleNSView: NSView {
    var capturedBinding: Binding<Bool>?
    var session: MKSSession?
    /// False while the view shows history: input is dropped (and held keys released).
    var inputEnabled = true {
        didSet { if !inputEnabled, oldValue { liftModifiers(); if !buttons.isEmpty { buttons = [] } } }
    }
    /// ⌘V / ⌘C while captured (owner, 3 Oct 2026: the clipboards must really meet).
    var onPasteShortcut: (() -> Void)?
    var onCopyShortcut: (() -> Void)?
    var zoom = ConsoleZoom.fit { didSet { needsLayout = true } }
    /// The host resizes the document when the guest screen changes size.
    var onFrameSizeChange: (() -> Void)?
    var framebufferSize: CGSize? {
        guard let f = drawnFrame, f.width > 0, f.height > 0 else { return nil }
        return CGSize(width: f.width, height: f.height)
    }
    private var drawnFrame: MKSFramebuffer?
    private let contentLayer = CALayer()
    private var buttons: MKSButtons = []
    private var trackedLocation = CGPoint.zero
    /// Trackpad scrolling in points not yet turned into wheel ticks.
    private var scrollRemainder: CGFloat = 0
    /// Modifier keysyms reported down to the guest, so releases match presses.
    private var heldModifiers: Set<UInt32> = []
    /// The keysym sent on key-down per key code; key-up reuses it instead of recomputing.
    private var heldKeys: [UInt16: UInt32] = [:]
    /// ⌘ pressed but not yet reported: ⌘C/V/X/A/Z become Ctrl+letter, so Super goes down only
    /// when another key is typed, and a lone ⌘ tap becomes a Windows-key tap on release.
    private var pendingSuper: UInt32?
    /// The guest's cursor (VMware cursor extension), or the arrow until it says.
    private var guestCursor: NSCursor = .arrow
    private var cursorImage: CGImage?
    private var cursorHidden = false
    private var mouseInside = false

    /// A 1 × 1 clear image: the guest hid its cursor, so nothing is drawn over the canvas.
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(contentLayer)
        contentLayer.contentsGravity = .resizeAspect
        applyGroundColour()
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no nib") }

    override var acceptsFirstResponder: Bool { true }

    private var isCaptured: Bool { capturedBinding?.wrappedValue == true }

    func update(frame: MKSFramebuffer, session: MKSSession?) {
        let sessionChanged = session !== self.session
        let sizeChanged = frame.width != drawnFrame?.width || frame.height != drawnFrame?.height
        self.session = session
        self.drawnFrame = frame
        if let image = frame.image {
            contentLayer.contents = image
        }
        if sizeChanged {
            needsLayout = true
            onFrameSizeChange?()
        }
        if sessionChanged {
            heldModifiers.removeAll()
            heldKeys.removeAll()
            pendingSuper = nil
            buttons = []
            if isCaptured { capturedBinding?.wrappedValue = false }
        }
    }

    func update(cursor: MKSCursor?) {
        let hidden = cursor != nil && cursor?.image == nil
        guard cursor?.image !== cursorImage || hidden != cursorHidden else { return }
        cursorImage = cursor?.image
        cursorHidden = hidden
        if let cursor {
            if let image = cursor.image {
                let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                guestCursor = NSCursor(image: nsImage, hotSpot: cursor.hotspot)
            } else {
                // The guest shows no cursor (a text console, a BIOS): hide the Mac's too, so no
                // arrow floats over a screen that can't use it (owner, 3 Oct 2026).
                guestCursor = Self.hiddenCursor
            }
        } else {
            guestCursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
        if mouseInside { guestCursor.set() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = fittedRect
        contentLayer.frame = rect.isEmpty ? bounds : rect
        CATransaction.commit()
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGroundColour()
    }

    /// The ground around the aspect-fitted screen is the page colour, in the current appearance.
    private func applyGroundColour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ground = NSColor(Theme.background).cgColor
            layer?.backgroundColor = ground
            contentLayer.backgroundColor = ground
        }
    }

    // MARK: Focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        } else if isCaptured {
            releaseCapture()
        }
    }

    @objc private func windowResignedKey(_ note: Notification) {
        if isCaptured { releaseCapture() }
    }

    override func resignFirstResponder() -> Bool {
        if isCaptured { releaseCapture() }
        return super.resignFirstResponder()
    }

    /// Sends up for every modifier the guest believes is held; the Mac's own state is left as
    /// is, so a later flagsChanged release is a no-op.
    private func liftModifiers() {
        for keysym in heldModifiers { session?.sendKey(keysym: keysym, down: false) }
        heldModifiers.removeAll()
    }

    /// Releasing the capture: whatever keys, modifiers and buttons are still reported down go up.
    private func releaseCapture() {
        for (_, keysym) in heldKeys { session?.sendKey(keysym: keysym, down: false) }
        heldKeys.removeAll()
        for keysym in heldModifiers { session?.sendKey(keysym: keysym, down: false) }
        heldModifiers.removeAll()
        pendingSuper = nil
        if !buttons.isEmpty {
            buttons = []
            session?.sendPointer(x: Int(trackedLocation.x), y: Int(trackedLocation.y), buttons: [])
        }
        capturedBinding?.wrappedValue = false
    }

    // MARK: Mouse

    override var isFlipped: Bool { true }

    /// Where the guest screen is drawn, in this view's (document) coordinates: aspect-fitted in
    /// Fit; at 1 px = 1 pt, centred when it is smaller than the viewport, in Actual size.
    private var fittedRect: CGRect {
        guard let f = drawnFrame, f.width > 0, f.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = zoom == .actual ? 1 : min(bounds.width / CGFloat(f.width), bounds.height / CGFloat(f.height))
        let size = CGSize(width: CGFloat(f.width) * scale, height: CGFloat(f.height) * scale)
        return CGRect(x: max(0, (bounds.width - size.width) / 2), y: max(0, (bounds.height - size.height) / 2),
                      width: size.width, height: size.height)
    }

    /// Actual size with more screen than viewport: the wheel scrolls the view, not the guest.
    private var scrollsTheView: Bool {
        guard zoom == .actual, let f = framebufferSize, let clip = enclosingScrollView?.contentView else { return false }
        return f.width > clip.bounds.width + 0.5 || f.height > clip.bounds.height + 0.5
    }

    /// The event's position in framebuffer pixels. Outside the fitted screen: nil for a plain
    /// move, the nearest edge pixel when `clamp` (drags and releases, so a button let go over
    /// the margin is not left pressed in the guest).
    private func pointerLocation(_ event: NSEvent, clamp: Bool) -> CGPoint? {
        let rect = fittedRect
        guard rect.width > 0, rect.height > 0, let f = drawnFrame else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard clamp || rect.contains(p) else { return nil }
        let x = Int((p.x - rect.minX) / rect.width * CGFloat(f.width))
        let y = Int((p.y - rect.minY) / rect.height * CGFloat(f.height))
        return CGPoint(x: min(max(0, x), f.width - 1), y: min(max(0, y), f.height - 1))
    }

    private func sendPointer(at point: CGPoint?) {
        guard inputEnabled else { return }
        guard let point else { return }
        trackedLocation = point
        session?.sendPointer(x: Int(point.x), y: Int(point.y), buttons: buttons)
    }

    /// Keys go to the guest while the pointer is over the screen; leaving it hands the keyboard
    /// back to the Mac (owner, 3 Oct 2026: no "click to capture").
    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        if session != nil, window?.isKeyWindow == true {
            window?.makeFirstResponder(self)
            capturedBinding?.wrappedValue = true
        }
    }
    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        if isCaptured { releaseCapture() }
    }
    override func cursorUpdate(with event: NSEvent) { guestCursor.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: guestCursor) }

    override func mouseMoved(with event: NSEvent) { sendPointer(at: pointerLocation(event, clamp: false)) }
    override func mouseDragged(with event: NSEvent) { sendPointer(at: pointerLocation(event, clamp: true)) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(at: pointerLocation(event, clamp: true)) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(at: pointerLocation(event, clamp: true)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturedBinding?.wrappedValue = true
        buttons.insert(.left)
        sendPointer(at: pointerLocation(event, clamp: true))
    }
    override func mouseUp(with event: NSEvent) {
        buttons.remove(.left)
        sendPointer(at: pointerLocation(event, clamp: true))
    }
    override func rightMouseDown(with event: NSEvent) {
        buttons.insert(.right)
        sendPointer(at: pointerLocation(event, clamp: true))
    }
    override func rightMouseUp(with event: NSEvent) {
        buttons.remove(.right)
        sendPointer(at: pointerLocation(event, clamp: true))
    }
    override func otherMouseDown(with event: NSEvent) {
        buttons.insert(.middle)
        sendPointer(at: pointerLocation(event, clamp: true))
    }
    override func otherMouseUp(with event: NSEvent) {
        buttons.remove(.middle)
        sendPointer(at: pointerLocation(event, clamp: true))
    }

    /// Wheel up (deltaY > 0) is RFB button 4 (mask 8), wheel down button 5 (mask 16). A
    /// trackpad reports points, not clicks: those accumulate and give one tick per ~10 pt.
    override func scrollWheel(with event: NSEvent) {
        if scrollsTheView { return super.scrollWheel(with: event) }
        guard inputEnabled else { return }
        guard let point = pointerLocation(event, clamp: false) else { return }
        var ticks: Int
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began { scrollRemainder = 0 }
            scrollRemainder += event.scrollingDeltaY
            ticks = Int((scrollRemainder / 10).rounded(.towardZero))
            scrollRemainder -= CGFloat(ticks) * 10
        } else {
            ticks = event.deltaY > 0 ? 1 : (event.deltaY < 0 ? -1 : 0)
        }
        ticks = max(-10, min(10, ticks))
        guard ticks != 0 else { return }
        let wheel: MKSButtons = ticks > 0 ? .scrollUp : .scrollDown
        trackedLocation = point
        for _ in 0..<abs(ticks) {
            session?.sendPointer(x: Int(point.x), y: Int(point.y), buttons: buttons.union(wheel))
            session?.sendPointer(x: Int(point.x), y: Int(point.y), buttons: buttons)
        }
    }

    // MARK: Keyboard (only while captured)

    /// While captured, ⌘ belongs to the guest as Ctrl (the Windows App convention): ⌘S saves,
    /// ⌘W closes a tab, ⌘V pastes through the clipboard. ⌘⇧Esc (release) and ⌘\ (sidebar) are
    /// the only shortcuts that stay on the Mac.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCaptured, inputEnabled, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, flags == [.command, .shift] {
            releaseCapture()
            return true
        }
        // Key codes, not characters: with a Thai (or any non-Latin) input source the characters
        // are Thai and ⌘V would go unrecognised (owner, 3 Oct 2026).
        if flags.contains(.command), event.keyCode == 0x2A {   // ⌘\
            return false
        }
        let shortcutLetters: [UInt16: Character] = [0x00: "a", 0x06: "z", 0x07: "x", 0x08: "c", 0x09: "v"]
        if flags == [.command], let letter = shortcutLetters[event.keyCode], !event.isARepeat {
            switch letter {
            case "v":
                Logger(subsystem: "Bestchaan.LabDock", category: "keys").notice("⌘V in console")
                // ⌘ is Control in the guest, and it is still down: lift every held modifier
                // first, or the pasted text arrives as Ctrl+letter shortcuts (owner's Notepad
                // got a "save changes?" dialog, 3 Oct 2026).
                liftModifiers()
                onPasteShortcut?()          // Mac clipboard → guest (Tools, or typed), then Ctrl+V
            case "c":
                Logger(subsystem: "Bestchaan.LabDock", category: "keys").notice("⌘C in console")
                sendControlCombo("c")       // the guest copies…
                onCopyShortcut?()           // …and the Mac picks it up through Tools
            default:
                sendControlCombo(letter)
            }
            return true
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isCaptured, inputEnabled else { return super.keyDown(with: event) }
        // ⌘⇧Esc releases the capture and stays local.
        if event.keyCode == 53, event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift) {
            releaseCapture()
            return
        }
        syncModifiers(with: event.modifierFlags)
        let keysym = heldKeys[event.keyCode]
            ?? MKSKeyMap.keysym(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        guard let keysym else { return }
        heldKeys[event.keyCode] = keysym
        session?.sendKey(keysym: keysym, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard isCaptured else { return super.keyUp(with: event) }
        // Only what went down goes up, and with the same keysym.
        guard let keysym = heldKeys.removeValue(forKey: event.keyCode) else { return }
        session?.sendKey(keysym: keysym, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCaptured, inputEnabled else { return super.flagsChanged(with: event) }
        let code = event.keyCode
        if code == 0x39 {
            // Caps Lock: macOS reports one event per tap (the flag toggles); the guest wants a press.
            session?.sendKey(keysym: MKSKeyMap.capsLock, down: true)
            session?.sendKey(keysym: MKSKeyMap.capsLock, down: false)
            return
        }
        guard let flag = modifierFlag(for: code), var keysym = MKSKeyMap.keysym(keyCode: code, characters: nil) else { return }
        // ⌘ is Ctrl in the guest (the Windows App convention; owner, 3 Oct 2026). The Windows key
        // is in Send keys….
        if flag == .command { keysym = code == 0x36 ? MKSKeyMap.controlRight : MKSKeyMap.control }
        let sides = modifierKeysyms(flag)
        let flagDown = event.modifierFlags.contains(flag)
        if heldModifiers.contains(keysym) {
            sendModifier(keysym, down: false)
            if !flagDown {
                for k in sides where heldModifiers.contains(k) { sendModifier(k, down: false) }
            }
        } else if flagDown {
            sendModifier(keysym, down: true)
        } else {
            for k in sides where heldModifiers.contains(k) { sendModifier(k, down: false) }
        }
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        default: nil
        }
    }

    /// Both sides of a modifier, left first.
    private func modifierKeysyms(_ flag: NSEvent.ModifierFlags) -> [UInt32] {
        switch flag {
        case .shift: [MKSKeyMap.shift, MKSKeyMap.shiftRight]
        case .control: [MKSKeyMap.control, MKSKeyMap.controlRight]
        case .option: [MKSKeyMap.alt, MKSKeyMap.altRight]
        case .command: [MKSKeyMap.control, MKSKeyMap.controlRight]   // ⌘ = Ctrl in the guest
        default: []
        }
    }

    private func sendModifier(_ keysym: UInt32, down: Bool) {
        if down {
            guard !heldModifiers.contains(keysym) else { return }
            heldModifiers.insert(keysym)
        } else {
            guard heldModifiers.remove(keysym) != nil else { return }
        }
        session?.sendKey(keysym: keysym, down: down)
    }

    /// Before a key is typed: modifiers the Mac holds that the guest has not seen (pressed before
    /// the capture, or the deferred ⌘) go down; ones the Mac let go of while we weren't looking
    /// go up. A modifier pressed while captured was already sent once by `flagsChanged`.
    private func syncModifiers(with flags: NSEvent.ModifierFlags) {
        let all: [NSEvent.ModifierFlags] = [.shift, .control, .option, .command]
        for flag in all {
            let sides = modifierKeysyms(flag)
            let wanted = flags.contains(flag)
            let held = sides.contains { heldModifiers.contains($0) }
            if wanted && !held {
                sendModifier(sides[0], down: true)
            } else if !wanted && held {
                // Ctrl and ⌘ share the guest's Control: let go only when neither is down.
                if sides[0] == MKSKeyMap.control, flags.contains(.control) || flags.contains(.command) { continue }
                for k in sides where heldModifiers.contains(k) { sendModifier(k, down: false) }
            }
        }
    }

    /// Ctrl+letter for the SwiftUI side (after a Tools paste landed).
    func pressControl(_ letter: Character) { sendControlCombo(letter) }

    /// Ctrl+letter in the guest; Control is pressed around the letter unless already held.
    private func sendControlCombo(_ letter: Character) {
        guard let keysym = MKSKeyMap.keysym(for: letter) else { return }
        let superHeld: [UInt32] = []
        let controlHeld = modifierKeysyms(.control).contains { heldModifiers.contains($0) }
        if !controlHeld { session?.sendKey(keysym: MKSKeyMap.control, down: true) }
        session?.sendKey(keysym: keysym, down: true)
        session?.sendKey(keysym: keysym, down: false)
        if !controlHeld { session?.sendKey(keysym: MKSKeyMap.control, down: false) }
        for k in superHeld { session?.sendKey(keysym: k, down: true) }
    }
}
