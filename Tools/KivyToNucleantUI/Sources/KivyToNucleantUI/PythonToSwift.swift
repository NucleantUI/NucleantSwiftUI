//
//  PythonToSwift.swift
//  KivyToNucleantUI
//
//  kv values and handlers are Python. This turns the part of Python a kv
//  file actually uses — arithmetic, comparisons, string building, `str()`,
//  `int()`, reads of ids and root properties, assignments in `on_press` —
//  into Swift, and gives up (nil) on the rest rather than guess.
//

import PySwiftAST

/// Parses one kv value (`10, 20`, `'vertical'`, `str(volume.value)`) as a
/// Python expression. Parenthesised, because PySwiftAST reads a bare
/// `a if c else b` as the start of an `if` statement.
func parseKvExpression(_ source: String) -> Expression? {
    guard let module = try? parsePython("(" + normalizedPython(source) + ")") else { return nil }
    for statement in module.body {
        if case .expr(let expr) = statement { return expr.value }
        if case .blank = statement { continue }
        return nil
    }
    return nil
}

/// Parses a kv handler (`count += 1; label.text = 'hi'`) as statements.
func parseKvStatements(_ source: String) -> [Statement]? {
    guard let module = try? parsePython(normalizedPython(source)) else { return nil }
    return module.body.filter {
        if case .blank = $0 { return false }
        return true
    }
}

/// kv writes `.5`; PySwiftAST wants `0.5`. Adds the zero outside strings.
private func normalizedPython(_ source: String) -> String {
    var out = ""
    var quote: Character?
    var escaped = false
    var previous: Character?
    let characters = Array(source)
    for (index, character) in characters.enumerated() {
        if let open = quote {
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
        } else if character == "'" || character == "\"" {
            quote = character
        } else if character == ".", index + 1 < characters.count, characters[index + 1].isNumber,
                  !(previous.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == ")" || $0 == "]" } ?? false) {
            out.append("0")
        }
        out.append(character)
        previous = character
    }
    return out
}

/// A plain number: `12`, `0.5`, `-3`, `dp(40)`, `sp(18)`.
func kvNumber(_ expression: Expression) -> Double? {
    switch expression {
    case .constant(let constant):
        switch constant.value {
        case .int(let value): return Double(value)
        case .float(let value): return value
        case .string(let text):
            // '28sp', '10dp', '12'
            let digits = text.prefix { "0123456789.-".contains($0) }
            let unit = text.dropFirst(digits.count)
            guard !digits.isEmpty, unit.isEmpty || densityUnits.contains(String(unit)) || unit == "px" else { return nil }
            return Double(digits)
        default: return nil
        }
    case .unaryOp(let op) where op.op == .uSub:
        return kvNumber(op.operand).map { -$0 }
    case .unaryOp(let op) where op.op == .uAdd:
        return kvNumber(op.operand)
    case .call(let call):
        if case .name(let name) = call.fun, densityUnits.contains(name.id), call.args.count == 1 {
            return kvNumber(call.args[0])
        }
        return nil
    default:
        return nil
    }
}

func kvString(_ expression: Expression) -> String? {
    if case .constant(let constant) = expression, case .string(let value) = constant.value {
        return value
    }
    return nil
}

func kvBool(_ expression: Expression) -> Bool? {
    switch expression {
    case .constant(let constant):
        if case .bool(let value) = constant.value { return value }
        if case .int(let value) = constant.value { return value != 0 }
        return nil
    case .name(let name):
        return name.id == "True" ? true : name.id == "False" ? false : nil
    default:
        return nil
    }
}

func isKvNone(_ expression: Expression) -> Bool {
    switch expression {
    case .constant(let constant):
        if case .none = constant.value { return true }
        return false
    case .name(let name):
        return name.id == "None"
    default:
        return false
    }
}

/// The items of `a, b` or `[a, b]` or `(a, b)`; a single value is one item.
func kvItems(_ expression: Expression) -> [Expression] {
    switch expression {
    case .tuple(let tuple): tuple.elts
    case .list(let list): list.elts
    default: [expression]
    }
}

/// `dp()`, `sp()` and friends: Kivy's density-independent units. NucleantUI
/// already measures in points, so they are the number itself.
private let densityUnits: Swift.Set<String> = ["dp", "sp", "pt", "mm", "cm", "inch"]

/// Translates Python in the context of one generated view.
struct PythonToSwift {
    let scope: ViewScope
    /// The widget the kv line is written on — what `self` means.
    let selfKey: WidgetKey?

    // MARK: - Expressions

    func expression(_ expression: Expression) -> String? {
        if let pieces = stringPieces(expression) {
            return literal(pieces)
        }
        switch expression {
        case .constant(let constant):
            switch constant.value {
            case .none: return "nil"
            case .bool(let value): return value ? "true" : "false"
            case .int(let value): return String(value)
            case .float(let value): return swiftNumber(value)
            case .string(let value): return value.swiftLiteral
            default: return nil
            }

        case .name(let name):
            switch name.id {
            case "True": return "true"
            case "False": return "false"
            case "None": return "nil"
            default: return reference([name.id])
            }

        case .attribute:
            guard let path = dottedPath(expression) else { return nil }
            return reference(path)

        case .binOp(let op):
            guard let left = operand(op.left), let right = operand(op.right) else { return nil }
            switch op.op {
            case .add: return "\(left) + \(right)"
            case .sub: return "\(left) - \(right)"
            case .mult: return "\(left) * \(right)"
            case .div: return "\(left) / \(right)"
            case .mod: return "\(left).truncatingRemainder(dividingBy: \(right))"
            case .floorDiv: return "(\(left) / \(right)).rounded(.down)"
            case .pow: return "pow(\(left), \(right))"
            default: return nil
            }

        case .unaryOp(let op):
            if op.op == .not, let code = self.expression(op.operand), let type = scope.member(named: code)?.type, type != "Bool" {
                return type == "String" ? "\(code).isEmpty" : "\(code) == 0"
            }
            guard let operand = operand(op.operand) else { return nil }
            switch op.op {
            case .not: return "!\(operand)"
            case .uSub: return "-\(operand)"
            case .uAdd: return operand
            case .invert: return "~\(operand)"
            }

        case .boolOp(let op):
            let parts = op.values.map(condition)
            guard !parts.contains(where: { $0 == nil }) else { return nil }
            return parts.compactMap { $0 }.joined(separator: op.op == .and ? " && " : " || ")

        case .compare(let compare):
            var left = compare.left
            var clauses: [String] = []
            for (op, right) in zip(compare.ops, compare.comparators) {
                guard let l = operand(left), let r = operand(right) else { return nil }
                switch op {
                case .eq, .is: clauses.append("\(l) == \(r)")
                case .notEq, .isNot: clauses.append("\(l) != \(r)")
                case .lt: clauses.append("\(l) < \(r)")
                case .ltE: clauses.append("\(l) <= \(r)")
                case .gt: clauses.append("\(l) > \(r)")
                case .gtE: clauses.append("\(l) >= \(r)")
                case .in: clauses.append("\(r).contains(\(l))")
                case .notIn: clauses.append("!\(r).contains(\(l))")
                }
                left = right
            }
            return clauses.joined(separator: " && ")

        case .ifExp(let ifExp):
            guard let test = condition(ifExp.test),
                  let body = operand(ifExp.body),
                  let orElse = operand(ifExp.orElse) else { return nil }
            return "\(test) ? \(body) : \(orElse)"

        case .call(let call):
            return self.call(call)

        case .subscriptExpr(let sub):
            guard let base = operand(sub.value), let index = self.expression(sub.slice) else { return nil }
            return "\(base)[\(index)]"

        case .list, .tuple:
            let parts = kvItems(expression).map(self.expression)
            guard !parts.contains(where: { $0 == nil }) else { return nil }
            return "[" + parts.compactMap { $0 }.joined(separator: ", ") + "]"

        default:
            return nil
        }
    }

    /// An expression read as a condition: Python's truthiness, spelled out
    /// for a `String` (`not empty`) or a number (`not zero`).
    func condition(_ expression: Expression) -> String? {
        guard let code = operand(expression) else { return nil }
        switch scope.member(named: code)?.type {
        case "String": return "!\(code).isEmpty"
        case "Int", "Double": return "\(code) != 0"
        default: return code
        }
    }

    /// An expression as an operand: parenthesised unless it is atomic.
    private func operand(_ expression: Expression) -> String? {
        guard let code = self.expression(expression) else { return nil }
        switch expression {
        case .binOp, .boolOp, .compare, .ifExp, .unaryOp:
            return "(\(code))"
        default:
            return code
        }
    }

    private func call(_ call: Call) -> String? {
        let args = call.args.map { expression($0) }
        guard !args.contains(where: { $0 == nil }) else { return nil }
        let arguments = args.compactMap { $0 }

        guard case .name(let function) = call.fun else {
            return nil
        }
        switch function.id {
        case _ where densityUnits.contains(function.id) && arguments.count == 1:
            return arguments[0]
        case "int" where arguments.count == 1:
            return "Int(\(arguments[0]))"
        case "float" where arguments.count == 1:
            return "Double(\(arguments[0]))"
        case "bool" where arguments.count == 1:
            return arguments[0]
        case "len" where arguments.count == 1:
            return "\(arguments[0]).count"
        case "abs", "min", "max":
            return "\(function.id)(\(arguments.joined(separator: ", ")))"
        case "round" where arguments.count == 1:
            return "\(operand(call.args[0]) ?? arguments[0]).rounded()"
        case "round" where arguments.count == 2:
            guard let digits = kvNumber(call.args[1]).map(Int.init), digits >= 0 else { return nil }
            let scale = swiftNumber(pow10(digits))
            return "(\(arguments[0]) * \(scale)).rounded() / \(scale)"
        case "print":
            return "print(\(arguments.joined(separator: ", ")))"
        case "get_color_from_hex", "rgba":
            guard call.args.count == 1, let hex = kvString(call.args[0]) else { return nil }
            return hexColor(hex)
        default:
            return nil
        }
    }

    private func reference(_ path: [String]) -> String? {
        scope.resolve(path, selfKey: selfKey)
    }

    // MARK: - Strings

    enum Piece {
        case text(String)
        case code(String)
    }

    /// The expression as the parts of one Swift string literal, when it is
    /// string-building Python: `'Volume: ' + str(int(v))`, an f-string,
    /// `'%d%%' % v`, `'{} items'.format(n)`.
    func stringPieces(_ expression: Expression) -> [Piece]? {
        switch expression {
        case .constant(let constant):
            if case .string(let value) = constant.value { return [.text(value)] }
            return nil

        case .joinedStr(let joined):
            var pieces: [Piece] = []
            for value in joined.values {
                if let text = kvString(value) {
                    pieces.append(.text(text))
                } else if case .formattedValue(let formatted) = value {
                    guard let code = self.expression(formatted.value) else { return nil }
                    pieces.append(.code(code))
                } else {
                    return nil
                }
            }
            return pieces

        case .call(let call):
            if case .name(let function) = call.fun, function.id == "str", call.args.count == 1 {
                if let inner = stringPieces(call.args[0]) { return inner }
                return self.expression(call.args[0]).map { [.code($0)] }
            }
            if case .attribute(let attribute) = call.fun, attribute.attr == "format",
               let format = kvString(attribute.value) {
                return formatPieces(format, call.args)
            }
            return nil

        case .binOp(let op) where op.op == .add:
            let left = stringPieces(op.left)
            let right = stringPieces(op.right)
            guard left != nil || right != nil else { return nil }
            guard let l = left ?? self.expression(op.left).map({ [.code($0)] }),
                  let r = right ?? self.expression(op.right).map({ [.code($0)] }) else { return nil }
            return l + r

        case .binOp(let op) where op.op == .mod:
            guard let format = kvString(op.left) else { return nil }
            return percentPieces(format, kvItems(op.right))

        default:
            return nil
        }
    }

    func literal(_ pieces: [Piece]) -> String {
        var body = ""
        for piece in pieces {
            switch piece {
            case .text(let text): body += text.escapedForSwiftLiteral
            case .code(let code): body += "\\(\(code))"
            }
        }
        return "\"\(body)\""
    }

    /// `'{} of {}'.format(a, b)` — positional `{}` / `{0}` only.
    private func formatPieces(_ format: String, _ args: [Expression]) -> [Piece]? {
        let codes = args.map { self.expression($0) }
        guard !codes.contains(where: { $0 == nil }) else { return nil }
        var pieces: [Piece] = []
        var text = ""
        var next = 0
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            if character == "{", let close = format[index...].firstIndex(of: "}") {
                let inside = format[format.index(after: index)..<close]
                let position = inside.isEmpty ? next : Int(inside.split(separator: ":").first ?? "") ?? -1
                guard position >= 0, position < codes.count, let code = codes[position] else { return nil }
                if !text.isEmpty { pieces.append(.text(text)); text = "" }
                pieces.append(.code(code))
                next = position + 1
                index = format.index(after: close)
                continue
            }
            text.append(character)
            index = format.index(after: index)
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    /// `'%d dB' % level`, `'%.1f' % v`, `'%s: %s' % (a, b)`.
    private func percentPieces(_ format: String, _ args: [Expression]) -> [Piece]? {
        var pieces: [Piece] = []
        var text = ""
        var next = 0
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            guard character == "%" else {
                text.append(character)
                index = format.index(after: index)
                continue
            }
            // Read "%[flags][width][.precision]type".
            var cursor = format.index(after: index)
            var spec = ""
            while cursor < format.endIndex, "0123456789.-+ ".contains(format[cursor]) {
                spec.append(format[cursor])
                cursor = format.index(after: cursor)
            }
            guard cursor < format.endIndex else { return nil }
            let type = format[cursor]
            index = format.index(after: cursor)
            if type == "%" {
                text.append("%")
                continue
            }
            guard next < args.count, let value = expression(args[next]) else { return nil }
            next += 1
            if !text.isEmpty { pieces.append(.text(text)); text = "" }
            switch type {
            case "d", "i":
                pieces.append(.code("Int(\(value))"))
            case "f", "F", "g", "e":
                if let dot = spec.firstIndex(of: "."), let digits = Int(spec[spec.index(after: dot)...]) {
                    let scale = swiftNumber(pow10(digits))
                    pieces.append(.code(digits == 0 ? "Int((\(value)).rounded())" : "(\(value) * \(scale)).rounded() / \(scale)"))
                } else {
                    pieces.append(.code(value))
                }
            default:
                pieces.append(.code(value))
            }
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    // MARK: - Statements

    /// A handler as Swift lines. A statement that doesn't translate becomes a
    /// comment with the kv it came from, so nothing silently disappears.
    func statements(_ source: String) -> [String] {
        guard let statements = parseKvStatements(source) else {
            return ["// kv: \(source)"]
        }
        var lines: [String] = []
        for statement in statements {
            if let line = self.statement(statement) {
                if !line.isEmpty { lines.append(line) }
            } else {
                lines.append("// kv: \(source)")
                break
            }
        }
        return lines
    }

    private func statement(_ statement: Statement) -> String? {
        switch statement {
        case .assign(let assign):
            guard assign.targets.count == 1,
                  let target = expression(assign.targets[0]),
                  let value = expression(assign.value) else { return nil }
            return "\(target) = \(value)"
        case .augAssign(let assign):
            guard let target = expression(assign.target), let value = expression(assign.value) else { return nil }
            switch assign.op {
            case .add: return "\(target) += \(value)"
            case .sub: return "\(target) -= \(value)"
            case .mult: return "\(target) *= \(value)"
            case .div: return "\(target) /= \(value)"
            default: return nil
            }
        case .expr(let expr):
            return expression(expr.value)
        case .pass:
            return ""
        default:
            return nil
        }
    }

    /// Every dotted name an expression reads (`root.count`, `volume.value`).
    static func assignedPaths(in source: String) -> [[String]] {
        guard let statements = parseKvStatements(source) else { return [] }
        return statements.compactMap { statement in
            switch statement {
            case .assign(let assign): assign.targets.first.flatMap(dottedPath)
            case .augAssign(let assign): dottedPath(assign.target)
            default: nil
            }
        }
    }
}

/// `root.ids.volume.value` → ["root", "ids", "volume", "value"].
func dottedPath(_ expression: Expression) -> [String]? {
    switch expression {
    case .name(let name): return [name.id]
    case .attribute(let attribute): return dottedPath(attribute.value).map { $0 + [attribute.attr] }
    default: return nil
    }
}

/// `#FF8800`, `#F80`, `#FF8800CC` (kv's hex is RGBA) → a `Color`.
func hexColor(_ hex: String) -> String? {
    var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if digits.count == 3 || digits.count == 4 {
        digits = digits.map { "\($0)\($0)" }.joined()
    }
    guard digits.count == 6 || digits.count == 8, UInt32(digits, radix: 16) != nil else { return nil }
    let rgb = "0x" + digits.prefix(6).uppercased()
    if digits.count == 8, let alpha = UInt32(digits.suffix(2), radix: 16), alpha != 255 {
        return "Color(hex: \(rgb), opacity: \(swiftNumber((Double(alpha) / 255 * 100).rounded() / 100)))"
    }
    return "Color(hex: \(rgb))"
}

private func pow10(_ digits: Int) -> Double {
    (0..<digits).reduce(1.0) { value, _ in value * 10 }
}
