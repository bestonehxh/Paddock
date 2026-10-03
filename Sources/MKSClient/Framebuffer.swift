import Foundation
import CoreGraphics

/// The guest screen: one B, G, R, X byte buffer plus the server's current pixel format. Owned by
/// the connection actor; only it mutates the buffer, and it hands out copies as CGImages.
struct FrameBuffer {
    var width: Int
    var height: Int
    /// B, G, R, X per pixel, row-major, `width * height * 4` bytes.
    var pixels: [UInt8]
    /// The format rectangles arrive in (starts as the one we requested).
    var format: RFB.PixelFormat

    init(width: Int = 0, height: Int = 0, format: RFB.PixelFormat = .bgra32) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
        self.format = format
    }

    var byteCount: Int { width * height * 4 }

    mutating func resize(width: Int, height: Int, format: RFB.PixelFormat? = nil) {
        self.width = width
        self.height = height
        if let format { self.format = format }
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    // MARK: Rectangles

    /// Raw-encoded rectangle data → pixels.
    mutating func applyRaw(x: Int, y: Int, width: Int, height: Int, data: ArraySlice<UInt8>) throws {
        try check(x: x, y: y, width: width, height: height)
        let bpp = format.bytesPerPixel
        guard data.count >= width * height * bpp else { throw MKSError.protocolError("a raw rectangle is short") }
        if format.isNativeBGRA {
            var src = data.startIndex
            for row in 0..<height {
                let dst = ((y + row) * self.width + x) * 4
                pixels.replaceSubrange(dst..<(dst + width * 4), with: data[src..<(src + width * 4)])
                src += width * 4
            }
        } else {
            var src = data.startIndex
            for row in 0..<height {
                var dst = ((y + row) * self.width + x) * 4
                for _ in 0..<width {
                    if let (b, g, r) = format.decodeBGRA(data[src..<(src + bpp)]) {
                        pixels[dst] = b; pixels[dst + 1] = g; pixels[dst + 2] = r; pixels[dst + 3] = 255
                    }
                    src += bpp
                    dst += 4
                }
            }
        }
    }

    /// CopyRect: the rectangle is a move of an existing region.
    mutating func applyCopyRect(x: Int, y: Int, width: Int, height: Int, srcX: Int, srcY: Int) throws {
        try check(x: x, y: y, width: width, height: height)
        guard srcX >= 0, srcY >= 0, srcX + width <= self.width, srcY + height <= self.height else {
            throw MKSError.protocolError("a copy rectangle points outside the screen")
        }
        // Source and destination may overlap in either direction (a window dragged down lands
        // the destination on rows not yet copied), so lift the whole source block out first
        // and only then write it back.
        let rowBytes = width * 4
        var block = [UInt8]()
        block.reserveCapacity(rowBytes * height)
        for row in 0..<height {
            let src = ((srcY + row) * self.width + srcX) * 4
            block.append(contentsOf: pixels[src..<(src + rowBytes)])
        }
        for row in 0..<height {
            let dst = ((y + row) * self.width + x) * 4
            pixels.replaceSubrange(dst..<(dst + rowBytes), with: block[(row * rowBytes)..<((row + 1) * rowBytes)])
        }
    }

    private func check(x: Int, y: Int, width: Int, height: Int) throws {
        guard x >= 0, y >= 0, width >= 0, height >= 0, x + width <= self.width, y + height <= self.height else {
            throw MKSError.protocolError("a rectangle doesn't fit the screen (\(width)×\(height) at \(x),\(y))")
        }
    }

    // MARK: Output

    /// A snapshot for drawing: the bytes are copied, so later rectangles can't change an image
    /// already handed to SwiftUI. Bitmap info matches the B, G, R, X memory order.
    func makeImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let data = Data(pixels) as NSData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Cursor decoding

extension FrameBuffer {
    /// A VMware cursor rectangle (`0x574d5664`): the hotspot is the rectangle position, the
    /// payload is a type byte plus either an AND/XOR pixel pair set (classic) or RGBA bytes
    /// (alpha). Cursor pixels arrive in the framebuffer's pixel format for classic cursors.
    static func decodeVMwareCursor(x: Int, y: Int, width: Int, height: Int,
                                   data: ArraySlice<UInt8>, format: RFB.PixelFormat) throws -> MKSCursor {
        guard width > 0, height > 0, width <= 512, height <= 512 else {
            throw MKSError.protocolError("an odd cursor size (\(width)×\(height))")
        }
        let bytes = Array(data)
        guard bytes.count >= 2 else { throw MKSError.protocolError("a cursor rectangle is short") }
        switch bytes[0] {
        case 0:
            let bpp = format.bytesPerPixel
            let count = width * height
            guard bytes.count >= 2 + count * bpp * 2 else {
                throw MKSError.protocolError("a classic cursor is short")
            }
            var rgba = [UInt8](repeating: 0, count: count * 4)
            // Arrays, not slices: the per-pixel reads below index from 0.
            let andMask = Array(bytes[2..<(2 + count * bpp)])
            let xorMask = Array(bytes[(2 + count * bpp)..<(2 + count * bpp * 2)])
            for i in 0..<count {
                guard let and = format.decodeBGRA(andMask[(i * bpp)..<((i + 1) * bpp)]),
                      let xor = format.decodeBGRA(xorMask[(i * bpp)..<((i + 1) * bpp)]) else { continue }
                // dst = (dst & and) ^ xor, over a white backdrop: opaque where and is black,
                // transparent where and is white and xor is black, inverted ≈ black.
                if and.0 == 0 && and.1 == 0 && and.2 == 0 {
                    rgba[i * 4] = xor.2; rgba[i * 4 + 1] = xor.1; rgba[i * 4 + 2] = xor.0; rgba[i * 4 + 3] = 255
                } else if xor.0 == 0 && xor.1 == 0 && xor.2 == 0 {
                    rgba[i * 4 + 3] = 0
                } else {
                    rgba[i * 4] = 0; rgba[i * 4 + 1] = 0; rgba[i * 4 + 2] = 0; rgba[i * 4 + 3] = 255
                }
            }
            return cursor(rgba: rgba, width: width, height: height, hotspotX: x, hotspotY: y)
        case 1:
            let count = width * height * 4
            guard bytes.count >= 2 + count else { throw MKSError.protocolError("an alpha cursor is short") }
            var rgba = [UInt8](bytes[2..<(2 + count)])
            // The wire order is R, G, B, A; the NSImage cursor wants a premultiplied
            // CGContext in B, G, R, A order — swap in place here.
            var i = 0
            while i < rgba.count {
                rgba.swapAt(i, i + 2)
                i += 4
            }
            return cursor(rgba: rgba, width: width, height: height, hotspotX: x, hotspotY: y)
        default:
            // A cursor flavour written after this code; nothing to draw but the shape is known.
            return MKSCursor(image: nil, hotspot: CGPoint(x: x, y: y))
        }
    }

    /// A standard RFB Cursor pseudo-encoding rectangle (-239), in case the server falls back to
    /// it: w×h pixels then a (w+7)/8 × h AND bitmask.
    static func decodeRFCursor(x: Int, y: Int, width: Int, height: Int,
                               data: ArraySlice<UInt8>, format: RFB.PixelFormat) throws -> MKSCursor {
        guard width > 0, height > 0, width <= 512, height <= 512 else {
            throw MKSError.protocolError("an odd cursor size (\(width)×\(height))")
        }
        let bytes = Array(data)
        let bpp = format.bytesPerPixel
        let maskStride = (width + 7) / 8
        guard bytes.count >= width * height * bpp + maskStride * height else {
            throw MKSError.protocolError("a cursor rectangle is short")
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for col in 0..<width {
                let i = row * width + col
                guard let (b, g, r) = format.decodeBGRA(bytes[(i * bpp)..<((i + 1) * bpp)]) else { continue }
                let maskByte = bytes[width * height * bpp + row * maskStride + col / 8]
                // RFC 6143 §7.8.1: a 1 bit means the pixel is drawn (opaque), 0 is see-through.
                let opaque = maskByte & (0x80 >> (col % 8)) != 0
                rgba[i * 4] = b; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = r
                rgba[i * 4 + 3] = opaque ? 255 : 0
            }
        }
        return cursor(rgba: rgba, width: width, height: height, hotspotX: x, hotspotY: y)
    }

    /// A standard RFB Cursor-with-alpha rectangle (-314): w×h RGBA pixels, no mask.
    static func decodeRFCursorAlpha(x: Int, y: Int, width: Int, height: Int,
                                    data: ArraySlice<UInt8>) throws -> MKSCursor {
        guard width > 0, height > 0, width <= 512, height <= 512 else {
            throw MKSError.protocolError("an odd cursor size (\(width)×\(height))")
        }
        var rgba = Array(data.prefix(width * height * 4))
        guard rgba.count == width * height * 4 else { throw MKSError.protocolError("an alpha cursor is short") }
        var i = 0
        while i < rgba.count {
            rgba.swapAt(i, i + 2)
            i += 4
        }
        return cursor(rgba: rgba, width: width, height: height, hotspotX: x, hotspotY: y)
    }

    private static func cursor(rgba: [UInt8], width: Int, height: Int, hotspotX: Int, hotspotY: Int) -> MKSCursor {
        let data = Data(rgba) as NSData
        let image = { () -> CGImage? in
            guard let provider = CGDataProvider(data: data) else { return nil }
            // The buffer holds B, G, R, A: little-endian ARGB, which CoreGraphics spells
            // premultipliedFirst + byteOrder32Little.
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                       | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }()
        return MKSCursor(image: image, hotspot: CGPoint(x: hotspotX, y: hotspotY))
    }
}

/// What went wrong in the console, as a sentence for the app to show.
public enum MKSError: Error, Sendable, LocalizedError {
    case transport(String)
    case protocolError(String)
    case unsupported(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .transport(let s): "Couldn't reach the console: \(s)"
        case .protocolError(let s): "The console stream broke: \(s)"
        case .unsupported(let s): "The console wants something the app can't speak (\(s))"
        case .timeout: "The console didn't answer in time"
        }
    }
}
