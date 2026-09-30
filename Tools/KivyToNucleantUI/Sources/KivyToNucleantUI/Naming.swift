//
//  Naming.swift
//  KivyToNucleantUI
//
//  kv is snake_case and Python-quoted; the output is Swift.
//

extension String {

    /// `font_size` → `fontSize`, `name_input` → `nameInput`. A leading
    /// underscore is dropped; a result that is a Swift keyword is backticked.
    var lowerCamel: String {
        let words = split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        guard let first = words.first else { return self }
        let head = first.prefix(1).lowercased() + first.dropFirst()
        let tail = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let name = ([head] + tail).joined()
        return swiftKeywords.contains(name) ? "`\(name)`" : name
    }

    /// `login_screen` → `LoginScreen`, `MyButton` stays.
    var upperCamel: String {
        split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }

    /// The text as a Swift string literal body: escaped, not yet quoted.
    var escapedForSwiftLiteral: String {
        var out = ""
        for character in self {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out
    }

    /// The text as a quoted Swift string literal.
    var swiftLiteral: String { "\"\(escapedForSwiftLiteral)\"" }

    func indented(_ level: Int) -> String {
        String(repeating: "    ", count: level) + self
    }
}

private let swiftKeywords: Set<String> = [
    "as", "break", "case", "catch", "class", "continue", "default", "defer", "do",
    "else", "enum", "extension", "fallthrough", "false", "for", "func", "guard",
    "if", "import", "in", "init", "internal", "is", "let", "nil", "operator",
    "private", "protocol", "public", "repeat", "return", "self", "static",
    "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
    "var", "where", "while",
]

/// A number as Swift source: `1`, `0.5`, `-3`.
func swiftNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
        return String(Int(value))
    }
    return String(value)
}
