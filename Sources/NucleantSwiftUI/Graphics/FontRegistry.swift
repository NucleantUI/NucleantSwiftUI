//
//  FontRegistry.swift
//  NucleantSwiftUI
//
//  ThorVG resolves a text paint's family by a name it was handed at load
//  time. `tvg_font_load(path)` keys the cache by path and registers whatever
//  family name is inside the file, which we'd then have to guess; loading the
//  bytes through `tvg_font_load_data(name:…)` lets us pick the key, so a
//  `Font` maps to a name deterministically.
//
//  Everything here is cached — *including failures*. Resolution sits on the
//  layout hot path (every text measurement asks for it), and an uncached miss
//  costs a full file read plus a parse attempt. Without the negative caches
//  below, one rebuild of a modest view tree spent ~300ms re-reading the same
//  unparseable font over and over.
//

import Foundation
import NucleantThorVG

@MainActor
public enum FontRegistry {

    /// What a `Font` actually resolves to, so the whole lookup below runs once
    /// per distinct font rather than once per measurement. `nil` values are
    /// cached too — a font with no usable face must not be re-searched.
    private static var resolutions: [ResolutionKey: String?] = [:]

    private struct ResolutionKey: Hashable {
        let family: String?
        let design: FontDesign
        let isBold: Bool
        let isItalic: Bool
    }

    /// Face names ThorVG has accepted, and ones already proven unusable —
    /// either not found on disk or rejected by the loader.
    private static var loaded: Set<String> = []
    private static var failed: Set<String> = []

    /// Explicit registrations: our family name → file path.
    private static var registeredPaths: [String: String] = [:]

    /// Where the built-in designs come from, in preference order. Ordered so a
    /// face ThorVG can actually parse comes first: macOS ships Helvetica and
    /// Menlo *only* as `.ttc` collections, which its loader rejects (see
    /// `fontExtensions`), so those are listed after a `.ttf` equivalent rather
    /// than first.
    private static let builtinFaces: [FontDesign: [String]] = [
        .default:    ["Helvetica Neue", "Arial", "Geneva", "Helvetica"],
        .serif:      ["Times New Roman", "Georgia", "Palatino"],
        .monospaced: ["Monaco", "Courier New", "Andale Mono", "Menlo"],
        .rounded:    ["Arial Rounded Bold", "Arial", "Geneva"],
    ]

    /// Directories scanned for a face named by `builtinFaces`.
    private static let searchDirectories = [
        "/System/Library/Fonts",
        "/System/Library/Fonts/Supplemental",
        "/Library/Fonts",
        NSHomeDirectory() + "/Library/Fonts",
    ]

    /// Extensions worth trying. `.ttc` is deliberately absent: a TrueType
    /// *Collection* holds several faces in one file and ThorVG's loader
    /// rejects it outright — every `Helvetica.ttc` / `Menlo.ttc` attempt
    /// returned a failure after reading the whole ~1MB file. Skipping the
    /// extension turns that into a cheap `stat` miss.
    private static let fontExtensions = [".ttf", ".otf"]

    /// Register a font file under a family name usable as `Font.custom(_:size:)`.
    /// Returns false when the file can't be read or ThorVG rejects it.
    @discardableResult
    public static func register(path: String, as family: String) -> Bool {
        registeredPaths[family] = path
        failed.remove(family)
        loaded.remove(family)
        resolutions.removeAll(keepingCapacity: true)
        return load(family: family, from: path)
    }

    /// The ThorVG family name to hand `tvg_text_set_font` for `font`, loading
    /// the face on first use. `nil` lets ThorVG pick its own fallback.
    static func resolve(_ font: Font) -> String? {
        let key = ResolutionKey(
            family: font.family,
            design: font.design,
            isBold: font.weight.isBoldFace,
            isItalic: font.isItalic
        )
        if let cached = resolutions[key] { return cached }

        let resolved = search(key)
        resolutions[key] = resolved
        return resolved
    }

    private static func search(_ key: ResolutionKey) -> String? {
        let candidates = key.family.map { [$0] }
            ?? builtinFaces[key.design]
            ?? builtinFaces[.default]!

        for family in candidates {
            for name in faceNames(family: family, bold: key.isBold, italic: key.isItalic) {
                if ensureLoaded(name) { return name }
            }
        }
        return nil
    }

    /// The file-name variants a family/weight/italic combination might be
    /// stored under, most specific first — macOS ships these as separate
    /// `Family Bold.ttf` / `Family Italic.ttf` files rather than one variable
    /// font, so the style is part of the name.
    private static func faceNames(family: String, bold: Bool, italic: Bool) -> [String] {
        var names: [String] = []
        if bold && italic { names.append("\(family) Bold Italic") }
        if bold           { names.append("\(family) Bold") }
        if italic         { names.append("\(family) Italic") }
        names.append(family)
        return names
    }

    /// Load `name` into ThorVG if it isn't already there. The name doubles as
    /// the file's basename when it wasn't explicitly registered.
    private static func ensureLoaded(_ name: String) -> Bool {
        if loaded.contains(name) { return true }
        if failed.contains(name) { return false }

        let path = registeredPaths[name] ?? locate(name)
        guard let path, load(family: name, from: path) else {
            failed.insert(name)
            return false
        }
        return true
    }

    private static func locate(_ name: String) -> String? {
        let manager = FileManager.default
        for directory in searchDirectories {
            for suffix in fontExtensions {
                let path = "\(directory)/\(name)\(suffix)"
                if manager.isReadableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    private static func load(family: String, from path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else {
            return false
        }
        let mimetype = (path as NSString).pathExtension.lowercased()
        // copy: true — ThorVG keeps the bytes, and `data` dies with this call.
        let result = tvg_font_load_from_data(
            name: family,
            data: [UInt8](data),
            mimetype: mimetype,
            copy: true
        )
        guard result == TVG_RESULT_SUCCESS else { return false }
        loaded.insert(family)
        return true
    }
}
