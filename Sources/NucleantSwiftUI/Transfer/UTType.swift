//
//  UTType.swift
//  NucleantSwiftUI
//
//  The content-type tag a `TransferRepresentation` is labelled with. The same
//  shape as UniformTypeIdentifiers' `UTType` — the identifiers are Apple's
//  public ones — but a plain struct here, so a transfer type reads the same
//  on every platform the stack runs on and never pulls in a system framework.
//

/// A uniform type identifier — `public.json`, `public.utf8-plain-text`.
///
/// A type may conform to others (`json` is `text` is `data` is `item`), and
/// that is how a drop that asks for `.text` accepts a drag that offered
/// `.utf8PlainText`. Identity is the identifier alone.
public struct UTType: Hashable, Sendable, CustomStringConvertible {

    public let identifier: String

    /// The types this one is a kind of, nearest first.
    public let supertypes: [UTType]

    /// A type by identifier, conforming to nothing but itself.
    public init(_ identifier: String) {
        self.identifier = identifier
        self.supertypes = []
    }

    /// A type an app declares, conforming to `supertype` — `.data` unless
    /// said otherwise. `exportedAs:` and `importedAs:` mean the same thing
    /// here; both spellings exist so a declaration reads as it would with
    /// UniformTypeIdentifiers.
    public init(exportedAs identifier: String, conformingTo supertype: UTType = .data) {
        self.identifier = identifier
        self.supertypes = [supertype]
    }

    public init(importedAs identifier: String, conformingTo supertype: UTType = .data) {
        self.identifier = identifier
        self.supertypes = [supertype]
    }

    private init(_ identifier: String, conformingTo supertypes: [UTType]) {
        self.identifier = identifier
        self.supertypes = supertypes
    }

    /// True when this type *is* `other` or is a kind of it, however far up.
    public func conforms(to other: UTType) -> Bool {
        if identifier == other.identifier { return true }
        return supertypes.contains { $0.conforms(to: other) }
    }

    public static func == (lhs: UTType, rhs: UTType) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }

    public var description: String { identifier }

    // MARK: - The public tree

    public static let item = UTType("public.item")
    public static let data = UTType("public.data", conformingTo: [.item])
    public static let content = UTType("public.content")
    public static let compositeContent = UTType("public.composite-content", conformingTo: [.content])

    public static let text = UTType("public.text", conformingTo: [.data, .content])
    public static let plainText = UTType("public.plain-text", conformingTo: [.text])
    public static let utf8PlainText = UTType("public.utf8-plain-text", conformingTo: [.plainText])
    public static let utf16PlainText = UTType("public.utf16-plain-text", conformingTo: [.plainText])
    public static let json = UTType("public.json", conformingTo: [.text])
    public static let xml = UTType("public.xml", conformingTo: [.text])
    public static let propertyList = UTType("com.apple.property-list", conformingTo: [.data])
    public static let commaSeparatedText = UTType("public.comma-separated-values-text", conformingTo: [.plainText])

    public static let url = UTType("public.url", conformingTo: [.data])
    public static let fileURL = UTType("public.file-url", conformingTo: [.url])

    public static let image = UTType("public.image", conformingTo: [.data, .content])
    public static let png = UTType("public.png", conformingTo: [.image])
    public static let jpeg = UTType("public.jpeg", conformingTo: [.image])
}
