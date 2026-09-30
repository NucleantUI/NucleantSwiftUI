//
//  RawValues.swift
//  KivyToNucleantUI
//
//  KvParser rebuilds a property's value from its tokens, joined by spaces —
//  `count += 1` comes back as `count + = 1`, `.5` as `. 5`, and every string
//  in double quotes. That is fine for display and not for parsing the value
//  as Python, so each value is read again from the line it was written on.
//

import KvParser

struct RawValues {
    private let lines: [Substring]

    init(_ source: String) {
        lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The module with every property's value as written in the source.
    func apply(to module: KvModule) -> KvModule {
        KvModule(
            directives: module.directives,
            rules: module.rules.map(apply),
            templates: module.templates,
            root: module.root.map(apply),
            dynamicClasses: module.dynamicClasses,
            line: module.line,
            column: module.column
        )
    }

    private func apply(_ rule: KvRule) -> KvRule {
        KvRule(
            selector: rule.selector,
            properties: rule.properties.map(apply),
            children: rule.children.map(apply),
            canvasBefore: rule.canvasBefore.map(apply),
            canvas: rule.canvas.map(apply),
            canvasAfter: rule.canvasAfter.map(apply),
            handlers: rule.handlers.map(apply),
            avoidPrevious: rule.avoidPrevious,
            line: rule.line,
            column: rule.column
        )
    }

    private func apply(_ widget: KvWidget) -> KvWidget {
        KvWidget(
            name: widget.name,
            id: widget.id,
            properties: widget.properties.map(apply),
            children: widget.children.map(apply),
            canvasBefore: widget.canvasBefore.map(apply),
            canvas: widget.canvas.map(apply),
            canvasAfter: widget.canvasAfter.map(apply),
            handlers: widget.handlers.map(apply),
            level: widget.level,
            line: widget.line,
            column: widget.column
        )
    }

    private func apply(_ canvas: KvCanvas) -> KvCanvas {
        KvCanvas(
            instructions: canvas.instructions.map {
                KvCanvasInstruction(instructionType: $0.instructionType, properties: $0.properties.map(apply), line: $0.line, column: $0.column)
            },
            line: canvas.line,
            column: canvas.column
        )
    }

    private func apply(_ property: KvProperty) -> KvProperty {
        guard let value = value(of: property) else { return property }
        return KvProperty(name: property.name, value: value, line: property.line, column: property.column)
    }

    /// The text after `name:` on the property's line, and the lines under it
    /// that are indented further — kv's continuation lines.
    private func value(of property: KvProperty) -> String? {
        let index = property.line - 1
        guard lines.indices.contains(index) else { return nil }
        let line = lines[index]
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix(property.name),
              let colon = trimmed.dropFirst(property.name.count).firstIndex(of: ":") else { return nil }
        guard trimmed[trimmed.index(trimmed.startIndex, offsetBy: property.name.count)..<colon].allSatisfy(\.isWhitespace) else {
            return nil
        }
        let first = trimmed[trimmed.index(after: colon)...].trimmingSpaces

        let indent = line.count - trimmed.count
        var continuation: [Substring] = []
        var next = index + 1
        while next < lines.count {
            let candidate = lines[next]
            let body = candidate.drop(while: { $0 == " " || $0 == "\t" })
            if body.isEmpty || body.hasPrefix("#") {
                next += 1
                continue
            }
            guard candidate.count - body.count > indent else { break }
            continuation.append(candidate)
            next += 1
        }
        guard !continuation.isEmpty else { return first }

        let margin = continuation.map { $0.count - $0.drop(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        let block = continuation.map { String($0.dropFirst(margin)) }.joined(separator: "\n")
        return first.isEmpty ? block : first + "\n" + block
    }
}

private extension Substring {
    var trimmingSpaces: String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
