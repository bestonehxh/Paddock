import Foundation
import CoreGraphics
import Testing
@testable import MKSClient

/// A wire that plays back scripted server bytes and records what the client sends — the test
/// double for the WebSocket.
final class ScriptedWire: RFBWire, @unchecked Sendable {
    private let incoming: AsyncStream<Data>.Continuation
    private var incomingStream: AsyncStream<Data>!
    private let lock = NSLock()
    private(set) var received: [Data] = []
    private var alive = true

    init(handshake: [Data]) {
        var stream: AsyncStream<Data>!
        var continuation: AsyncStream<Data>.Continuation!
        (stream, continuation) = AsyncStream.makeStream()
        incomingStream = stream
        incoming = continuation
        for chunk in handshake { continuation.yield(chunk) }
    }

    /// More server bytes mid-session (updates, cut text…).
    func push(_ data: Data) { incoming.yield(data) }

    func readChunk() async throws -> Data {
        for await chunk in incomingStream {
            if !alive { break }
            return chunk
        }
        throw MKSError.transport("the test server closed the stream")
    }

    func write(_ data: Data) async throws {
        append(data)
    }

    // NSLock is off limits inside an async function; this keeps it in a sync one.
    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        received.append(data)
    }

    func close() {
        lock.lock(); closeCount += 1; lock.unlock()
        alive = false
        incoming.finish()
    }

    private var closeCount = 0
    /// True once the client closed the wire (disconnect, error, or the end of run()).
    var closeCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return closeCount > 0
    }

    /// Everything the client sent, as one blob for prefix checks.
    var sentBlob: Data {
        lock.lock(); defer { lock.unlock() }
        return received.reduce(Data(), +)
    }
}

/// The RFB 3.8 server handshake: version, security None, ServerInit with the given size.
enum ScriptedHandshake {
    static func serverInit(width: Int, height: Int, format: RFB.PixelFormat = .bgra32,
                           version: String = "RFB 003.008\n") -> [Data] {
        var init_ = Data()
        init_.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xFF)])
        init_.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xFF)])
        init_.append(contentsOf: format.encoded)
        init_.append(contentsOf: [0, 0, 0, 0])   // name length 0
        if version == "RFB 003.007\n" {
            // 3.7: no SecurityResult after type None.
            return [Data(version.utf8), Data([1, 1]), init_]
        }
        return [Data(version.utf8), Data([1, 1]), Data([0, 0, 0, 0]), init_]
    }
}

func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

/// A rectangle header: position, size, encoding.
func rectHeader(x: Int, y: Int, width: Int, height: Int, encoding: Int32) -> [UInt8] {
    u16(x) + u16(y) + u16(width) + u16(height) + u32(UInt32(bitPattern: encoding))
}

/// A FramebufferUpdate message carrying the given rectangles (header + payload each).
func update(rects: [[UInt8]]) -> Data {
    Data([0, 0] + u16(rects.count) + rects.flatMap { $0 })
}

func rawRect(x: Int, y: Int, width: Int, height: Int, pixels: [UInt8]) -> [UInt8] {
    rectHeader(x: x, y: y, width: width, height: height, encoding: 0) + pixels
}

func cutText(_ bytes: [UInt8]) -> Data {
    Data([3, 0, 0, 0] + u32(UInt32(bytes.count)) + bytes)
}

func solidPixels(count: Int, bgrx: [UInt8] = [0x00, 0x80, 0xFF, 0x01]) -> [UInt8] {
    (0..<count).flatMap { _ in bgrx }
}

/// A connection on a scripted wire with an unbounded stream and an iterator the test drives
/// phase by phase (the stream is single-consumer).
struct Scripted {
    let wire: ScriptedWire
    let connection: Connection
    var events: AsyncStream<MKSEvent>.AsyncIterator
    let task: Task<Void, Never>

    init(handshake: [Data]) {
        let wire = ScriptedWire(handshake: handshake)
        let (stream, continuation) = AsyncStream<MKSEvent>.makeStream(bufferingPolicy: .unbounded)
        self.wire = wire
        connection = Connection(continuation: continuation, boxes: Connection.Boxes(), makeWire: { wire })
        events = stream.makeAsyncIterator()
        let c = connection
        task = Task { await c.start() }
    }

    init(width: Int = 4, height: Int = 3) {
        self.init(handshake: ScriptedHandshake.serverInit(width: width, height: height))
    }

    /// Consumes events until one satisfies `match`; nil when the stream ended first.
    mutating func next(where match: (MKSEvent) -> Bool) async -> MKSEvent? {
        while let event = await events.next() {
            if match(event) { return event }
        }
        return nil
    }

    mutating func waitConnected() async -> Bool {
        await next(where: { if case .state(.connected) = $0 { return true }; return false }) != nil
    }

    mutating func nextFrame() async -> MKSFramebuffer? {
        if case .frame(let f, _)? = await next(where: { if case .frame = $0 { return true }; return false }) { return f }
        return nil
    }

    mutating func disconnectReason() async -> String?? {
        if case .state(.disconnected(let reason))? = await next(where: {
            if case .state(.disconnected) = $0 { return true }; return false }) { return .some(reason) }
        return nil
    }

    func finish() { task.cancel(); wire.close() }
}

/// Polls `condition` for up to two seconds (for writes the client makes after an event).
func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

func rgba(of image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return data
}

/// A raw framebuffer-update message with one rectangle.
func rawUpdate(x: Int, y: Int, width: Int, height: Int, pixels: [UInt8]) -> Data {
    var d = Data([0, 0, 0, 1])   // update, padding, 1 rect
    d.append(contentsOf: [UInt8(x >> 8), UInt8(x & 0xFF), UInt8(y >> 8), UInt8(y & 0xFF),
                          UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)])
    var encoding = UInt32(0).bigEndian
    withUnsafeBytes(of: &encoding) { d.append(contentsOf: $0) }
    d.append(contentsOf: pixels)
    return d
}

/// Full session against a scripted server: runs the connection until an event matches.
func openSession(width: Int = 4, height: Int = 3)
    -> (stream: AsyncStream<MKSEvent>, wire: ScriptedWire, task: Task<Void, Never>) {
    let wire = ScriptedWire(handshake: ScriptedHandshake.serverInit(width: width, height: height))
    let (stream, continuation) = AsyncStream<MKSEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    let connection = Connection(continuation: continuation, boxes: Connection.Boxes(), makeWire: { wire })
    let task = Task { await connection.start() }
    return (stream, wire, task)
}

// MARK: - Tests

@Test func handshakeOrder() async throws {
    let (stream, wire, task) = openSession()
    defer { task.cancel(); wire.close() }
    var connected = false
    for await event in stream {
        if case .state(.connected) = event { connected = true; break }
    }
    #expect(connected)
    let sent = wire.sentBlob
    #expect(sent.starts(with: Data("RFB 003.008\n".utf8)))
    #expect(sent.contains(Data(RFB.ClientMessage.setPixelFormat(.bgra32).bytes)))
    #expect(sent.contains(Data(RFB.ClientMessage.setEncodings(RFB.requestedEncodings).bytes)))
    #expect(sent.contains(Data(RFB.ClientMessage.updateRequest(incremental: false, x: 0, y: 0, width: 4, height: 3).bytes)))
}

@Test func frameDecoding() async throws {
    var pixels = [UInt8]()
    for _ in 0..<12 { pixels += [0x00, 0x80, 0xFF, 0x01] }
    let wire = ScriptedWire(handshake: ScriptedHandshake.serverInit(width: 4, height: 3))
    let (stream, continuation) = AsyncStream<MKSEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    let connection = Connection(continuation: continuation, boxes: Connection.Boxes(), makeWire: { wire })
    let task = Task { await connection.start() }
    defer { task.cancel(); wire.close() }

    var frame: MKSFramebuffer?
    var seen: [MKSEvent] = []
    for await event in stream {
        seen.append(event)
        // Push the update once we know we're connected and the client asked for the first frame.
        if wire.sentBlob.contains(Data(RFB.ClientMessage.updateRequest(incremental: false, x: 0, y: 0, width: 4, height: 3).bytes)) {
            wire.push(rawUpdate(x: 0, y: 0, width: 4, height: 3, pixels: pixels))
        }
        if case .frame(let f, _) = event { frame = f; break }
    }
    #expect(frame?.width == 4)
    #expect(frame?.height == 3)
    #expect(frame?.image != nil)
    // The framebuffer's B,G,R,X pixels draw into the RGBA context as R first.
    let image = try #require(frame?.image)
    let bytes = rgba(of: image)
    #expect(bytes[0] == 255)   // R
    #expect(bytes[1] == 128)   // G
    #expect(bytes[2] == 0)     // B
}

@Test func pixelFormatRoundTrip() {
    let f = RFB.PixelFormat.bgra32
    #expect(RFB.PixelFormat.parse(f.encoded) == f)
    #expect(f.bytesPerPixel == 4)
    let pixel = f.decodeBGRA([0x00, 0x80, 0xFF, 0x01][...])
    #expect(pixel?.0 == 0 && pixel?.1 == 128 && pixel?.2 == 255)
    #expect(f.isNativeBGRA)
}

@Test func rgb16Decode() {
    let f = RFB.PixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: false, trueColour: true,
                            redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
    // Red full on: 0xF800 little-endian → bytes 0x00, 0xF8.
    let pixel = f.decodeBGRA([0x00, 0xF8][...])
    #expect(pixel?.2 == 255 && pixel?.1 == 0 && pixel?.0 == 0)
}

@Test func framebufferRectangles() throws {
    var fb = FrameBuffer(width: 4, height: 4)
    var red = [UInt8](); var blue = [UInt8]()
    for _ in 0..<16 { red += [0, 0, 255, 255]; blue += [255, 0, 0, 255] }
    try fb.applyRaw(x: 0, y: 0, width: 4, height: 4, data: ArraySlice(red))
    try fb.applyRaw(x: 0, y: 0, width: 2, height: 2, data: ArraySlice(blue))
    #expect(fb.pixels[0] == 255 && fb.pixels[2] == 0)   // blue block over red: B then R
    try fb.applyCopyRect(x: 2, y: 2, width: 2, height: 2, srcX: 0, srcY: 0)
    let i = (2 * 4 + 2) * 4
    #expect(fb.pixels[i] == 255 && fb.pixels[i + 2] == 0)
    #expect(throws: Error.self) {
        try fb.applyRaw(x: 3, y: 3, width: 4, height: 4, data: ArraySlice(red))
    }
}

@Test func vmwareAlphaCursor() throws {
    // 1×1 alpha cursor (type 1): R 255, G 0, B 0, A 255.
    let data: [UInt8] = [1, 0, 255, 0, 0, 255]
    let cursor = try FrameBuffer.decodeVMwareCursor(x: 3, y: 5, width: 1, height: 1,
                                                    data: ArraySlice(data), format: .bgra32)
    #expect(cursor.hotspot == CGPoint(x: 3, y: 5))
    let image = try #require(cursor.image)
    let bytes = rgba(of: image)
    #expect(bytes == [255, 0, 0, 255])   // R, G, B, A as drawn into an RGBA context
}

@Test func vmwareClassicCursor() throws {
    // 2×1 classic cursor: pixel 0 opaque white (and black, xor white); pixel 1 transparent.
    var data: [UInt8] = [0, 0]
    data += [0, 0, 0, 0, 255, 255, 255, 255]      // and-mask pixels
    data += [255, 255, 255, 255, 0, 0, 0, 0]      // xor-mask pixels
    let cursor = try FrameBuffer.decodeVMwareCursor(x: 0, y: 0, width: 2, height: 1,
                                                    data: ArraySlice(data), format: .bgra32)
    let bytes = rgba(of: try #require(cursor.image))
    #expect(bytes[3] == 255 && bytes[0] == 255 && bytes[1] == 255 && bytes[2] == 255)
    #expect(bytes[7] == 0)
}

@Test func keymap() {
    #expect(MKSKeyMap.keysym(keyCode: 0x00, characters: "a") == 0x61)
    #expect(MKSKeyMap.keysym(keyCode: 0x12, characters: "1") == 0x31)
    #expect(MKSKeyMap.keysym(keyCode: 0x7B, characters: nil) == 0xFF51)   // left arrow
    #expect(MKSKeyMap.keysym(keyCode: 0x38, characters: nil) == MKSKeyMap.shift)
    #expect(MKSKeyMap.keysym(keyCode: 0x24, characters: "\r") == 0xFF0D)  // return
    #expect(MKSKeyMap.keysym(for: "x") == 0x78)
    #expect(MKSKeyMap.keysym(for: "\n") == 0xFF0D)
    #expect(MKSKeyMap.keysym(for: "ก") == nil)
    // XT codes through the QEMU extension: A = 0x1e, right arrow = 0xe0 0x4d → 0xcd.
    #expect(MKSKeyMap.xtKeyCode(usbHID: 0x04) == 0x1E)
    #expect(MKSKeyMap.xtKeyCode(usbHID: 0x4F) == 0xCD)
    #expect(MKSKeyMap.xtKeyCode(usbHID: 0x28) == 0x1C)
}

@Test func serverCutText() async throws {
    let wire = ScriptedWire(handshake: ScriptedHandshake.serverInit(width: 1, height: 1))
    let (stream, continuation) = AsyncStream<MKSEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
    let connection = Connection(continuation: continuation, boxes: Connection.Boxes(), makeWire: { wire })
    let task = Task { await connection.start() }
    defer { task.cancel(); wire.close() }

    var text: String?
    for await event in stream {
        // Push the cut text once the handshake finished (the client's version string arrived).
        if wire.sentBlob.contains(Data(RFB.ClientMessage.setEncodings(RFB.requestedEncodings).bytes)) {
            var d = Data([3, 0, 0, 0])   // ServerCutText, padding, length 5
            var length = UInt32(5).bigEndian
            withUnsafeBytes(of: &length) { d.append(contentsOf: $0) }
            d.append(contentsOf: Array("hello".utf8))
            wire.push(d)
        }
        if case .clipboard(let t) = event { text = t; break }
    }
    #expect(text == "hello")
}

// MARK: - Review fixes

/// Finding 1: CopyRect with the destination below the source must not smear the first row down.
@Test func copyRectDownward() throws {
    var fb = FrameBuffer(width: 2, height: 3)
    // Row r is filled with the value r + 1 in every byte.
    var rows = [UInt8]()
    for r in 0..<3 { rows += [UInt8](repeating: UInt8(r + 1), count: 8) }
    try fb.applyRaw(x: 0, y: 0, width: 2, height: 3, data: ArraySlice(rows))
    try fb.applyCopyRect(x: 0, y: 1, width: 2, height: 2, srcX: 0, srcY: 0)
    #expect(Array(fb.pixels[0..<8]) == [UInt8](repeating: 1, count: 8))
    #expect(Array(fb.pixels[8..<16]) == [UInt8](repeating: 1, count: 8))   // old row 0
    #expect(Array(fb.pixels[16..<24]) == [UInt8](repeating: 2, count: 8))  // old row 1, not row 0 twice
    // And upward still works.
    try fb.applyCopyRect(x: 0, y: 0, width: 2, height: 2, srcX: 0, srcY: 1)
    #expect(Array(fb.pixels[0..<8]) == [UInt8](repeating: 1, count: 8))
    #expect(Array(fb.pixels[8..<16]) == [UInt8](repeating: 2, count: 8))
}

/// Finding 2: disconnect() right after connect() closes the wire and ends the stream.
@Test func disconnectRightAfterConnect() async throws {
    // A server that never answers: the client sits in its first read. start() is awaited
    // directly so the session is started; whether run() has made its wire yet when stop()
    // lands is the race under test, and both orders must close the wire.
    let wire = ScriptedWire(handshake: [])
    let (stream, continuation) = AsyncStream<MKSEvent>.makeStream(bufferingPolicy: .unbounded)
    let connection = Connection(continuation: continuation, boxes: Connection.Boxes(), makeWire: { wire })
    await connection.start()
    await connection.stop()
    var states: [MKSState] = []
    for await event in stream {
        if case .state(let st) = event { states.append(st) }
    }
    #expect(wire.closeCalled)
    #expect(states.first == .connecting)
    #expect(states.last == .disconnected(reason: nil))
    // No other reason leaked ("the test server closed the stream" is what the read threw).
    #expect(!states.contains { if case .disconnected(let r) = $0 { return r != nil }; return false })
}

/// Finding 2, the other order: stop() landing before start() must still end the stream.
@Test func disconnectBeforeConnect() async throws {
    let wire = ScriptedWire(handshake: [])
    let (stream, continuation) = AsyncStream<MKSEvent>.makeStream(bufferingPolicy: .unbounded)
    let connection = Connection(continuation: continuation, boxes: Connection.Boxes(), makeWire: { wire })
    await connection.stop()
    await connection.start()
    var states: [MKSState] = []
    for await event in stream {
        if case .state(let st) = event { states.append(st) }
    }
    #expect(states == [.disconnected(reason: nil)])
    #expect(!wire.closeCalled)   // never opened
}

/// Finding 3: the server's empty -258 pseudo-rect is a capability flag, not a fatal encoding;
/// QEMU key events only go out once it arrived.
@Test func qemuExtendedKeyPseudoRect() async throws {
    var s = Scripted()
    defer { s.finish() }
    #expect(await s.waitConnected())
    // Before the flag: the HID path writes nothing.
    let before = s.wire.received.count
    await s.connection.write(.qemuKey(keysym: 0, xtCode: 0x1E, down: true))
    #expect(s.wire.received.count == before)

    let flag = rectHeader(x: 0, y: 0, width: 0, height: 0, encoding: -258)
    s.wire.push(update(rects: [flag, rawRect(x: 0, y: 0, width: 4, height: 3, pixels: solidPixels(count: 12))]))
    let frame = await s.nextFrame()
    #expect(frame?.width == 4)
    #expect(await s.connection.qemuKeysSupported)
    await s.connection.write(.qemuKey(keysym: 0, xtCode: 0x1E, down: true))
    #expect(s.wire.sentBlob.contains(Data(RFB.ClientMessage.qemuKey(keysym: 0, xtCode: 0x1E, down: true).bytes)))
    // Still connected: a cut text afterwards is delivered.
    s.wire.push(cutText(Array("ok".utf8)))
    let clip = await s.next(where: { if case .clipboard = $0 { return true }; return false })
    #expect(clip != nil)
}

/// Finding 4: SetColourMapEntries is pad(1) + first-colour(2) + count(2) + n × 6.
@Test func colourMapThenRaw() async throws {
    var s = Scripted()
    defer { s.finish() }
    #expect(await s.waitConnected())
    var map = Data([1, 0] + u16(0) + u16(1))
    map.append(contentsOf: [0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00])
    map.append(update(rects: [rawRect(x: 0, y: 0, width: 4, height: 3, pixels: solidPixels(count: 12))]))
    s.wire.push(map)
    let frame = await s.nextFrame()
    #expect(frame?.width == 4 && frame?.height == 3)
}

/// Finding 6 / 12: one update split across three chunks at odd offsets, then an update and a
/// ServerCutText in a single chunk.
@Test func splitAndCombinedChunks() async throws {
    var s = Scripted()
    defer { s.finish() }
    #expect(await s.waitConnected())
    let msg = update(rects: [rawRect(x: 0, y: 0, width: 4, height: 3, pixels: solidPixels(count: 12))])
    #expect(msg.count == 64)
    s.wire.push(msg[0..<5])        // inside the message header
    s.wire.push(msg[5..<17])       // through the rect header into the pixels
    s.wire.push(msg[17..<64])
    let first = await s.nextFrame()
    #expect(first != nil)
    let bytes = rgba(of: try #require(first?.image))
    #expect(bytes[0] == 255 && bytes[1] == 128 && bytes[2] == 0)

    var combined = update(rects: [rawRect(x: 1, y: 1, width: 2, height: 1, pixels: solidPixels(count: 2, bgrx: [1, 2, 3, 0]))])
    combined.append(cutText(Array("hello".utf8)))
    s.wire.push(combined)
    // The second frame is throttled (~30 fps), so it may follow the clipboard event.
    var sawFrame = false, text: String?
    while !(sawFrame && text != nil), let event = await s.events.next() {
        if case .frame = event { sawFrame = true }
        if case .clipboard(let t) = event { text = t }
    }
    #expect(sawFrame)
    #expect(text == "hello")
}

/// Finding 6: the reader hands out exact counts across chunk boundaries and compacts lazily.
@Test func readerIndexAndCompaction() async throws {
    let chunks = Locked<[Data]>([Data("abcdef".utf8), Data("ghij".utf8)])
    var reader = RFB.Reader(next: {
        var list = chunks.value
        guard !list.isEmpty else { throw MKSError.transport("end") }
        let d = list.removeFirst()
        chunks.value = list
        return d
    })
    #expect(try await reader.read(3) == Array("abc".utf8))
    #expect(reader.readIndex == 3 && reader.buffer.count == 6)      // not yet past half
    #expect(try await reader.read(2) == Array("de".utf8))
    #expect(reader.readIndex == 0 && reader.buffer.count == 1)      // compacted
    #expect(try await reader.read(3) == Array("fgh".utf8))          // spans the chunk boundary
    #expect(try await reader.readU16() == Int(UInt8(ascii: "i")) << 8 | Int(UInt8(ascii: "j")))
    #expect(reader.buffer.isEmpty && reader.readIndex == 0)
    await #expect(throws: MKSError.self) { try await reader.read(1) }
}

/// Finding 8: shifted characters are wrapped in Shift_L.
@Test func keymapShift() {
    let (events, skipped) = MKSKeyMap.keyEvents(for: "Hello!")
    #expect(skipped.isEmpty)
    typealias E = MKSKeyMap.KeyEvent
    let sh = MKSKeyMap.shift
    #expect(events == [
        E(keysym: sh, down: true), E(keysym: 0x48, down: true), E(keysym: 0x48, down: false), E(keysym: sh, down: false),
        E(keysym: 0x65, down: true), E(keysym: 0x65, down: false),
        E(keysym: 0x6C, down: true), E(keysym: 0x6C, down: false),
        E(keysym: 0x6C, down: true), E(keysym: 0x6C, down: false),
        E(keysym: 0x6F, down: true), E(keysym: 0x6F, down: false),
        E(keysym: sh, down: true), E(keysym: 0x21, down: true), E(keysym: 0x21, down: false), E(keysym: sh, down: false),
    ])
    #expect(MKSKeyMap.needsShift("A") && MKSKeyMap.needsShift("?") && MKSKeyMap.needsShift("~"))
    #expect(!MKSKeyMap.needsShift("a") && !MKSKeyMap.needsShift("1") && !MKSKeyMap.needsShift("é"))
    // Each letter is a down/up pair.
    let (ab, _) = MKSKeyMap.keyEvents(for: "ab")
    #expect(ab == [E(keysym: 0x61, down: true), E(keysym: 0x61, down: false),
                   E(keysym: 0x62, down: true), E(keysym: 0x62, down: false)])
    #expect(MKSKeyMap.keyEvents(for: "ก").skipped == ["ก"])
}

/// Finding 8 on the wire: the key messages leave in order with Shift around "H" and "!".
@Test func sendTextOnTheWire() async throws {
    var s = Scripted()
    defer { s.finish() }
    #expect(await s.waitConnected())
    let before = s.wire.received.count
    let (events, _) = MKSKeyMap.keyEvents(for: "H!")
    await s.connection.type(events: events)
    let sent = Array(s.wire.received.dropFirst(before))
    let expected = events.map { Data(RFB.ClientMessage.key(keysym: $0.keysym, down: $0.down).bytes) }
    #expect(sent == expected)
    #expect(sent.count == 8)
}

/// Finding 9: a 16-bpp true-colour ServerInit is accepted (we set our own format anyway).
@Test func pixelFormat16Accepted() async throws {
    let rgb16 = RFB.PixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: false, trueColour: true,
                                redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
    #expect(RFB.PixelFormat.parse(rgb16.encoded) == rgb16)
    var s = Scripted(handshake: ScriptedHandshake.serverInit(width: 2, height: 2, format: rgb16))
    defer { s.finish() }
    #expect(await s.waitConnected())
    // A colour map is still refused.
    var mapped = rgb16; mapped.trueColour = false
    var m = Scripted(handshake: ScriptedHandshake.serverInit(width: 2, height: 2, format: mapped))
    defer { m.finish() }
    let reason = await m.disconnectReason()
    #expect(reason == .some("The console wants something the app can't speak (a colour-mapped screen)"))
}

/// Finding 10: RFC 6143 cursor mask, 1 = opaque; the constants for the dormant encodings.
@Test func rfCursorMask() throws {
    // 2×1 cursor: pixel 0 red, pixel 1 green; mask 0b10000000 → pixel 0 drawn, pixel 1 clear.
    let data: [UInt8] = [0, 0, 255, 0,  0, 255, 0, 0,  0x80]
    let cursor = try FrameBuffer.decodeRFCursor(x: 1, y: 1, width: 2, height: 1, data: ArraySlice(data), format: .bgra32)
    let bytes = rgba(of: try #require(cursor.image))
    #expect(bytes[0] == 255 && bytes[3] == 255)
    #expect(bytes[7] == 0)
    #expect(RFB.Encoding.cursor.rawValue == -239)
    #expect(RFB.Encoding.pointerPosition.rawValue == -232)
    #expect(RFB.Encoding.cursorWithAlpha.rawValue == -314)
    #expect(!RFB.requestedEncodings.contains(.vmwDisplayModeChange))
    #expect(!RFB.requestedEncodings.contains(.cursor))
    #expect(!RFB.requestedEncodings.contains(.pointerPosition))
}

/// Finding 11: a 3.7 server gets 3.7 echoed back and no SecurityResult is awaited.
@Test func version37Echo() async throws {
    var s = Scripted(handshake: ScriptedHandshake.serverInit(width: 2, height: 2, version: "RFB 003.007\n"))
    defer { s.finish() }
    #expect(await s.waitConnected())
    #expect(s.wire.sentBlob.starts(with: Data("RFB 003.007\n".utf8)))
    // Older than 3.7 is refused with a sentence.
    var old = Scripted(handshake: [Data("RFB 003.003\n".utf8)])
    defer { old.finish() }
    #expect(await old.disconnectReason() == .some("The console wants something the app can't speak (RFB 3.3)"))
}

/// Finding 11: ServerCutText is Latin-1.
@Test func serverCutTextLatin1() async throws {
    var s = Scripted()
    defer { s.finish() }
    #expect(await s.waitConnected())
    s.wire.push(cutText([0xE9, 0x41]))
    guard case .clipboard(let text)? = await s.next(where: { if case .clipboard = $0 { return true }; return false }) else {
        Issue.record("no clipboard event"); return
    }
    #expect(text == "éA")
}

/// Finding 11 / 12: DesktopSize resizes the buffer, yields .resized, and the next request is a
/// full one for the new size.
@Test func desktopSizeRect() async throws {
    var s = Scripted(width: 4, height: 3)
    defer { s.finish() }
    #expect(await s.waitConnected())
    s.wire.push(update(rects: [rectHeader(x: 0, y: 0, width: 6, height: 2, encoding: -223)]))
    guard case .resized(let w, let h)? = await s.next(where: { if case .resized = $0 { return true }; return false }) else {
        Issue.record("no resize"); return
    }
    #expect(w == 6 && h == 2)
    let wire = s.wire
    let full = Data(RFB.ClientMessage.updateRequest(incremental: false, x: 0, y: 0, width: 6, height: 2).bytes)
    #expect(await eventually { wire.received.last == full })
    // The buffer is the new size: a full 6×2 raw rect fits and comes back as a 6×2 frame.
    s.wire.push(update(rects: [rawRect(x: 0, y: 0, width: 6, height: 2, pixels: solidPixels(count: 12))]))
    let frame = await s.nextFrame()
    #expect(frame?.width == 6 && frame?.height == 2)
    let incremental = Data(RFB.ClientMessage.updateRequest(incremental: true, x: 0, y: 0, width: 6, height: 2).bytes)
    #expect(await eventually { wire.received.last == incremental })
}

@Test func extendedDesktopSizeRect() async throws {
    var s = Scripted(width: 4, height: 3)
    defer { s.finish() }
    #expect(await s.waitConnected())
    // One screen: number-of-screens 1 + 3 pad + 16 bytes (id, x, y, w, h, flags).
    var payload: [UInt8] = [1, 0, 0, 0]
    payload += u32(1) + u16(0) + u16(0) + u16(8) + u16(5) + u32(0)
    s.wire.push(update(rects: [rectHeader(x: 0, y: 0, width: 8, height: 5, encoding: -308) + payload]))
    guard case .resized(let w, let h)? = await s.next(where: { if case .resized = $0 { return true }; return false }) else {
        Issue.record("no resize"); return
    }
    #expect(w == 8 && h == 5)
    let wire = s.wire
    let full = Data(RFB.ClientMessage.updateRequest(incremental: false, x: 0, y: 0, width: 8, height: 5).bytes)
    #expect(await eventually { wire.received.last == full })
    s.wire.push(update(rects: [rawRect(x: 0, y: 0, width: 8, height: 5, pixels: solidPixels(count: 40))]))
    let frame = await s.nextFrame()
    #expect(frame?.width == 8 && frame?.height == 5)
}

/// Finding 12: the security handshake's two refusal paths say what happened.
@Test func securityRefused() async throws {
    // Only VNC authentication on offer.
    var vnc = Scripted(handshake: [Data("RFB 003.008\n".utf8), Data([1, 2])])
    defer { vnc.finish() }
    #expect(await vnc.disconnectReason() == .some("The console wants something the app can't speak (security types 2)"))
    #expect(vnc.wire.closeCalled)

    // Zero types and a reason string.
    let reason = Array("ticket expired".utf8)
    var refused = Scripted(handshake: [Data("RFB 003.008\n".utf8), Data([0] + u32(UInt32(reason.count)) + reason)])
    defer { refused.finish() }
    #expect(await refused.disconnectReason() == .some("The console wants something the app can't speak (ticket expired)"))
}

/// Finding 5: a flood of cursor positions collapses to the latest point and never starves
/// the other events.
@Test func cursorPositionCoalesced() async throws {
    var s = Scripted()
    defer { s.finish() }
    #expect(await s.waitConnected())
    var rects: [[UInt8]] = []
    for i in 0..<200 { rects.append(rectHeader(x: i, y: i, width: 0, height: 0, encoding: Int32(bitPattern: 0x574d5666))) }
    s.wire.push(update(rects: rects))
    s.wire.push(cutText(Array("after".utf8)))
    var positions: [(Int, Int)] = []
    var text: String?
    while let event = await s.events.next() {
        if case .cursorPosition(let x, let y) = event { positions.append((x, y)) }
        if case .clipboard(let t) = event { text = t; break }
    }
    #expect(text == "after")
    #expect(positions.count < 200)
    // The latest point is the one that survives (either emitted at once or after the ~16 ms wait).
    let last = await s.next(where: { if case .cursorPosition = $0 { return true }; return false })
    let finalPoint: (Int, Int)? = {
        if case .cursorPosition(let x, let y)? = last { return (x, y) }
        return positions.last
    }()
    #expect(finalPoint?.0 == 199 && finalPoint?.1 == 199)
}
