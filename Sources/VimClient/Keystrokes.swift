import Foundation

/// USB HID usage codes (page 7) for a US keyboard, the form `PutUsbScanCodes` takes.
public enum HIDKey {
    public struct Stroke: Sendable, Hashable {
        public var code: Int
        public var shift: Bool
        public var control: Bool = false
        public var alt: Bool = false
        public var gui: Bool = false

        public init(code: Int, shift: Bool = false, control: Bool = false, alt: Bool = false, gui: Bool = false) {
            self.code = code
            self.shift = shift
            self.control = control
            self.alt = alt
            self.gui = gui
        }

        /// The value vim25 wants: usage code in the high 16 bits, page 7 in the low bits.
        public var usbHidCode: Int32 { Int32(code << 16 | 7) }
    }

    public static let enter = 0x28, escape = 0x29, backspace = 0x2A, tab = 0x2B, space = 0x2C
    public static let delete = 0x4C, leftControl = 0xE0, leftShift = 0xE1, leftAlt = 0xE2, leftGUI = 0xE3

    private static let plain: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[c] = 0x04 + i }
        for (i, c) in "1234567890".enumerated() { m[c] = 0x1E + i }
        m["\n"] = enter; m["\r"] = enter
        m[" "] = space; m["\t"] = tab
        m["-"] = 0x2D; m["="] = 0x2E; m["["] = 0x2F; m["]"] = 0x30; m["\\"] = 0x31
        m[";"] = 0x33; m["'"] = 0x34; m["`"] = 0x35; m[","] = 0x36; m["."] = 0x37; m["/"] = 0x38
        return m
    }()

    private static let shifted: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { m[c] = 0x04 + i }
        for (i, c) in "!@#$%^&*()".enumerated() { m[c] = 0x1E + i }
        m["_"] = 0x2D; m["+"] = 0x2E; m["{"] = 0x2F; m["}"] = 0x30; m["|"] = 0x31
        m[":"] = 0x33; m["\""] = 0x34; m["~"] = 0x35; m["<"] = 0x36; m[">"] = 0x37; m["?"] = 0x38
        return m
    }()

    /// Strokes for a character on a US layout, nil for anything the layout can't type.
    public static func stroke(for c: Character) -> Stroke? {
        if let code = plain[c] { return Stroke(code: code) }
        if let code = shifted[c] { return Stroke(code: code, shift: true) }
        return nil
    }

    /// Strokes for a string; `skipped` collects characters the layout can't type (Thai, emoji…).
    public static func strokes(for text: String, skipped: inout [Character]) -> [Stroke] {
        var out: [Stroke] = []
        var previousWasCR = false
        for c in text {
            if c == "\r\n" { out.append(Stroke(code: enter)); previousWasCR = false; continue }
            if c == "\n" && previousWasCR { previousWasCR = false; continue }
            previousWasCR = c == "\r"
            if let s = stroke(for: c) { out.append(s) } else { skipped.append(c) }
        }
        return out
    }

    /// Named keys for the console toolbar.
    public static let ctrlAltDel = Stroke(code: delete, control: true, alt: true)
}
