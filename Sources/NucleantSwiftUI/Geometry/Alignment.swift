//
//  Alignment.swift
//  NucleantSwiftUI
//

public enum HorizontalAlignment: Hashable, Sendable {
    case leading
    case center
    case trailing

    /// Where a `childWidth`-wide child starts inside a `containerWidth`-wide
    /// container under this alignment.
    func offset(childWidth: Double, in containerWidth: Double) -> Double {
        switch self {
        case .leading:  return 0
        case .center:   return (containerWidth - childWidth) / 2
        case .trailing: return containerWidth - childWidth
        }
    }
}

public enum VerticalAlignment: Hashable, Sendable {
    case top
    case center
    case bottom

    func offset(childHeight: Double, in containerHeight: Double) -> Double {
        switch self {
        case .top:    return 0
        case .center: return (containerHeight - childHeight) / 2
        case .bottom: return containerHeight - childHeight
        }
    }
}

public struct Alignment: Hashable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let topLeading     = Alignment(horizontal: .leading,  vertical: .top)
    public static let top            = Alignment(horizontal: .center,   vertical: .top)
    public static let topTrailing    = Alignment(horizontal: .trailing, vertical: .top)
    public static let leading        = Alignment(horizontal: .leading,  vertical: .center)
    public static let center         = Alignment(horizontal: .center,   vertical: .center)
    public static let trailing       = Alignment(horizontal: .trailing, vertical: .center)
    public static let bottomLeading  = Alignment(horizontal: .leading,  vertical: .bottom)
    public static let bottom         = Alignment(horizontal: .center,   vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)

    /// Place a `size`-sized child inside `rect` under this alignment.
    public func position(_ size: Size, in rect: Rect) -> Rect {
        Rect(
            x: rect.minX + horizontal.offset(childWidth: size.width, in: rect.width),
            y: rect.minY + vertical.offset(childHeight: size.height, in: rect.height),
            width: size.width,
            height: size.height
        )
    }
}

/// Alignment of text inside its own frame — distinct from `Alignment`, which
/// positions a whole view.
public enum TextAlignment: Hashable, Sendable {
    case leading
    case center
    case trailing
}
