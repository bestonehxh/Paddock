import Foundation
import os
import CoreGraphics
import CryptoKit
import Security

// MARK: - Public contract

/// Connection state of one console session.
public enum MKSState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnected(reason: String?)
}

/// One decoded framebuffer: the whole guest screen, B, G, R, X bytes as a `CGImage`, ready to draw.
public struct MKSFramebuffer: Sendable {
    public var width: Int
    public var height: Int
    public var image: CGImage?
    public init(width: Int, height: Int, image: CGImage?) {
        self.width = width; self.height = height; self.image = image
    }
}

/// Guest-drawn cursor (VMware cursor extension); a nil image hides the cursor.
public struct MKSCursor: Sendable {
    public var image: CGImage?
    public var hotspot: CGPoint
    public init(image: CGImage?, hotspot: CGPoint) { self.image = image; self.hotspot = hotspot }
}

public enum MKSEvent: Sendable {
    case state(MKSState)
    /// A new frame after one or more rectangles changed; `dirty` is in framebuffer pixels.
    case frame(MKSFramebuffer, dirty: CGRect)
    case cursor(MKSCursor)
    /// The guest moved its own cursor to this point (framebuffer pixels).
    case cursorPosition(x: Int, y: Int)
    case resized(width: Int, height: Int)
    /// Guest clipboard text (ServerCutText), when the server sends it.
    case clipboard(String)
    /// The server refused a size we asked for (1 prohibited, 2 out of resources, 3 invalid).
    case resizeRefused(status: Int)
}

/// Mouse buttons in RFB order.
public struct MKSButtons: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = MKSButtons(rawValue: 1)
    public static let middle = MKSButtons(rawValue: 2)
    public static let right = MKSButtons(rawValue: 4)
    public static let scrollUp = MKSButtons(rawValue: 8)
    public static let scrollDown = MKSButtons(rawValue: 16)
}

/// A WebMKS console: RFB over WebSocket to `wss://<host>:<port>/ticket/<ticket>` (the URL from
/// `VimSession.consoleTicket`). The session owns its socket and decoder; the view consumes
/// `events` and sends input. All methods are safe to call from any thread.
public final class MKSSession: Sendable {
    public let url: URL
    public let expectedThumbprint: String?

    /// - Parameters:
    ///   - url: the ticket URL (`wss://host:443/ticket/<ticket>`).
    ///   - expectedThumbprint: the host certificate SHA-1 thumbprint to accept (colon-separated
    ///     hex), or nil to accept whatever the host presents.
    public init(url: URL, expectedThumbprint: String?) {
        self.url = url
        self.expectedThumbprint = expectedThumbprint
        // Unbounded: a dropped `.state(.connected)` or `.clipboard` is worse than a short queue.
        // The two events that can flood (frames, cursor positions) are coalesced in the actor
        // (newest wins, ~30 and ~60 per second), and the view consumes before `connect()`.
        let (stream, continuation) = AsyncStream<MKSEvent>.makeStream(bufferingPolicy: .unbounded)
        eventStream = stream
        connection = Connection(continuation: continuation, boxes: stateBoxes,
                                makeWire: { WebSocketWire(url: url, expectedThumbprint: expectedThumbprint) })
    }

    /// Frames, state changes, cursor updates. One stream for the session's life: every access
    /// returns the same instance, so keep a single consumer (the console view).
    public var events: AsyncStream<MKSEvent> { eventStream }

    /// Opens the socket, runs the RFB handshake, requests the first full frame. No effect while
    /// already started; a session is single-shot (tickets are single-use).
    public func connect() {
        Self.log.notice("connect \(self.url.lastPathComponent.prefix(8), privacy: .public)")
        Task { await connection.start() }
    }

    public func disconnect() {
        Self.log.notice("disconnect \(self.url.lastPathComponent.prefix(8), privacy: .public)")
        Task { await connection.stop() }
    }

    /// The last frame, for a view that mounts after frames started flowing.
    public var framebuffer: MKSFramebuffer? { stateBoxes.frame.value }
    public var state: MKSState { stateBoxes.state.value }

    // MARK: Input

    /// Keyboard: X11 keysym (RFB KeyEvent). Use `MKSKeyMap` to translate macOS key codes.
    public func sendKey(keysym: UInt32, down: Bool) {
        // Diagnostics (owner's "Windows locks when I switch VMs", 3 Oct 2026): every key the
        // app sends, readable with `log show --predicate 'subsystem == "Bestchaan.Paddock"'`.
        Self.log.notice("key \(String(keysym, radix: 16), privacy: .public) \(down ? "down" : "up", privacy: .public)")
        Task { await connection.write(.key(keysym: keysym, down: down)) }
    }
    private static let log = Logger(subsystem: "Bestchaan.Paddock", category: "mks")
    /// Keyboard by USB HID usage, as an XT keycode through the QEMU extended key event — for
    /// keys with no keysym. Does nothing when the usage has no XT scancode, or while the server
    /// has not confirmed the extension (it answers SetEncodings with an empty -258 pseudo-rect).
    public func sendKey(usbHID: UInt32, down: Bool) {
        guard let xt = MKSKeyMap.xtKeyCode(usbHID: usbHID) else { return }
        Task { await connection.write(.qemuKey(keysym: 0, xtCode: xt, down: down)) }
    }
    /// Pointer position in framebuffer pixels and the buttons currently held.
    public func sendPointer(x: Int, y: Int, buttons: MKSButtons) {
        Task { await connection.write(.pointer(x: max(0, min(x, 65535)), y: max(0, min(y, 65535)), buttons: buttons.rawValue)) }
    }
    /// Types text as key presses (printable Latin-1 + Enter/Tab; uppercase and US shifted
    /// punctuation with Shift_L held); returns characters it could not type.
    public func sendText(_ text: String) -> [Character] {
        let (events, skipped) = MKSKeyMap.keyEvents(for: text)
        guard !events.isEmpty else { return skipped }
        Task { await connection.type(events: events) }
        return skipped
    }
    public func sendCtrlAltDel() {
        Self.log.notice("ctrl-alt-del")
        Task { await connection.ctrlAltDel() }
    }
    /// Ask for a full redraw.
    public func refresh() {
        Task { await connection.requestFullUpdate() }
    }

    /// Keeps the connection but stops asking the host for frames (a console kept alive while
    /// another VM is shown costs nothing then); `resume()` asks for a full redraw.
    public func pause() { Task { await connection.pause() } }
    public func resume() { Task { await connection.resume() } }

    /// What the server said it can do: VMware capability bits (bit 128 = resolution requests)
    /// and whether ExtendedDesktopSize was confirmed. For diagnostics and tests.
    public func capabilities() async -> (vmwCaps: UInt32, extendedDesktopSize: Bool) {
        await connection.capabilities()
    }

    /// Ask the guest to change its screen to this size (follows the window in Fit mode when the
    /// guest has Tools). Ignored when the server didn't offer ExtendedDesktopSize.
    public func requestDesktopSize(width: Int, height: Int) {
        Task { await connection.requestDesktopSize(width: width, height: height) }
    }

    // MARK: Internals

    private let connection: Connection
    private let eventStream: AsyncStream<MKSEvent>
    /// The last frame / state, readable synchronously from the view: the connection actor
    /// publishes into these locked boxes.
    private let stateBoxes = Connection.Boxes()
}

// MARK: - Wire

/// The byte stream `Connection` runs RFB over. One chunk = one WebSocket message.
protocol RFBWire: Sendable {
    func readChunk() async throws -> Data
    func write(_ data: Data) async throws
    func close()
    /// Why the wire failed, as a sentence, when it knows better than the thrown error does
    /// (a certificate that doesn't match the pin, a ping that went unanswered). Nil otherwise.
    var failureReason: String? { get }
}

extension RFBWire {
    var failureReason: String? { nil }
}

/// `URLSessionWebSocketTask` on the ticket URL, subprotocol `binary`, TLS trust pinned to the
/// host's SHA-1 certificate thumbprint the same way VimClient's `SOAPTransport` pins it. Pings
/// every 20 s so a dropped LAN path surfaces as an error instead of silence.
final class WebSocketWire: RFBWire, @unchecked Sendable {
    // The lock below guards `alive`; everything else is immutable after init and the URLSession
    // calls back on its own queue.
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let trust: TrustDelegate
    private let alive = Locked<Bool>(true)
    /// Set when the wire closed itself (a failed ping); read back as the error's sentence.
    private let closeReason = Locked<String?>(nil)

    /// The certificate pin failure first, then a self-inflicted close (ping); nil when the
    /// wire has nothing to add to the error.
    var failureReason: String? { trust.pinFailure ?? closeReason.value }

    init(url: URL, expectedThumbprint: String?) {
        let trust = TrustDelegate(expectedSHA1: expectedThumbprint)
        self.trust = trust
        let config = URLSessionConfiguration.ephemeral
        // A console with nothing changing (a login prompt, a BIOS screen) sends nothing for
        // minutes; the idle timeout must not tear it down. The handshake has its own 15 s deadline
        // and the ping below notices a dead path (review, 3 Oct 2026).
        config.timeoutIntervalForRequest = 3600
        config.httpAdditionalHeaders = ["User-Agent": "Paddock/1.0"]
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = session.webSocketTask(with: request)
        // Foundation caps a WebSocket message at 1 MB by default; ESXi sends a whole Raw frame
        // (1920×1080×4 ≈ 8 MB) in one message and the receive fails with "Message too long".
        task.maximumMessageSize = 64 << 20
        task.resume()
        // No WebSocket pings: ESXi's WebMKS endpoint drops the connection about 10 s after a
        // ping frame (reproduced on 8.0.3, "Socket is not connected"), and the RFB stream has
        // its own traffic. A dead path surfaces as a failed receive() (live test, 3 Oct 2026).
    }

    func readChunk() async throws -> Data {
        guard alive.value else { throw MKSError.transport(closeReason.value ?? "the console is closed") }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            // After a self-inflicted close the receive fails with "cancelled"; the reason we
            // recorded is the one worth reading.
            if let reason = closeReason.value { throw MKSError.transport(reason) }
            throw error
        }
        switch message {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: throw MKSError.protocolError("an unexpected websocket message")
        }
    }

    func write(_ data: Data) async throws {
        guard alive.value else { throw MKSError.transport("the console is closed") }
        try await task.send(.data(data))
    }

    func close() {
        alive.value = false
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }

    /// SHA-1 thumbprint pinning, mirroring VimClient's `SOAPTransport`: accept whatever the host
    /// presents when there is no pin, otherwise require a match.
    final class TrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        // Mutable state is behind the lock; delegate callbacks arrive on a URLSession queue.
        private let lock = NSLock()
        private let expectedSHA1: String?
        private var observedSHA1Storage: String?
        private var pinFailureStorage: String?

        var observedSHA1: String? { lock.lock(); defer { lock.unlock() }; return observedSHA1Storage }
        /// A sentence when the presented certificate didn't match the pin: URLSession reports
        /// that as a plain "cancelled", which tells the user nothing.
        var pinFailure: String? { lock.lock(); defer { lock.unlock() }; return pinFailureStorage }

        init(expectedSHA1: String?) {
            self.expectedSHA1 = expectedSHA1.map { $0.uppercased().filter { $0.isHexDigit } }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else { return (.cancelAuthenticationChallenge, nil) }
            let der = SecCertificateCopyData(leaf) as Data
            let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
            // The lock verdict runs synchronously (NSLock is off limits in async contexts).
            return evaluate(sha1: sha1, trust: trust)
        }

        private func evaluate(sha1: String, trust: SecTrust) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            lock.lock(); defer { lock.unlock() }
            observedSHA1Storage = sha1
            guard let expected = expectedSHA1 else { return (.useCredential, URLCredential(trust: trust)) }
            let observed = sha1.uppercased().filter({ $0.isHexDigit })
            guard observed == expected else {
                pinFailureStorage = "The host's certificate (SHA-1 \(sha1)) doesn't match the saved thumbprint"
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
}

// MARK: - Connection

/// Owns the wire, the RFB state machine and the framebuffer. Everything the user does is a
/// message this actor serialises; results leave through the event stream and the locked boxes.
actor Connection {
    struct Boxes: Sendable {
        let state: Locked<MKSState>
        let frame: Locked<MKSFramebuffer?>
        init() {
            state = Locked(.idle)
            frame = Locked(nil)
        }
    }

    private let continuation: AsyncStream<MKSEvent>.Continuation
    private let boxes: Boxes
    private let makeWire: @Sendable () -> RFBWire

    private var wire: RFBWire?
    private var started = false
    private var stopped = false
    private var handshakeDone = false
    /// The server answered our -258 request with the pseudo-rect: QEMU extended key events
    /// may be sent. Until then the HID path does nothing (a server that doesn't speak the
    /// extension would treat message type 255 as garbage and drop the connection).
    private(set) var qemuKeysSupported = false
    /// The server sent an ExtendedDesktopSize rect: it accepts SetDesktopSize requests. The
    /// screen id comes from that rect (0 until one arrives).
    private(set) var desktopResizeSupported = false
    /// The server's VMware capability bits (type-127 ServerCaps); bit 128 = resolution requests.
    private(set) var vmwServerCaps: UInt32 = 0
    private var screenID: UInt32 = 0
    /// A DesktopSize / ExtendedDesktopSize rect arrived in the current update: the next
    /// request must be a full one, the old framebuffer content being gone.
    private var fullUpdateNeeded = false
    /// Background mode: no update requests go out until `resume()` (see the message loop).
    private var paused = false
    private var pausedPendingRequest = false

    func pause() { paused = true }

    func resume() async {
        guard paused else { return }
        paused = false
        if pausedPendingRequest {
            pausedPendingRequest = false
            await requestFullUpdate()
        }
    }
    private var framebuffer = FrameBuffer()
    private var lastCursorImage: CGImage?
    private var lastCursorHotspot = CGPoint.zero

    // Frame publishing: at most ~30 per second; the newest content wins.
    private var lastEmit = Date.distantPast
    private var pendingDirty: CGRect?
    private var emitTask: Task<Void, Never>?

    // Cursor position publishing: same idea, ~60 per second, only the latest point survives.
    private var lastCursorEmit = Date.distantPast
    private var pendingCursorPosition: (x: Int, y: Int)?
    private var cursorEmitTask: Task<Void, Never>?

    init(continuation: AsyncStream<MKSEvent>.Continuation, boxes: Boxes, makeWire: @escaping @Sendable () -> RFBWire) {
        self.continuation = continuation
        self.boxes = boxes
        self.makeWire = makeWire
    }

    // MARK: Lifecycle

    func start() {
        guard !started, !stopped else { return }
        started = true
        setState(.connecting)
        Task { await self.run() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        emitTask?.cancel()
        cursorEmitTask?.cancel()
        if let wire {
            // run() sees the read fail, notices `stopped` and finishes the stream.
            wire.close()
        } else if !started {
            // Never started (disconnect() won the race with connect()): nothing will run, so
            // end the session here. A started run() that hasn't made its wire yet checks
            // `stopped` right after it does.
            setState(.disconnected(reason: nil))
            continuation.finish()
        }
    }

    private func setState(_ s: MKSState) {
        boxes.state.value = s
        continuation.yield(.state(s))
    }

    private func run() async {
        let wire = makeWire()
        self.wire = wire
        defer {
            wire.close()
            emitTask?.cancel()
            cursorEmitTask?.cancel()
            continuation.finish()
        }
        // disconnect() may have landed between start() and here: don't leave a connected
        // socket nobody will ever read.
        if stopped {
            setState(.disconnected(reason: nil))
            return
        }
        // Reads stall until 15 s past start while the handshake is pending; frames afterwards
        // wait on the socket's own liveness (pings).
        let deadline = Locked<Date?>(Date().addingTimeInterval(15))
        var reader = RFB.Reader(next: { [wire, deadline] in
            let chunk = try await Self.read(wire: wire, deadline: deadline.value)
            if case .read(let data) = chunk { return data }
            throw MKSError.timeout
        })
        do {
            try await handshake(&reader, wire: wire)
            deadline.value = nil
            handshakeDone = true
            if stopped {
                setState(.disconnected(reason: nil))
                return
            }
            setState(.connected)
            try await messageLoop(&reader, wire: wire)
            setState(.disconnected(reason: nil))
        } catch is CancellationError {
            setState(.disconnected(reason: nil))
        } catch {
            // The user hung up: whatever the read threw afterwards is noise, not a reason.
            if stopped {
                setState(.disconnected(reason: nil))
                return
            }
            // The wire knows some failures better than the error does (a certificate that
            // doesn't match the pin surfaces from URLSession as a bare "cancelled").
            let reason = wire.failureReason
                ?? (error as? MKSError)?.errorDescription
                ?? error.localizedDescription
            setState(.disconnected(reason: reason))
        }
    }

    private enum TimedRead: Sendable { case read(Data), timedOut }

    /// One chunk, given up on at `deadline` (nil: no deadline). On timeout the wire is closed
    /// so the still-running `receive()` fails instead of lingering until the TCP timeout.
    private static func read(wire: RFBWire, deadline: Date?) async throws -> TimedRead {
        guard let deadline else { return .read(try await wire.readChunk()) }
        return try await withThrowingTaskGroup(of: TimedRead.self) { group in
            group.addTask { .read(try await wire.readChunk()) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return .read(Data()) }
                return .timedOut
            }
            let first = try await group.next() ?? .timedOut
            if case .timedOut = first { wire.close() }
            group.cancelAll()
            return first
        }
    }

    // MARK: Handshake

    private func handshake(_ reader: inout RFB.Reader, wire: RFBWire) async throws {
        let versionBytes = try await reader.read(12)
        guard let version = RFB.version(versionBytes), version.major == 3, version.minor >= 7 else {
            // "RFB 3.3" for a parseable but too old server; the raw bytes for anything else.
            let said = RFB.version(versionBytes).map { "RFB \($0.major).\($0.minor)" }
                ?? String(decoding: versionBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MKSError.unsupported(said)
        }
        // Echo 3.7 to a 3.7 server (no SecurityResult after type None); 3.8 for 3.8 and later.
        let negotiatedMinor = min(version.minor, 8)
        try await wire.write(Data(RFB.versionString(minor: negotiatedMinor).utf8))
        let typeCount = try await reader.readU8()
        if typeCount == 0 {
            let length = Int(try await reader.readU32())
            throw MKSError.unsupported(try await reader.readString(length: length))
        }
        let offered = try await reader.read(Int(typeCount))
        guard let chosen = RFB.chooseSecurityType(offered) else {
            throw MKSError.unsupported("security types \(offered.map { String(Int($0)) }.joined(separator: ", "))")
        }
        try await wire.write(Data([chosen]))
        if negotiatedMinor >= 8 {
            let result = try await reader.readU32()
            if result != 0 {
                let length = Int(try await reader.readU32())
                throw MKSError.unsupported(try await reader.readString(length: length))
            }
        }
        try await wire.write(Data([1]))   // ClientInit, shared
        let width = try await reader.readU16()
        let height = try await reader.readU16()
        let formatBytes = try await reader.read(16)
        guard let serverFormat = RFB.PixelFormat.parse(formatBytes), serverFormat.trueColour else {
            throw MKSError.unsupported("a colour-mapped screen")
        }
        let nameLength = Int(try await reader.readU32())
        _ = try await reader.readString(length: nameLength)
        framebuffer.resize(width: width, height: height)
        // Our pixel format before the first update request, as the protocol requires.
        try await wire.write(Data(RFB.ClientMessage.setPixelFormat(.bgra32).bytes))
        try await wire.write(Data(RFB.ClientMessage.setEncodings(RFB.requestedEncodings).bytes))
        try await wire.write(Data(RFB.ClientMessage.updateRequest(incremental: false, x: 0, y: 0, width: width, height: height).bytes))
    }

    // MARK: Message loop

    private func messageLoop(_ reader: inout RFB.Reader, wire: RFBWire) async throws {
        while !stopped, !Task.isCancelled {
            let type = try await reader.readU8()
            switch type {
            case 0:
                _ = try await reader.read(1)
                let count = try await reader.readU16()
                var dirty: CGRect?
                fullUpdateNeeded = false
                for _ in 0..<count {
                    if let rect = try await readRect(&reader) {
                        dirty = dirty.map { $0.union(rect) } ?? rect
                    }
                }
                if let dirty { publishFrame(dirty: dirty) }
                guard !stopped else { return }
                // A paused stream (console kept alive in the background) asks for nothing more:
                // the connection stays, the host sends no frames, the Mac decodes nothing.
                if paused { pausedPendingRequest = true; continue }
                // After a resize the whole (blank) buffer must be redrawn: ask for everything.
                try await wire.write(Data(RFB.ClientMessage.updateRequest(
                    incremental: !fullUpdateNeeded, x: 0, y: 0, width: framebuffer.width, height: framebuffer.height).bytes))
            case 1:
                // SetColourMapEntries: pad(1) + first-colour u16, then number-of-colours u16
                // and n × (r, g, b) u16s. Irrelevant to a true-colour client; consume and drop.
                _ = try await reader.read(3)
                let colours = try await reader.readU16()
                _ = try await reader.read(colours * 6)
            case 2:
                break   // Bell: nothing to ring in a quiet app
            case 3:
                _ = try await reader.read(3)
                let length = try await reader.readU32()
                if length & 0x8000_0000 != 0 {
                    throw MKSError.unsupported("the extended clipboard")
                }
                // ServerCutText is ISO 8859-1 by the spec.
                let text = try await reader.readLatin1(length: Int(length))
                continuation.yield(.clipboard(text))
            case 127:
                // VMware server message: sub-type, total length (header included), payload.
                let sub = try await reader.read(1)[0]
                let length = Int(try await reader.readU16())
                let payload = try await reader.read(max(0, length - 4))
                if sub == 0, payload.count >= 4 {
                    vmwServerCaps = UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])
                }
                // Heartbeat (4), reconnect token (6), audio (3/8), session close (7): skipped.
            default:
                throw MKSError.protocolError("server message \(type)")
            }
        }
    }

    /// Reads one rectangle (header, payload, pixel application); returns the dirty area when
    /// pixels changed, nil for pseudo-rectangles (already yielded directly).
    private func readRect(_ reader: inout RFB.Reader) async throws -> CGRect? {
        let x = try await reader.readU16()
        let y = try await reader.readU16()
        let w = try await reader.readU16()
        let h = try await reader.readU16()
        let rawEncoding = Int32(bitPattern: try await reader.readU32())
        let format = framebuffer.format
        switch RFB.Encoding(raw: rawEncoding) {
        case .raw:
            let data = try await reader.read(w * h * format.bytesPerPixel)
            try framebuffer.applyRaw(x: x, y: y, width: w, height: h, data: ArraySlice(data))
            return CGRect(x: x, y: y, width: w, height: h)
        case .copyRect:
            let srcX = try await reader.readU16()
            let srcY = try await reader.readU16()
            try framebuffer.applyCopyRect(x: x, y: y, width: w, height: h, srcX: srcX, srcY: srcY)
            return CGRect(x: x, y: y, width: w, height: h)
        case .desktopSize:
            framebuffer.resize(width: w, height: h)
            fullUpdateNeeded = true
            continuation.yield(.resized(width: w, height: h))
            return nil
        case .extendedDesktopSize:
            // x = reason (0 server, 1 this client, 2 another client), y = status for a request
            // we sent (0 ok, 1 prohibited, 2 out of resources, 3 invalid layout).
            let head = try await reader.read(4)
            let screens = try await reader.read(Int(head[0]) * 16)
            if screens.count >= 4 {
                screenID = UInt32(screens[0]) << 24 | UInt32(screens[1]) << 16 | UInt32(screens[2]) << 8 | UInt32(screens[3])
            }
            desktopResizeSupported = true
            if x == 1, y != 0 {
                continuation.yield(.resizeRefused(status: y))
                return nil
            }
            framebuffer.resize(width: w, height: h)
            fullUpdateNeeded = true
            continuation.yield(.resized(width: w, height: h))
            return nil
        case .vmwDefineCursor:
            let header = try await reader.read(2)
            var data = header
            if header[0] == 0 {
                data += try await reader.read(w * h * format.bytesPerPixel * 2)
            } else {
                data += try await reader.read(w * h * 4)
            }
            let cursor = try FrameBuffer.decodeVMwareCursor(x: x, y: y, width: w, height: h,
                                                            data: ArraySlice(data), format: format)
            rememberCursor(cursor)
            continuation.yield(.cursor(cursor))
            return nil
        case .vmwCursorState:
            let state = try await reader.readU16()
            continuation.yield(.cursor(MKSCursor(image: state & 1 != 0 ? lastCursorImage : nil,
                                                 hotspot: lastCursorHotspot)))
            return nil
        case .vmwCursorPosition, .pointerPosition:
            publishCursorPosition(x: x, y: y)
            return nil
        case .vmwKeyRepeat:
            _ = try await reader.read(10)
            return nil
        case .vmwLEDState:
            _ = try await reader.read(4)
            return nil
        case .vmwDisplayModeChange:
            // Not advertised (payload unconfirmed); kept so a server that sends it anyway
            // doesn't break the stream.
            let formatBytes = try await reader.read(16)
            framebuffer.resize(width: w, height: h, format: RFB.PixelFormat.parse(formatBytes))
            fullUpdateNeeded = true
            continuation.yield(.resized(width: w, height: h))
            return nil
        case .vmwVMState:
            _ = try await reader.read(2)
            return nil
        case .cursor:
            let data = try await reader.read(w * h * format.bytesPerPixel + (w + 7) / 8 * h)
            let cursor = try FrameBuffer.decodeRFCursor(x: x, y: y, width: w, height: h,
                                                        data: ArraySlice(data), format: format)
            rememberCursor(cursor)
            continuation.yield(.cursor(cursor))
            return nil
        case .cursorWithAlpha:
            let data = try await reader.read(w * h * 4)
            let cursor = try FrameBuffer.decodeRFCursorAlpha(x: x, y: y, width: w, height: h,
                                                             data: ArraySlice(data))
            rememberCursor(cursor)
            continuation.yield(.cursor(cursor))
            return nil
        case .qemuExtendedKey:
            // An empty pseudo-rect: the server's way of saying it accepts QEMU extended key
            // events. A capability flag, not pixels.
            qemuKeysSupported = true
            return nil
        case nil:
            throw MKSError.protocolError("encoding \(rawEncoding)")
        }
    }

    private func rememberCursor(_ cursor: MKSCursor) {
        lastCursorImage = cursor.image
        lastCursorHotspot = cursor.hotspot
    }

    // MARK: Frame publishing

    private func publishFrame(dirty: CGRect) {
        pendingDirty = pendingDirty.map { $0.union(dirty) } ?? dirty
        let sinceLast = Date().timeIntervalSince(lastEmit)
        if sinceLast >= 1.0 / 30 {
            emitPendingFrame()
        } else if emitTask == nil {
            emitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.0 / 30 - sinceLast))
                await self?.emitPendingFrame()
            }
        }
    }

    private func emitPendingFrame() {
        guard stopped == false, let dirty = pendingDirty else { return }
        pendingDirty = nil
        emitTask = nil
        lastEmit = Date()
        guard let image = framebuffer.makeImage() else { return }
        let fb = MKSFramebuffer(width: framebuffer.width, height: framebuffer.height, image: image)
        boxes.frame.value = fb
        continuation.yield(.frame(fb, dirty: dirty))
    }

    /// Guest cursor moves can arrive hundreds of times a second; only the latest point matters,
    /// so publish at most ~60 per second and never let them crowd out other events.
    private func publishCursorPosition(x: Int, y: Int) {
        pendingCursorPosition = (x, y)
        let sinceLast = Date().timeIntervalSince(lastCursorEmit)
        if sinceLast >= 1.0 / 60 {
            emitPendingCursorPosition()
        } else if cursorEmitTask == nil {
            cursorEmitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.0 / 60 - sinceLast))
                await self?.emitPendingCursorPosition()
            }
        }
    }

    private func emitPendingCursorPosition() {
        guard stopped == false, let point = pendingCursorPosition else { return }
        pendingCursorPosition = nil
        cursorEmitTask = nil
        lastCursorEmit = Date()
        continuation.yield(.cursorPosition(x: point.x, y: point.y))
    }

    // MARK: Input

    func write(_ message: RFB.ClientMessage) async {
        guard handshakeDone, !stopped, let wire else { return }
        // Without the server's -258 confirmation a type-255 message is garbage to it.
        if case .qemuKey = message, !qemuKeysSupported { return }
        try? await wire.write(Data(message.bytes))
    }

    /// Asks the guest to switch to this screen size (needs VMware Tools in the guest to take
    /// effect; the server answers with an ExtendedDesktopSize rect either way). Dropped when the
    /// server never confirmed the extension, or when the size is already current.
    func capabilities() -> (vmwCaps: UInt32, extendedDesktopSize: Bool) {
        (vmwServerCaps, desktopResizeSupported)
    }

    func requestDesktopSize(width: Int, height: Int) async {
        guard width >= 320, height >= 200 else { return }
        guard width != framebuffer.width || height != framebuffer.height else { return }
        if vmwServerCaps & 128 != 0 {
            await write(.vmwResolution(width: width, height: height))
        } else if desktopResizeSupported {
            await write(.setDesktopSize(width: width, height: height, screenID: screenID))
        }
    }

    func type(events: [MKSKeyMap.KeyEvent]) async {
        for event in events {
            await write(.key(keysym: event.keysym, down: event.down))
        }
    }

    func ctrlAltDel() async {
        for keysym in [MKSKeyMap.control, MKSKeyMap.alt] {
            await write(.key(keysym: keysym, down: true))
        }
        await write(.key(keysym: 0xFFFF, down: true))
        await write(.key(keysym: 0xFFFF, down: false))
        await write(.key(keysym: MKSKeyMap.alt, down: false))
        await write(.key(keysym: MKSKeyMap.control, down: false))
    }

    func requestFullUpdate() async {
        await write(.updateRequest(incremental: false, x: 0, y: 0, width: framebuffer.width, height: framebuffer.height))
    }
}

// MARK: - Locked box

/// A value behind an NSLock: the connection actor publishes, the session's synchronous
/// properties read. Everything stored is immutable once published (MKSState, MKSFramebuffer and
/// its CGImage), so sharing across threads is safe.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
