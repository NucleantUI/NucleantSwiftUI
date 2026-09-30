//
//  KivyToNucleantUI.swift
//  KivyToNucleantUI
//
//  Kivy's kv language in, NucleantUI Swift out.
//
//  Started from KvSwiftUI (Py-Swift/PySwiftKitDemoPlugin), which does the same
//  for SwiftUI; this one writes NucleantUI — `@View` structs, the framework's
//  own controls and modifiers — and follows kv's semantics further:
//
//  - A kv rule for a class (`<Card@BoxLayout>:`, or `<LoginScreen>:` for a
//    class defined in Python) is a `@View` struct. The root widget is
//    `ContentView`, and a `NucleantApp` opens it in a window.
//  - A property a dynamic class invents (`count: 0`) is a stored property:
//    `@State` when a handler in the rule assigns it, a parameter otherwise.
//    `text:` given where the class is used becomes a parameter too.
//  - An input widget's value is `@State`: a Slider with `id: volume` gives
//    `@State private var volume: Double`, and `volume.value` anywhere in the
//    rule reads it.
//  - A style rule for a built-in widget (`<Label>:`) is applied to every
//    Label in the file, as Kivy does.
//  - `size_hint` is honoured: a widget in a layout fills its share unless its
//    hint is None, in which case `width`/`height` fix it.
//  - `canvas.before`/`canvas` become a background, `canvas.after` an overlay.
//
//  What has no NucleantUI counterpart is left as a `// kv:` comment in place.
//

import KvParser
import PySwiftAST

public struct KivyToNucleantUI: Sendable {

    public struct Options: Sendable {
        /// Leave `// kv:` notes where something could not be carried over.
        public var includeComments = true
        /// Add a `NucleantApp` that opens the root widget in a window.
        public var generateApp = true
        public var windowTitle = "Kivy App"

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// kv source in, Swift source out. A kv file that does not parse comes
    /// back as a comment with the parser's error.
    public func convert(_ source: String) -> String {
        do {
            let tokens = try KvTokenizer(source: source).tokenize()
            let module = RawValues(source).apply(to: try KvParser(tokens: tokens).parse())
            return generate(from: module)
        } catch {
            return "// The kv source did not parse:\n// \(error)"
        }
    }

    public func generate(from module: KvModule) -> String {
        let plan = ModulePlan(module)
        let emitter = ViewEmitter(plan: plan, options: options)

        var sections: [String] = []
        var imports = ["import NucleantUI"]

        var constants: [String] = []
        for (name, value) in plan.constants {
            let scope = ViewScope(name: "", constants: Swift.Set(plan.constants.map(\.name)))
            let code = emitter.constantValue(value, scope: scope)
            constants.append("let \(name) = \(code)")
        }
        if !constants.isEmpty { sections.append(constants.joined(separator: "\n")) }

        if options.includeComments {
            for note in plan.notes { sections.append("// kv: \(note)") }
        }

        for decl in plan.classes {
            sections.append(emitter.structSource(for: decl))
        }

        var appRoot: String?
        if let root = module.root {
            sections.append(emitter.contentViewSource(for: root))
            appRoot = "ContentView"
        } else if let decl = plan.classes.first(where: { $0.base == nil }) ?? plan.classes.last {
            appRoot = decl.name
        }

        if options.generateApp, let appRoot {
            sections.append("""
            @main
            struct KivyApp: NucleantApp {
                var body: some Scene {
                    WindowGroup(\(options.windowTitle.swiftLiteral), width: 800, height: 600) {
                        \(appRoot)()
                    }
                }
            }
            """)
        }

        if emitter.usesFoundation { imports.append("import Foundation") }
        return ([imports.sorted().joined(separator: "\n")] + sections).joined(separator: "\n\n") + "\n"
    }
}

// MARK: - The module, read once before anything is written

/// A kv class that becomes a `@View` struct.
struct ClassDecl {
    let name: String
    /// The Kivy class it extends, when kv says (`<Card@BoxLayout>`); nil for
    /// a class whose base is in Python (`<LoginScreen>`).
    let base: String?
    let rule: KvRule
    /// Stored properties, in declaration (and so init-argument) order.
    let members: [Member]
}

struct ModulePlan {
    /// Rules for built-in widgets, applied to every instance: `<Label>:`.
    private(set) var styleRules: [String: [KvRule]] = [:]
    private(set) var classes: [ClassDecl] = []
    private(set) var constants: [(name: String, value: String)] = []
    private(set) var notes: [String] = []

    func classDecl(named name: String) -> ClassDecl? {
        classes.first { $0.name == name }
    }

    init(_ module: KvModule) {
        for directive in module.directives {
            switch directive {
            case .set(let name, let value, _):
                constants.append((name, value))
            case .import(let alias, let package, _):
                notes.append("#:import \(alias) \(package) — Python imports have no Swift counterpart")
            case .include:
                notes.append("#:include — only this file is converted")
            default:
                break
            }
        }

        // Which content properties each class is given where it is used —
        // `MyButton: text: 'OK'` makes `text` a parameter of MyButton.
        var instanceProperties: [String: [String]] = [:]
        func scan(_ widget: KvWidget) {
            for property in widget.properties where passableProperties.contains(property.name) {
                if !(instanceProperties[widget.name]?.contains(property.name) ?? false) {
                    instanceProperties[widget.name, default: []].append(property.name)
                }
            }
            widget.children.forEach(scan)
        }
        module.rules.forEach { $0.children.forEach(scan) }
        module.root.map(scan)

        for rule in module.rules {
            switch rule.selector {
            case .name(let name) where builtinWidgets.contains(name):
                styleRules[name, default: []].append(rule)
            case .name(let name):
                classes.append(Self.classDecl(name: name, base: nil, rule: rule, passed: instanceProperties[name] ?? []))
            case .dynamicClass(let name, let bases):
                classes.append(Self.classDecl(name: name, base: bases.first, rule: rule, passed: instanceProperties[name] ?? []))
            case .multiple(let selectors):
                for case .name(let name) in selectors where builtinWidgets.contains(name) {
                    styleRules[name, default: []].append(rule)
                }
            case .className(let name):
                notes.append("<.\(name)> — class selectors are not converted")
            }
        }
    }

    private static func classDecl(name: String, base: String?, rule: KvRule, passed: [String]) -> ClassDecl {
        // Names a handler anywhere in the rule assigns: those are state.
        var assigned: Swift.Set<String> = []
        func collect(_ properties: [KvProperty], isRoot: Bool) {
            for property in properties where property.name.hasPrefix("on_") {
                for path in PythonToSwift.assignedPaths(in: property.value) {
                    if path.count == 2, path[0] == "root" || (isRoot && path[0] == "self") {
                        assigned.insert(path[1])
                    }
                }
            }
        }
        func walk(_ widget: KvWidget) {
            collect(widget.properties + widget.handlers, isRoot: false)
            widget.children.forEach(walk)
        }
        collect(rule.properties + rule.handlers, isRoot: true)
        rule.children.forEach(walk)

        var members: [Member] = []
        for property in rule.properties where !knownProperties.contains(property.name) && !property.name.hasPrefix("on_") {
            let (type, initial) = inferType(property.value)
            let kind: Member.Kind = assigned.contains(property.name) ? .state : .parameter
            members.append(Member(name: property.name.lowerCamel, type: type, initial: initial, kind: kind))
        }
        for property in passed where !members.contains(where: { $0.name == property.lowerCamel }) {
            let ruleValue = rule.properties.last { $0.name == property }?.value
            let initial = ruleValue.flatMap(parseKvExpression).flatMap(kvString)?.swiftLiteral ?? "\"\""
            let kind: Member.Kind = assigned.contains(property) ? .state : .parameter
            members.append(Member(name: property.lowerCamel, type: "String", initial: initial, kind: kind))
        }
        return ClassDecl(name: name, base: base, rule: rule, members: members)
    }

    /// The Swift type and initial value of a property a kv class declares
    /// by assigning it: `count: 0`, `title: 'Inbox'`, `accent: 1, .5, 0, 1`.
    private static func inferType(_ source: String) -> (String, String) {
        guard let expression = parseKvExpression(source) else { return ("String", source.swiftLiteral) }
        if case .name(let name) = expression, name.id == "True" || name.id == "False" {
            return ("Bool", name.id == "True" ? "true" : "false")
        }
        if case .constant(let constant) = expression {
            switch constant.value {
            case .bool(let value): return ("Bool", value ? "true" : "false")
            case .int(let value): return ("Int", String(value))
            case .float(let value): return ("Double", swiftNumber(value))
            case .string(let value):
                if value.hasPrefix("#"), let color = hexColor(value) { return ("Color", color) }
                return ("String", value.swiftLiteral)
            default: break
            }
        }
        if let number = kvNumber(expression) { return ("Double", swiftNumber(number)) }
        if let color = literalColor(expression) { return ("Color", color) }
        return ("String", source.swiftLiteral)
    }
}

/// `1, .5, 0, 1` / `[1, 1, 1]` as a `Color`, when every channel is a number.
func literalColor(_ expression: Expression) -> String? {
    let items = kvItems(expression)
    guard items.count == 3 || items.count == 4 else { return nil }
    let numbers = items.compactMap(kvNumber)
    guard numbers.count == items.count, numbers.allSatisfy({ (0...1).contains($0) }) else { return nil }
    let opacity = numbers.count == 4 && numbers[3] != 1 ? ", opacity: \(swiftNumber(numbers[3]))" : ""
    if numbers[0] == numbers[1], numbers[1] == numbers[2] {
        return "Color(white: \(swiftNumber(numbers[0]))\(opacity))"
    }
    return "Color(red: \(swiftNumber(numbers[0])), green: \(swiftNumber(numbers[1])), blue: \(swiftNumber(numbers[2]))\(opacity))"
}

/// Widgets the emitter knows by name. A rule naming one styles it; anything
/// else is a class of the app's own.
let builtinWidgets: Swift.Set<String> = [
    "Label", "Button", "ToggleButton", "TextInput", "Slider", "Switch", "CheckBox",
    "ProgressBar", "Spinner", "Image", "AsyncImage", "BoxLayout", "GridLayout",
    "FloatLayout", "RelativeLayout", "AnchorLayout", "StackLayout", "ScrollView",
    "Widget", "Screen", "ScreenManager", "PageLayout",
]

/// Content that a class's user may set, and so becomes a parameter.
let passableProperties: Swift.Set<String> = ["text", "source", "hint_text"]

/// Kivy widget properties. Anything else a class rule assigns is a property
/// the class declares.
let knownProperties: Swift.Set<String> = [
    "id", "size", "size_hint", "size_hint_x", "size_hint_y", "size_hint_min", "size_hint_max",
    "width", "height", "pos", "pos_hint", "x", "y", "center", "center_x", "center_y",
    "top", "right", "opacity", "disabled", "padding", "spacing", "orientation", "cols", "rows",
    "text", "font_size", "font_name", "bold", "italic", "color", "background_color",
    "background_normal", "background_down", "halign", "valign", "text_size", "markup",
    "hint_text", "multiline", "password", "value", "min", "max", "step", "active", "values",
    "source", "allow_stretch", "keep_ratio", "fit_mode", "do_scroll_x", "do_scroll_y",
    "anchor_x", "anchor_y", "state", "group", "minimum_height", "minimum_width",
    "row_default_height", "row_force_default", "col_default_width", "col_force_default",
    "line_height", "shorten", "max_lines", "outline_width", "name", "title", "foreground_color",
    "cursor_color", "readonly", "input_filter", "write_tab", "bar_width", "scroll_type",
    "effect_cls", "transition", "current", "manager",
]
