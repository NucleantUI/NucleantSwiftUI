//
//  Transferable.swift
//  NucleantSwiftUI
//
//  CoreTransferable's surface: a type says how it turns into bytes and back,
//  as one or more representations, each tagged with a content type. A drag
//  exports the payload through them and a drop imports it — the same way
//  SwiftUI moves a value between views, minus the pasteboard: the transfer
//  here stays inside the process, but still goes through the encoding, so a
//  representation that would not survive a real pasteboard fails here too.
//

import Foundation

/// A type that can be moved by drag and drop.
///
/// ```swift
/// struct Track: Codable, Transferable {
///     let name: String
///     static var transferRepresentation: some TransferRepresentation {
///         CodableRepresentation(contentType: .json)
///     }
/// }
/// ```
///
/// Representations are listed most preferred first. `String`, `Data` and
/// `URL` conform already.
public protocol Transferable {
    /// Not constrained to `Item == Self` here: with an opaque
    /// `some TransferRepresentation` witness that requirement makes the
    /// conformance check circular. The builder pins `Item` to `Self` instead,
    /// and `_exporters` checks it once more at runtime.
    associatedtype Representation: TransferRepresentation

    @TransferRepresentationBuilder<Self>
    static var transferRepresentation: Representation { get }
}

extension Transferable {
    /// The representation's functions, with `Self` in place of its `Item`.
    /// The two are the same type for anything the builder produced; only a
    /// witness written with an explicit foreign type could differ, and that
    /// is a programming error.
    static var _exporters: [_TransferExporter<Self>] {
        guard let exporters = transferRepresentation._exporters as? [_TransferExporter<Self>] else {
            preconditionFailure("\(Self.self).transferRepresentation is for \(Representation.Item.self), not \(Self.self)")
        }
        return exporters
    }

    static var _importers: [_TransferImporter<Self>] {
        guard let importers = transferRepresentation._importers as? [_TransferImporter<Self>] else {
            preconditionFailure("\(Self.self).transferRepresentation is for \(Representation.Item.self), not \(Self.self)")
        }
        return importers
    }
}

/// One way of encoding an `Item` — or several, when built from a block.
///
/// A representation is fully described by what it can export and what it
/// can import, each as a content type and a function. The concrete kinds
/// below only differ in how they come by those functions.
public protocol TransferRepresentation<Item> {
    associatedtype Item: Transferable

    var _exporters: [_TransferExporter<Item>] { get }
    var _importers: [_TransferImporter<Item>] { get }
}

/// An `Item` to bytes of one content type.
public struct _TransferExporter<Item> {
    public let contentType: UTType
    public let export: (Item) throws -> Data

    public init(contentType: UTType, export: @escaping (Item) throws -> Data) {
        self.contentType = contentType
        self.export = export
    }
}

/// Bytes of one content type to an `Item`.
public struct _TransferImporter<Item> {
    public let contentType: UTType
    public let `import`: (Data) throws -> Item

    public init(contentType: UTType, import: @escaping (Data) throws -> Item) {
        self.contentType = contentType
        self.import = `import`
    }
}

// MARK: - The builder

/// Combines the representations listed in `transferRepresentation`. One
/// stays itself; several become one that exports through each in turn and
/// imports through the first that can.
///
/// Fixed arities rather than a parameter pack: every element must have the
/// same `Item`, and a same-element requirement on a pack is not something
/// the compiler accepts yet. Four is plenty — a type rarely travels as more
/// than a native encoding, a text form and a proxy.
@resultBuilder
public struct TransferRepresentationBuilder<Item: Transferable> {

    /// Where `Item` is pinned: a `CodableRepresentation(contentType: .json)`
    /// names no item type of its own, and gets it from here.
    public static func buildExpression<R: TransferRepresentation>(_ r: R) -> R
    where R.Item == Item {
        r
    }

    public static func buildBlock<R: TransferRepresentation>(_ r: R) -> R
    where R.Item == Item {
        r
    }

    public static func buildBlock<R0: TransferRepresentation, R1: TransferRepresentation>(
        _ r0: R0, _ r1: R1
    ) -> _CombinedTransferRepresentation<Item>
    where R0.Item == Item, R1.Item == Item {
        _CombinedTransferRepresentation(r0, r1)
    }

    public static func buildBlock<R0: TransferRepresentation, R1: TransferRepresentation, R2: TransferRepresentation>(
        _ r0: R0, _ r1: R1, _ r2: R2
    ) -> _CombinedTransferRepresentation<Item>
    where R0.Item == Item, R1.Item == Item, R2.Item == Item {
        _CombinedTransferRepresentation(r0, r1, r2)
    }

    public static func buildBlock<R0: TransferRepresentation, R1: TransferRepresentation, R2: TransferRepresentation, R3: TransferRepresentation>(
        _ r0: R0, _ r1: R1, _ r2: R2, _ r3: R3
    ) -> _CombinedTransferRepresentation<Item>
    where R0.Item == Item, R1.Item == Item, R2.Item == Item, R3.Item == Item {
        _CombinedTransferRepresentation(r0, r1, r2, r3)
    }
}

/// Several representations in declaration order — what a multi-line
/// `transferRepresentation` block produces. Only their exporters and
/// importers are kept; the representations' own types are not needed once
/// those have been taken.
public struct _CombinedTransferRepresentation<Item: Transferable>: TransferRepresentation {

    public let _exporters: [_TransferExporter<Item>]
    public let _importers: [_TransferImporter<Item>]

    init(_ representations: any TransferRepresentation<Item>...) {
        _exporters = representations.flatMap { $0._exporters }
        _importers = representations.flatMap { $0._importers }
    }
}

// MARK: - Representations

/// An encoder a `CodableRepresentation` can use — Foundation's `JSONEncoder`
/// and `PropertyListEncoder` both are. Declared here rather than borrowed
/// from Combine's `TopLevelEncoder`, which does not exist off Apple platforms.
public protocol TransferEncoder {
    func encode<T: Encodable>(_ value: T) throws -> Data
}

public protocol TransferDecoder {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

extension JSONEncoder: TransferEncoder {}
extension JSONDecoder: TransferDecoder {}
extension PropertyListEncoder: TransferEncoder {}
extension PropertyListDecoder: TransferDecoder {}

/// A `Codable` item, encoded with the given coder pair — JSON by default.
///
/// ```swift
/// CodableRepresentation(contentType: .json)
/// CodableRepresentation(contentType: .propertyList,
///                       encoder: PropertyListEncoder(), decoder: PropertyListDecoder())
/// ```
public struct CodableRepresentation<
    Item: Transferable & Codable,
    Encoder: TransferEncoder,
    Decoder: TransferDecoder
>: TransferRepresentation {

    public let contentType: UTType
    let encoder: Encoder
    let decoder: Decoder

    public init(contentType: UTType, encoder: Encoder, decoder: Decoder) {
        self.contentType = contentType
        self.encoder = encoder
        self.decoder = decoder
    }

    public var _exporters: [_TransferExporter<Item>] {
        let encoder = encoder
        return [_TransferExporter(contentType: contentType) { try encoder.encode($0) }]
    }

    public var _importers: [_TransferImporter<Item>] {
        let decoder = decoder
        return [_TransferImporter(contentType: contentType) { try decoder.decode(Item.self, from: $0) }]
    }
}

extension CodableRepresentation where Encoder == JSONEncoder, Decoder == JSONDecoder {
    /// JSON, the usual choice.
    public init(contentType: UTType = .json) {
        self.init(contentType: contentType, encoder: JSONEncoder(), decoder: JSONDecoder())
    }
}

/// An item as raw bytes, converted both ways by hand. The one-sided
/// initializers make a representation that only exports or only imports.
public struct DataRepresentation<Item: Transferable>: TransferRepresentation {

    public let contentType: UTType
    let exporting: ((Item) throws -> Data)?
    let importing: ((Data) throws -> Item)?

    public init(
        contentType: UTType,
        exporting: @escaping (Item) throws -> Data,
        importing: @escaping (Data) throws -> Item
    ) {
        self.contentType = contentType
        self.exporting = exporting
        self.importing = importing
    }

    public init(exportedContentType: UTType, exporting: @escaping (Item) throws -> Data) {
        self.contentType = exportedContentType
        self.exporting = exporting
        self.importing = nil
    }

    public init(importedContentType: UTType, importing: @escaping (Data) throws -> Item) {
        self.contentType = importedContentType
        self.exporting = nil
        self.importing = importing
    }

    public var _exporters: [_TransferExporter<Item>] {
        guard let exporting else { return [] }
        return [_TransferExporter(contentType: contentType, export: exporting)]
    }

    public var _importers: [_TransferImporter<Item>] {
        guard let importing else { return [] }
        return [_TransferImporter(contentType: contentType, import: importing)]
    }
}

/// An item transferred *as* another transferable type — a `Track` that
/// travels as its name, say, so a plain-text drop accepts it. The proxy's
/// own representations do the encoding.
public struct ProxyRepresentation<Item: Transferable, Proxy: Transferable>: TransferRepresentation {

    let exporting: ((Item) throws -> Proxy)?
    let importing: ((Proxy) throws -> Item)?

    public init(
        exporting: @escaping (Item) throws -> Proxy,
        importing: @escaping (Proxy) throws -> Item
    ) {
        self.exporting = exporting
        self.importing = importing
    }

    public init(exporting: @escaping (Item) throws -> Proxy) {
        self.exporting = exporting
        self.importing = nil
    }

    public init(importing: @escaping (Proxy) throws -> Item) {
        self.exporting = nil
        self.importing = importing
    }

    public var _exporters: [_TransferExporter<Item>] {
        guard let exporting else { return [] }
        return Proxy._exporters.map { proxy in
            _TransferExporter(contentType: proxy.contentType) { item in
                try proxy.export(try exporting(item))
            }
        }
    }

    public var _importers: [_TransferImporter<Item>] {
        guard let importing else { return [] }
        return Proxy._importers.map { proxy in
            _TransferImporter(contentType: proxy.contentType) { data in
                try importing(try proxy.import(data))
            }
        }
    }
}

// MARK: - Standard conformances

/// What a `String` or `Data` cannot be decoded from.
public struct TransferDecodingError: Error, CustomStringConvertible {
    public let contentType: UTType
    public var description: String { "bytes could not be decoded as \(contentType)" }
}

// Each names its `Representation` outright: on Apple platforms Foundation
// brings CoreTransferable along, whose own conformances already give these
// types a `Representation`, and the witness would otherwise be matched to
// that one.

extension String: Transferable {
    public typealias Representation = DataRepresentation<String>

    public static var transferRepresentation: DataRepresentation<String> {
        DataRepresentation(
            contentType: .utf8PlainText,
            exporting: { Data($0.utf8) },
            importing: { data in
                guard let string = String(data: data, encoding: .utf8) else {
                    throw TransferDecodingError(contentType: .utf8PlainText)
                }
                return string
            }
        )
    }
}

extension Data: Transferable {
    public typealias Representation = DataRepresentation<Data>

    public static var transferRepresentation: DataRepresentation<Data> {
        DataRepresentation(contentType: .data, exporting: { $0 }, importing: { $0 })
    }
}

extension URL: Transferable {
    public typealias Representation = DataRepresentation<URL>

    public static var transferRepresentation: DataRepresentation<URL> {
        DataRepresentation(
            contentType: .url,
            exporting: { Data($0.absoluteString.utf8) },
            importing: { data in
                guard let string = String(data: data, encoding: .utf8), let url = URL(string: string) else {
                    throw TransferDecodingError(contentType: .url)
                }
                return url
            }
        )
    }
}

// MARK: - The item in flight

/// What a drag carries between its source and a drop: the payload, exported
/// on demand into whichever of its content types a destination asks for.
/// The in-process stand-in for an `NSItemProvider` — a value is encoded once
/// per type it is asked in, and a destination for `T` takes it only if some
/// type `T` imports is one the payload exports.
@MainActor
final class TransferPayload {

    /// One content type the payload can be had as, and how.
    private struct Export {
        let contentType: UTType
        let produce: () throws -> Data
    }

    private let exports: [Export]
    private var encoded: [UTType: Data] = [:]

    /// What was dragged, by name — for the input trace.
    let itemName: String

    init<T: Transferable>(_ item: T) {
        itemName = "\(T.self)"
        exports = T._exporters.map { exporter in
            Export(contentType: exporter.contentType) { try exporter.export(item) }
        }
    }

    var contentTypes: [UTType] { exports.map(\.contentType) }

    /// Whether a destination for `T` could take this payload — decided from
    /// the content types alone, so it can be asked on every pointer move.
    func canImport<T: Transferable>(_ type: T.Type) -> Bool {
        match(for: type) != nil
    }

    /// The payload as a `T`, through the first pairing of an importer of
    /// `T`'s and an export of this payload's whose types agree. Throws what
    /// the encoding or decoding threw.
    func load<T: Transferable>(_ type: T.Type) throws -> T? {
        guard let (importer, export) = match(for: type) else { return nil }
        let data: Data
        if let cached = encoded[export.contentType] {
            data = cached
        } else {
            data = try export.produce()
            encoded[export.contentType] = data
        }
        return try importer.import(data)
    }

    /// Importers are tried in `T`'s declared order — its preference — and
    /// each against the exports in the payload's order. A type matches when
    /// the export *conforms to* what the importer wants, so `.text` takes
    /// `.utf8PlainText` and `.json` alike.
    private func match<T: Transferable>(for type: T.Type) -> (_TransferImporter<T>, Export)? {
        for importer in T._importers {
            let wanted = importer.contentType
            if let export = exports.first(where: { $0.contentType.conforms(to: wanted) }) {
                return (importer, export)
            }
        }
        return nil
    }
}
