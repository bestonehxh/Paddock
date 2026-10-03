import Foundation

/// RFB 3.8 ("RFB proto") as ESXi's WebMKS speaks it: handshake bytes, pixel formats, client
/// messages and the server messages the app consumes. Pure data in and out — no sockets here —
/// so every branch is unit-testable against a recorded byte stream.
enum RFB {
    static let protocolVersion = "RFB 003.008\n"

    /// The 12-byte version string for a negotiated minor (3.7 is echoed back to a 3.7 server).
    static func versionString(minor: Int) -> String {
        "RFB 003.\(String(format: "%03d", minor))\n"
    }

    // MARK: Encoding numbers

    /// Frame encodings we ask for and know how to consume.
    enum Encoding: Int32, Sendable {
        case raw = 0
        case copyRect = 1
        case desktopSize = -223
        case qemuExtendedKey = -258
        case extendedDesktopSize = -308
        // Standard pseudo-encodings (RFC 6143 / rfbproto): consumed if a server sends them,
        // never advertised. -240 is X Cursor (not handled), so it is deliberately absent.
        case cursor = -239
        case pointerPosition = -232
        case cursorWithAlpha = -314
        case vmwDefineCursor = 0x574d5664   // "WMVd"
        case vmwCursorState = 0x574d5665    // "WMVe"
        case vmwCursorPosition = 0x574d5666  // "WMVf"
        case vmwKeyRepeat = 0x574d5667      // "WMVg"
        case vmwLEDState = 0x574d5668       // "WMVh"
        case vmwDisplayModeChange = 0x574d5669 // "WMVi"
        case vmwVMState = 0x574d566a        // "WMVj"

        init?(raw: Int32) { self.init(rawValue: raw) }
    }

    /// The encodings advertised in SetEncodings: raw and copyrect for pixels, desktop size
    /// changes, the VMware cursor set, and the QEMU extended key pseudo-encoding (which is how
    /// the server learns we may send keycodes, see `ClientMessage.extendedKey`). Tight and the
    /// standard RFB cursors are deliberately left out for now, as is DisplayModeChange
    /// (0x574d5669) whose payload is unconfirmed.
    static let requestedEncodings: [Encoding] = [
        .raw, .copyRect, .desktopSize, .extendedDesktopSize, .qemuExtendedKey,
        .vmwDefineCursor, .vmwCursorState, .vmwCursorPosition,
        // "WMVj" = VMWServerCaps in VMware's wmks.js: the server then sends a type-127 ServerCaps
        // message whose bit 128 means it takes resolution requests (read from the ESXi UI bundle).
        .vmwVMState,
    ]

    // MARK: Pixel format

    /// A PIXEL_FORMAT (16 bytes on the wire). Only true-colour formats are supported; a colour
    /// map is rejected with a sentence.
    struct PixelFormat: Sendable, Equatable {
        var bitsPerPixel: Int
        var depth: Int
        var bigEndian: Bool
        var trueColour: Bool
        var redMax: Int
        var greenMax: Int
        var blueMax: Int
        var redShift: Int
        var greenShift: Int
        var blueShift: Int

        /// What we ask the server for: 32 bpp, depth 24, little-endian, true colour, shifts
        /// 16/8/0 — bytes on the wire come as B, G, R, X, ready for a CGContext.
        static let bgra32 = PixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
                                        redMax: 255, greenMax: 255, blueMax: 255,
                                        redShift: 16, greenShift: 8, blueShift: 0)

        var bytesPerPixel: Int { max(1, bitsPerPixel / 8) }

        /// True when rectangles arrive exactly as the framebuffer stores them (B, G, R, X per
        /// pixel) and can be copied without conversion.
        var isNativeBGRA: Bool {
            self == .bgra32
        }

        static func parse(_ bytes: [UInt8]) -> PixelFormat? {
            let b = bytes
            guard b.count >= 16 else { return nil }
            func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
            // Any true-colour maxima are fine (16 bpp servers say 31/63/31): we set our own
            // format right after ServerInit, and `decodeBGRA` scales the others anyway.
            return PixelFormat(bitsPerPixel: Int(b[0]), depth: Int(b[1]), bigEndian: b[2] != 0,
                               trueColour: b[3] != 0, redMax: u16(4), greenMax: u16(6), blueMax: u16(8),
                               redShift: Int(b[10]), greenShift: Int(b[11]), blueShift: Int(b[12]))
        }

        /// The 16 bytes of a SetPixelFormat / ServerInit pixel format.
        var encoded: [UInt8] {
            var out = [UInt8]()
            out.append(UInt8(bitsPerPixel))
            out.append(UInt8(depth))
            out.append(bigEndian ? 1 : 0)
            out.append(trueColour ? 1 : 0)
            func append16(_ v: Int) { out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF)) }
            append16(redMax); append16(greenMax); append16(blueMax)
            out.append(UInt8(redShift)); out.append(UInt8(greenShift)); out.append(UInt8(blueShift))
            out.append(contentsOf: [0, 0, 0])
            return out
        }
    }

    // MARK: Client messages

    /// Client → server messages, rendered to bytes. All integers big-endian on the wire.
    enum ClientMessage {
        case setPixelFormat(PixelFormat)
        case setEncodings([Encoding])
        case updateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int)
        case key(keysym: UInt32, down: Bool)
        case qemuKey(keysym: UInt32, xtCode: UInt32, down: Bool)
        case pointer(x: Int, y: Int, buttons: UInt8)
        /// SetDesktopSize (type 251): ask the server to change the guest screen to one screen of
        /// this size. Only meaningful after the server confirmed ExtendedDesktopSize.
        case setDesktopSize(width: Int, height: Int, screenID: UInt32)
        /// VMware's own resolution request (client message 127, sub-type 5): what the ESXi web
        /// console sends for "fit guest to window". Needs Tools in the guest to take effect.
        case vmwResolution(width: Int, height: Int)

        var bytes: [UInt8] {
            switch self {
            case .vmwResolution(let w, let h):
                let hh = h & ~1   // wmks rounds the height to an even number
                return [127, 5, 0, 8, UInt8((w >> 8) & 0xFF), UInt8(w & 0xFF), UInt8((hh >> 8) & 0xFF), UInt8(hh & 0xFF)]
            case .setDesktopSize(let w, let h, let id):
                func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
                func u32(_ v: UInt32) -> [UInt8] {
                    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
                }
                return [251, 0] + u16(w) + u16(h) + [1, 0] + u32(id) + u16(0) + u16(0) + u16(w) + u16(h) + u32(0)
            case .setPixelFormat(let format):
                return [0, 0, 0, 0] + format.encoded
            case .setEncodings(let encodings):
                var out: [UInt8] = [2, 0, UInt8(encodings.count >> 8), UInt8(encodings.count & 0xFF)]
                for e in encodings {
                    let v = e.rawValue
                    out.append(UInt8((v >> 24) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF))
                    out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
                }
                return out
            case .updateRequest(let incremental, let x, let y, let w, let h):
                func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
                return [3, incremental ? 1 : 0] + u16(x) + u16(y) + u16(w) + u16(h)
            case .key(let keysym, let down):
                let v = keysym
                return [4, down ? 1 : 0, 0, 0,
                        UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            case .qemuKey(let keysym, let xt, let down):
                func u32(_ v: UInt32) -> [UInt8] {
                    [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
                }
                let d = UInt32(down ? 1 : 0)
                return [255, 0, UInt8((d >> 8) & 0xFF), UInt8(d & 0xFF)] + u32(keysym) + u32(xt)
            case .pointer(let x, let y, let buttons):
                func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
                return [5, buttons] + u16(x) + u16(y)
            }
        }
    }

    // MARK: Server messages

    /// One FramebufferUpdate rectangle after its 12-byte header was read; the payload has been
    /// consumed (and turned into data / a cursor / nothing for pseudos).
    enum RectOutcome: Sendable {
        /// Raw or copyrect pixels: x, y, w, h of the changed area.
        case pixels(x: Int, y: Int, width: Int, height: Int)
        case resized(width: Int, height: Int, format: PixelFormat?)
        case cursor(MKSCursor)
        case cursorVisible(Bool)
        case cursorAt(x: Int, y: Int)
        case ignored
    }

    enum ServerMessage: Sendable {
        case update([RectOutcome])
        case cutText(String)
        case bell
    }

    /// Reads exact byte counts out of a stream of chunks (WebSocket messages). `next` pulls the
    /// following chunk, blocking until one arrives.
    struct Reader {
        /// Bytes received but not yet consumed start at `readIndex`; the prefix before it is
        /// dead and compacted away lazily, so an 8 MB frame read in small pieces stays O(n).
        var buffer: [UInt8] = []
        var readIndex = 0
        let next: @Sendable () async throws -> Data

        init(next: @escaping @Sendable () async throws -> Data) {
            self.next = next
        }

        var available: Int { buffer.count - readIndex }

        mutating func read(_ count: Int) async throws -> [UInt8] {
            // A broken or hostile stream must not order a multi-gigabyte allocation on this
            // Mac: nothing the protocol legitimately carries is this large.
            guard count >= 0, count <= Self.maxRead else { throw MKSError.protocolError("a message asks for \(count) bytes") }
            while available < count {
                let chunk = try await next()
                buffer.append(contentsOf: chunk)
            }
            let out = Array(buffer[readIndex..<(readIndex + count)])
            readIndex += count
            compact()
            return out
        }

        /// Drops consumed bytes when the whole buffer is used up, or when more than half of it
        /// is dead — never on every read.
        private mutating func compact() {
            if readIndex == buffer.count {
                // A one-off giant message must not pin its capacity for the session's life.
                buffer.removeAll(keepingCapacity: buffer.capacity <= Self.keptCapacity)
                readIndex = 0
            } else if readIndex > buffer.count / 2 {
                buffer.removeFirst(readIndex)
                readIndex = 0
            }
        }

        /// 256 MiB, far above any real framebuffer update or clipboard text.
        static let maxRead = 268_435_456
        /// Capacity kept after a message is consumed (16 MiB: a 1920×1080 Raw frame fits).
        static let keptCapacity = 16 << 20

        mutating func readU8() async throws -> UInt8 { try await read(1)[0] }
        mutating func readU16() async throws -> Int {
            let b = try await read(2)
            return Int(b[0]) << 8 | Int(b[1])
        }
        mutating func readU32() async throws -> UInt32 {
            let b = try await read(4)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }

        /// UTF-8 text (the desktop name, failure reasons).
        mutating func readString(length: Int) async throws -> String {
            let b = try await read(length)
            return String(decoding: b, as: UTF8.self)
        }

        /// Latin-1 text: ServerCutText is ISO 8859-1 by the spec, not UTF-8.
        mutating func readLatin1(length: Int) async throws -> String {
            let b = try await read(length)
            return String(b.map { Character(Unicode.Scalar($0)) })
        }
    }
}

// MARK: - Handshake

extension RFB {
    /// Parses the server's 12-byte version string ("RFB 003.008\n" → 3, 8).
    static func version(_ bytes: [UInt8]) -> (major: Int, minor: Int)? {
        guard bytes.count == 12, bytes.prefix(3).elementsEqual("RFB".utf8), bytes[11] == 0x0A else { return nil }
        guard let major = Int(String(decoding: bytes[4...6], as: UTF8.self)),
              let minor = Int(String(decoding: bytes[8...10], as: UTF8.self)) else { return nil }
        return (major, minor)
    }

    /// The security types the server offers; empty means the server refused the connection
    /// (read the reason with `readSecurityFailure`).
    static func securityTypes(_ byte: UInt8) -> Int { Int(byte) }

    /// Picks a security type from the server's list. 1 = None is all the app needs; the WebMKS
    /// ticket in the URL is the authentication.
    static func chooseSecurityType(_ types: [UInt8]) -> UInt8? {
        types.first { $0 == 1 }
    }
}

// MARK: - Pixel conversion

extension RFB.PixelFormat {
    /// One pixel from wire bytes → (b, g, r, 255) as stored in the framebuffer. True-colour
    /// formats of 8/16/24/32 bpp, either endianness; max values other than 255 are scaled.
    func decodeBGRA(_ bytes: ArraySlice<UInt8>) -> (UInt8, UInt8, UInt8)? {
        let b = Array(bytes)
        guard trueColour, [1, 2, 3, 4].contains(bytesPerPixel), b.count >= bytesPerPixel else { return nil }
        var value: UInt32 = 0
        if bigEndian {
            for i in 0..<bytesPerPixel { value = value << 8 | UInt32(b[i]) }
        } else {
            for i in (0..<bytesPerPixel).reversed() { value = value << 8 | UInt32(b[i]) }
        }
        func channel(_ max: Int, _ shift: Int) -> UInt8 {
            let raw = (value >> UInt32(shift)) & UInt32(max)
            if max == 255 { return UInt8(raw) }
            return UInt8((Int(raw) * 255 + max / 2) / max)
        }
        return (channel(blueMax, blueShift), channel(greenMax, greenShift), channel(redMax, redShift))
    }
}
