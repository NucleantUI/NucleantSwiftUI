//
//  Color.swift
//  NucleantSwiftUI
//

/// Light or dark appearance — `@Environment(\.colorScheme)`.
///
/// The window seeds it from the system appearance and follows it as it
/// changes; `.colorScheme(_:)` fixes it for a subtree. Dynamic colors
/// (`Color.dynamic(light:dark:)`, and the semantic ones — `.primary`,
/// `.background`, …) resolve against whichever scheme is in effect where
/// they are drawn.
public enum ColorScheme: Hashable, Sendable {
    case light
    case dark
}

/// An sRGB color with straight (non-premultiplied) alpha, stored as 0…1
/// components. ThorVG takes 8-bit channels, so the renderer scales on the way
/// out — see `Color.rgba8`.
///
/// A color may carry a second set of components for dark mode; the
/// `red`/`green`/`blue`/`alpha` here are then the light variant, and the
/// renderer resolves the right one when the color is drawn.
public struct Color: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    /// The dark-mode components, when this is a dynamic color.
    struct Components: Hashable, Sendable {
        var red: Double, green: Double, blue: Double, alpha: Double
    }
    var dark: Components?

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = opacity
    }

    /// A color with one appearance in light mode and another in dark.
    public static func dynamic(light: Color, dark: Color) -> Color {
        var color = light.resolved(for: .light)
        let darkColor = dark.resolved(for: .dark)
        color.dark = Components(red: darkColor.red, green: darkColor.green, blue: darkColor.blue, alpha: darkColor.alpha)
        return color
    }

    /// Whether this color differs between the two schemes.
    public var isDynamic: Bool { dark != nil }

    /// This color as drawn under `scheme` — a plain color, with no variant.
    public func resolved(for scheme: ColorScheme) -> Color {
        guard let dark else { return self }
        switch scheme {
        case .light:
            var copy = self
            copy.dark = nil
            return copy
        case .dark:
            return Color(red: dark.red, green: dark.green, blue: dark.blue, opacity: dark.alpha)
        }
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
        copy.dark?.alpha *= value
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

    // MARK: Semantic colors
    //
    // Dynamic: each has a light and a dark appearance, resolved where it is
    // drawn. Values follow the system palettes — near-black text on
    // near-white in light mode, the reverse in dark — so an app that only
    // uses these reads correctly under either.

    /// Default text/foreground color.
    public static let primary = Color.dynamic(light: Color(white: 0.1), dark: Color(white: 0.95))
    /// Captions, secondary labels.
    public static let secondary = Color.dynamic(light: Color(white: 0.45), dark: Color(white: 0.65))
    /// Placeholders, disabled text.
    public static let tertiary = Color.dynamic(light: Color(white: 0.65), dark: Color(white: 0.45))
    /// The window background. The dark value matches the engine's own
    /// clear color; the window sets the clear color to whichever applies.
    public static let background = Color.dynamic(light: Color(hex: 0xF2F2F7), dark: Color(red: 0.02, green: 0.02, blue: 0.04))
    /// Panels and cards over the background.
    public static let secondaryBackground = Color.dynamic(light: Color.white, dark: Color(hex: 0x1C1F26))
    /// Rows and controls over a panel.
    public static let tertiaryBackground = Color.dynamic(light: Color(hex: 0xE9E9EE), dark: Color(hex: 0x272B34))
    /// Hairlines between things.
    public static let separator = Color.dynamic(light: Color(white: 0, opacity: 0.12), dark: Color(white: 1, opacity: 0.10))
    /// A control's track or well — a fader's groove, a bar's empty part.
    public static let fill = Color.dynamic(light: Color(white: 0, opacity: 0.08), dark: Color(white: 1, opacity: 0.08))
}
