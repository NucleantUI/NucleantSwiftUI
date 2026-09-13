//
//  Font.swift
//  NucleantSwiftUI
//

public enum FontWeight: Int, Hashable, Sendable, Comparable {
    case ultraLight = 100
    case thin       = 200
    case light      = 300
    case regular    = 400
    case medium     = 500
    case semibold   = 600
    case bold       = 700
    case heavy      = 800
    case black      = 900

    public static func < (lhs: FontWeight, rhs: FontWeight) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The two weights the bundled font families actually ship — anything
    /// `semibold` or above resolves to the bold face.
    var isBoldFace: Bool { self >= .semibold }
}

public enum FontDesign: Hashable, Sendable {
    case `default`
    case serif
    case monospaced
    case rounded
}

public struct Font: Hashable, Sendable {
    /// The family this font asks for. `nil` means "whatever the design maps
    /// to" — resolved by `FontRegistry` at draw time.
    public var family: String?
    public var size: Double
    public var weight: FontWeight
    public var design: FontDesign
    public var isItalic: Bool

    public init(
        family: String? = nil,
        size: Double,
        weight: FontWeight = .regular,
        design: FontDesign = .default,
        isItalic: Bool = false
    ) {
        self.family = family
        self.size = size
        self.weight = weight
        self.design = design
        self.isItalic = isItalic
    }

    public func weight(_ weight: FontWeight) -> Font {
        var copy = self
        copy.weight = weight
        return copy
    }

    public func bold() -> Font { weight(.bold) }

    public func italic() -> Font {
        var copy = self
        copy.isItalic = true
        return copy
    }

    public func size(_ size: Double) -> Font {
        var copy = self
        copy.size = size
        return copy
    }
}

extension Font {
    public static func system(
        size: Double,
        weight: FontWeight = .regular,
        design: FontDesign = .default
    ) -> Font {
        Font(size: size, weight: weight, design: design)
    }

    public static func custom(_ family: String, size: Double) -> Font {
        Font(family: family, size: size)
    }

    public static let largeTitle = Font.system(size: 34, weight: .regular)
    public static let title      = Font.system(size: 28, weight: .regular)
    public static let title2     = Font.system(size: 22, weight: .regular)
    public static let title3     = Font.system(size: 20, weight: .regular)
    public static let headline   = Font.system(size: 17, weight: .semibold)
    public static let subheadline = Font.system(size: 15, weight: .regular)
    public static let body       = Font.system(size: 17, weight: .regular)
    public static let callout    = Font.system(size: 16, weight: .regular)
    public static let footnote   = Font.system(size: 13, weight: .regular)
    public static let caption    = Font.system(size: 12, weight: .regular)
    public static let monospaced = Font.system(size: 14, design: .monospaced)
}
