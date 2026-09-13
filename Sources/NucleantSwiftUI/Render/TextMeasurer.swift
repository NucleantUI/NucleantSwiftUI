//
//  TextMeasurer.swift
//  NucleantSwiftUI
//
//  Text sizing, done through ThorVG's own font metrics so layout and drawing
//  agree. Widths come from summing per-glyph advances
//  (`tvg_text_get_glyph_metrics`) rather than from a paint's AABB: the AABB is
//  only valid once a canvas has updated the paint, and layout runs before
//  anything is on a canvas.
//

import NucleantThorVG

@MainActor
enum TextMeasurer {

    /// Identifies one resolved face+size — what the advance cache is keyed on.
    private struct FaceKey: Hashable {
        let family: String?
        let size: Double
        let italic: Bool
    }

    private struct GlyphKey: Hashable {
        let face: FaceKey
        let character: Character
    }

    /// One reusable `Tvg_Paint` per face, so measuring a string doesn't
    /// allocate a text object per call. Never added to a canvas — released
    /// only when the process ends, which is the same lifetime as the cache.
    private static var probes: [FaceKey: Tvg_Paint] = [:]
    private static var advances: [GlyphKey: Double] = [:]
    private static var lineMetrics: [FaceKey: (ascent: Double, descent: Double, lineHeight: Double)] = [:]

    private static func key(for font: Font) -> FaceKey {
        PerfTrace.textMeasures += 1
        return FaceKey(family: FontRegistry.resolve(font), size: font.size, italic: font.isItalic)
    }

    private static func probe(_ face: FaceKey) -> Tvg_Paint? {
        if let existing = probes[face] { return existing }
        ThorEngine.ensureInitialized()
        guard let paint = tvg_text_new() else { return nil }
        if let family = face.family {
            _ = family.withCString { tvg_text_set_font(paint, $0) }
        } else {
            _ = tvg_text_set_font(paint, nil)
        }
        _ = tvg_text_set_size(paint, Float(face.size))
        probes[face] = paint
        return paint
    }

    /// Ascent / descent / line height for a font, in points.
    static func lineMetrics(for font: Font) -> (ascent: Double, descent: Double, lineHeight: Double) {
        let face = key(for: font)
        if let cached = lineMetrics[face] { return cached }

        var result = (ascent: font.size * 0.8, descent: font.size * 0.2, lineHeight: font.size * 1.2)
        if let paint = probe(face) {
            var metrics = Tvg_Text_Metrics()
            if tvg_text_get_text_metrics(paint, &metrics) == TVG_RESULT_SUCCESS, metrics.advance > 0 {
                result = (
                    ascent: Double(metrics.ascent),
                    descent: Double(-metrics.descent),
                    lineHeight: Double(metrics.advance)
                )
            }
        }
        lineMetrics[face] = result
        return result
    }

    /// The advance width of one character, in points.
    private static func advance(_ character: Character, face: FaceKey) -> Double {
        let glyphKey = GlyphKey(face: face, character: character)
        if let cached = advances[glyphKey] { return cached }

        // Fallback ratio for a face ThorVG can't measure — roughly the average
        // advance of a proportional Latin face at a given em size.
        var width = face.size * 0.5
        if let paint = probe(face) {
            var metrics = Tvg_Glyph_Metrics()
            let result = String(character).withCString {
                tvg_text_get_glyph_metrics(paint, $0, &metrics)
            }
            if result == TVG_RESULT_SUCCESS, metrics.advance > 0 {
                width = Double(metrics.advance)
            }
        }
        advances[glyphKey] = width
        return width
    }

    /// The width of `string` on a single line.
    static func width(of string: String, font: Font) -> Double {
        let face = key(for: font)
        return string.reduce(0) { $0 + advance($1, face: face) }
    }

    /// Break `string` into lines that fit `maxWidth`, at word boundaries where
    /// possible. `maxWidth == nil` means one line, however long.
    static func wrap(_ string: String, font: Font, maxWidth: Double?, lineLimit: Int?) -> [String] {
        let paragraphs = string.components(separatedBy: "\n")
        guard let maxWidth, maxWidth > 0 else {
            return limited(paragraphs, to: lineLimit)
        }

        let face = key(for: font)
        var lines: [String] = []

        for paragraph in paragraphs {
            var current = ""
            var currentWidth = 0.0

            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let piece = current.isEmpty ? String(word) : " " + word
                let pieceWidth = piece.reduce(0.0) { $0 + advance($1, face: face) }
                if !current.isEmpty && currentWidth + pieceWidth > maxWidth {
                    lines.append(current)
                    current = String(word)
                    currentWidth = word.reduce(0.0) { $0 + advance($1, face: face) }
                } else {
                    current += piece
                    currentWidth += pieceWidth
                }
            }
            lines.append(current)
        }
        return limited(lines, to: lineLimit)
    }

    private static func limited(_ lines: [String], to lineLimit: Int?) -> [String] {
        guard let lineLimit, lineLimit > 0, lines.count > lineLimit else { return lines }
        return Array(lines.prefix(lineLimit))
    }

    /// Measured boxes, keyed by everything that decides one. Text sizing is
    /// the leaf of every layout pass and by far its most expensive step, so it
    /// is worth remembering across passes as well as within one — the same
    /// label re-measured after a state change has not changed shape.
    private struct SizeKey: Hashable {
        let string: String
        let font: Font
        let proposal: ProposedSize
        let lineLimit: Int?
    }

    private static var sizes: [SizeKey: Size] = [:]

    /// The box `string` occupies under `proposal`.
    static func size(of string: String, font: Font, proposal: ProposedSize, lineLimit: Int?) -> Size {
        let key = SizeKey(string: string, font: font, proposal: proposal, lineLimit: lineLimit)
        if let cached = sizes[key] { return cached }
        let measured = measure(key)
        sizes[key] = measured
        return measured
    }

    private static func measure(_ key: SizeKey) -> Size {
        let (string, font, proposal, lineLimit) = (key.string, key.font, key.proposal, key.lineLimit)
        guard !string.isEmpty else {
            return Size(width: 0, height: lineMetrics(for: font).lineHeight)
        }
        let lines = wrap(string, font: font, maxWidth: proposal.width, lineLimit: lineLimit)
        let widest = lines.reduce(0.0) { max($0, width(of: $1, font: font)) }
        let lineHeight = lineMetrics(for: font).lineHeight
        return Size(
            width: proposal.width.map { min(widest, $0) } ?? widest,
            height: lineHeight * Double(lines.count)
        )
    }
}

/// ThorVG's process-wide engine.
///
/// Nothing ThorVG-side works until this has run: `tvg_wgcanvas_create` returns
/// null, and text can't be measured because the font loader isn't up. The app
/// runtime calls it at launch; the calls from the renderer and the measurer are
/// a backstop for a `ViewHost` driven without `NucleantApp` (an embedded host,
/// a test).
///
/// The thread count is fixed by the *first* call and ignored afterwards — which
/// is why the app runtime's call, made before any other, is the one that
/// decides it.
@MainActor
public enum ThorEngine {
    private static var initialized = false

    public static func ensureInitialized(threads: UInt32 = 0) {
        guard !initialized else { return }
        initialized = true
        _ = tvg_engine_init(threads)
    }
}
