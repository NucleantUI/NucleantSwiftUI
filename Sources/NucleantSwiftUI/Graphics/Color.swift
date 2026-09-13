//
//  Color.swift
//  NucleantSwiftUI
//

/// An sRGB color with straight (non-premultiplied) alpha, stored as 0…1
/// components. ThorVG takes 8-bit channels, so the renderer scales on the way
/// out — see `Color.rgba8`.
public struct Color: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = opacity
    }

    /// White-point grey.
    public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    /// `0xRRGGBB`, with alpha given separately — the form hex literals in
    /// designs come in.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }

    public func opacity(_ value: Double) -> Color {
        var copy = self
        copy.alpha = alpha * value
        return copy
    }

    /// 8-bit channels in the order ThorVG's `set_fill_color(r:g:b:a:)` wants.
    public var rgba8: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        func channel(_ value: Double) -> UInt8 {
            UInt8(Swift.max(0, Swift.min(1, value)) * 255)
        }
        return (channel(red), channel(green), channel(blue), channel(alpha))
    }

    public var isClear: Bool { alpha <= 0 }
}

extension Color {
    public static let clear   = Color(red: 0, green: 0, blue: 0, opacity: 0)
    public static let black   = Color(white: 0)
    public static let white   = Color(white: 1)
    public static let gray    = Color(white: 0.5)
    public static let red     = Color(hex: 0xFF3B30)
    public static let orange  = Color(hex: 0xFF9500)
    public static let yellow  = Color(hex: 0xFFCC00)
    public static let green   = Color(hex: 0x34C759)
    public static let mint    = Color(hex: 0x00C7BE)
    public static let teal    = Color(hex: 0x30B0C7)
    public static let cyan    = Color(hex: 0x32ADE6)
    public static let blue    = Color(hex: 0x007AFF)
    public static let indigo  = Color(hex: 0x5856D6)
    public static let purple  = Color(hex: 0xAF52DE)
    public static let pink    = Color(hex: 0xFF2D55)
    public static let brown   = Color(hex: 0xA2845E)

    /// Default text/foreground color. A single value rather than a dynamic
    /// system color — there is no appearance service under this stack.
    public static let primary   = Color(white: 0.95)
    public static let secondary = Color(white: 0.65)
    /// Default window background, matching the engine's own clear color.
    public static let background = Color(red: 0.02, green: 0.02, blue: 0.04)
}
