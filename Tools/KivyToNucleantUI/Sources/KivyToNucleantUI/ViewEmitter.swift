//
//  ViewEmitter.swift
//  KivyToNucleantUI
//
//  One kv widget → one NucleantUI view expression and its modifiers.
//
//  Lines come back unindented at the widget's own level; a container indents
//  its children one level in, and a modifier is one level in from its view.
//

import KvParser
import PySwiftAST

/// What a widget sits in, which decides how its `size_hint` reads.
enum Parent {
    /// The window, or the top of a struct's body: fill it.
    case window
    case box(vertical: Bool)
    case grid
    /// FloatLayout, RelativeLayout, AnchorLayout, Screen: children overlap.
    case free
    case scroll(vertical: Bool)

    var fillsWidth: Bool {
        switch self {
        case .window, .box, .grid, .free: true
        case .scroll(let vertical): vertical
        }
    }

    var fillsHeight: Bool {
        switch self {
        case .window, .box, .free: true
        case .grid: false
        case .scroll(let vertical): !vertical
        }
    }
}

/// A widget's properties after style rules: last write wins, first write
/// keeps its place.
struct Props {
    private var byName: [String: KvProperty] = [:]
    private(set) var order: [String] = []

    init(_ properties: [KvProperty]) {
        for property in properties {
            if byName[property.name] == nil { order.append(property.name) }
            byName[property.name] = property
        }
    }

    subscript(name: String) -> KvProperty? { byName[name] }

    func expression(_ name: String) -> Expression? {
        byName[name].flatMap { parseKvExpression($0.value) }
    }

    func number(_ name: String) -> Double? {
        expression(name).flatMap(kvNumber)
    }

    func string(_ name: String) -> String? {
        expression(name).flatMap(kvString)
    }

    func bool(_ name: String) -> Bool? {
        expression(name).flatMap(kvBool)
    }
}

/// Properties that shape Kivy's own rendering and have nothing to become here.
private let silentlyIgnored: Swift.Set<String> = [
    "id", "text_size", "markup", "pos", "x", "y", "center", "center_x", "center_y", "top", "right",
    "background_normal", "background_down", "minimum_height", "minimum_width", "name", "shorten",
    "max_lines", "line_height", "outline_width", "effect_cls", "bar_width", "scroll_type",
    "write_tab", "cursor_color", "size_hint_min", "size_hint_max", "manager", "transition",
]

/// The passable properties each base widget draws itself.
private let shownProperties: [String: [String]] = [
    "Label": ["text"], "Button": ["text"], "ToggleButton": ["text"],
    "Image": ["source"], "TextInput": ["hint_text"],
]

final class ViewEmitter {
    let plan: ModulePlan
    let options: KivyToNucleantUI.Options
    private(set) var usesFoundation = false
    private let constantNames: Swift.Set<String>

    init(plan: ModulePlan, options: KivyToNucleantUI.Options) {
        self.plan = plan
        self.options = options
        self.constantNames = Swift.Set(plan.constants.map(\.name))
    }

    // MARK: - Structs

    func structSource(for decl: ClassDecl) -> String {
        let scope = ViewScope(name: decl.name, constants: constantNames)
        decl.members.forEach(scope.add)

        // The rule is the struct's root widget. Its own `text:` reads the
        // parameter a caller may set instead.
        let shown = decl.base.map { shownProperties[$0] ?? [] } ?? []
        var properties: [KvProperty] = []
        for property in decl.rule.properties where knownProperties.contains(property.name) {
            if passableProperties.contains(property.name), scope.member(named: property.name.lowerCamel) != nil {
                if shown.contains(property.name) {
                    properties.append(KvProperty(name: property.name, value: "root.\(property.name)", line: property.line))
                }
            } else {
                properties.append(property)
            }
        }
        for kvName in shown where scope.member(named: kvName.lowerCamel) != nil {
            if !properties.contains(where: { $0.name == kvName }) {
                properties.append(KvProperty(name: kvName, value: "root.\(kvName)", line: decl.rule.line))
            }
        }

        if decl.base == nil {
            scope.note("\(decl.name)'s base class is declared in Python; laid out as a vertical BoxLayout")
        }
        let root = KvWidget(
            name: decl.base ?? "BoxLayout",
            properties: decl.base == nil ? properties + [KvProperty(name: "orientation", value: "'vertical'", line: decl.rule.line)] : properties,
            children: decl.rule.children,
            canvasBefore: decl.rule.canvasBefore,
            canvas: decl.rule.canvas,
            canvasAfter: decl.rule.canvasAfter,
            handlers: decl.rule.handlers,
            line: decl.rule.line,
            column: decl.rule.column
        )
        return structSource(named: decl.name, root: root, scope: scope)
    }

    func contentViewSource(for root: KvWidget) -> String {
        structSource(named: "ContentView", root: root, scope: ViewScope(name: "ContentView", constants: constantNames))
    }

    private func structSource(named name: String, root: KvWidget, scope: ViewScope) -> String {
        scope.rootKey = WidgetKey(root)
        declareStates(in: root, scope: scope)
        let body = view(root, parent: .window, scope: scope)

        var lines: [String] = []
        if options.includeComments {
            lines += scope.notes.map { "// kv: \($0)" }
        }
        lines.append("@View")
        lines.append("struct \(name) {")
        if !scope.members.isEmpty {
            lines += scope.members.map { $0.declaration.indented(1) }
            lines.append("")
        }
        lines.append("var body: some View {".indented(1))
        lines += body.map { $0.isEmpty ? $0 : $0.indented(2) }
        lines.append("}".indented(1))
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    func constantValue(_ source: String, scope: ViewScope) -> String {
        guard let expression = parseKvExpression(source) else { return source.swiftLiteral }
        if let color = literalColor(expression) { return color }
        if let text = kvString(expression), text.hasPrefix("#"), let color = hexColor(text) { return color }
        return PythonToSwift(scope: scope, selfKey: nil).expression(expression) ?? source.swiftLiteral
    }

    // MARK: - State behind input widgets

    /// Gives every input widget in the struct its `@State`, before any code
    /// is written, so `volume.value` resolves wherever it appears.
    private func declareStates(in widget: KvWidget, scope: ViewScope) {
        let props = Props(effectiveProperties(widget))
        let base = widget.id.map(\.lowerCamel)
        func declare(_ fallback: String, type: String, initial: String, kvProperty: String) {
            let name = scope.freshName(base ?? fallback)
            scope.add(Member(name: name, type: type, initial: initial, kind: .state))
            scope.bind(WidgetState(widget: widget.name, kvProperty: kvProperty, name: name), to: WidgetKey(widget), id: widget.id)
        }

        switch widget.name {
        case "Slider":
            let initial = props.number("value") ?? props.number("min") ?? 0
            declare("value", type: "Double", initial: swiftNumber(initial), kvProperty: "value")
        case "TextInput":
            declare("text", type: "String", initial: (props.string("text") ?? "").swiftLiteral, kvProperty: "text")
        case "Switch", "CheckBox":
            declare("isOn", type: "Bool", initial: props.bool("active") == true ? "true" : "false", kvProperty: "active")
        case "ToggleButton":
            declare("isOn", type: "Bool", initial: props.string("state") == "down" ? "true" : "false", kvProperty: "state")
        case "Spinner":
            let first = props.expression("values").flatMap { kvItems($0).first }.flatMap(kvString)
            declare("selection", type: "String", initial: (props.string("text") ?? first ?? "").swiftLiteral, kvProperty: "text")
        default:
            break
        }

        // A class used here is its own struct, with its own state.
        guard plan.classDecl(named: widget.name) == nil else { return }
        effectiveChildren(widget).forEach { declareStates(in: $0, scope: scope) }
    }

    // MARK: - Style rules

    private func styleRules(for name: String) -> [KvRule] {
        plan.styleRules[name] ?? []
    }

    private func effectiveProperties(_ widget: KvWidget) -> [KvProperty] {
        styleRules(for: widget.name).flatMap { $0.properties + $0.handlers } + widget.properties + widget.handlers
    }

    private func effectiveChildren(_ widget: KvWidget) -> [KvWidget] {
        styleRules(for: widget.name).flatMap(\.children) + widget.children
    }

    // MARK: - Views

    func view(_ widget: KvWidget, parent: Parent, scope: ViewScope) -> [String] {
        let props = Props(effectiveProperties(widget))
        let key = WidgetKey(widget)
        let python = PythonToSwift(scope: scope, selfKey: key)
        let rules = styleRules(for: widget.name)
        let canvasBefore = widget.canvasBefore ?? rules.last(where: { $0.canvasBefore != nil })?.canvasBefore
        let canvas = widget.canvas ?? rules.last(where: { $0.canvas != nil })?.canvas
        let canvasAfter = widget.canvasAfter ?? rules.last(where: { $0.canvasAfter != nil })?.canvasAfter
        let children = effectiveChildren(widget)

        var consumed: Swift.Set<String> = []
        var head: [String] = []
        var modifiers: [String] = []
        var sizes = true
        var textAlignment = false

        func use(_ names: String...) { consumed.formUnion(names) }
        func comment(_ text: String) {
            if options.includeComments { modifiers.append("// kv: \(text)") }
        }
        func code(_ name: String) -> String? {
            props.expression(name).flatMap(python.expression)
        }
        func text(_ name: String) -> String? {
            guard let expression = props.expression(name) else { return nil }
            if let pieces = python.stringPieces(expression) { return python.literal(pieces) }
            guard let code = python.expression(expression) else { return nil }
            if case .ifExp(let choice) = expression,
               python.stringPieces(choice.body) != nil, python.stringPieces(choice.orElse) != nil {
                return code
            }
            return isString(code, scope: scope) ? code : "\"\\(\(code))\""
        }
        func color(_ name: String) -> String? {
            props.expression(name).flatMap { colorCode($0, python) }
        }
        func container(_ open: String, _ parentOfChildren: Parent) {
            guard !children.isEmpty else {
                head = ["Color.clear"]
                return
            }
            head = ["\(open) {"]
            for child in children {
                head += view(child, parent: parentOfChildren, scope: scope).map { $0.isEmpty ? $0 : $0.indented(1) }
            }
            head.append("}")
        }
        func stateName() -> String {
            scope.state(for: key)?.name ?? "value"
        }

        switch widget.name {
        case "Label":
            use("text", "font_size", "bold", "italic", "font_name", "color", "halign", "valign")
            if props["text"] != nil, text("text") == nil { comment("text: \(props["text"]!.value)") }
            head = ["Text(\(text("text") ?? "\"\""))"]
            modifiers += fontModifiers(props, python, isText: true)
            if let color = color("color") { modifiers.append(".foregroundColor(\(color))") }
            if let halign = props.string("halign"), let alignment = textAlignmentName(halign) {
                modifiers.append(".multilineTextAlignment(\(alignment))")
            }
            textAlignment = true

        case "Button":
            use("text", "font_size", "bold", "italic", "font_name", "color", "background_color", "on_press", "on_release", "halign", "valign")
            let title = text("text") ?? "\"\""
            let actions = handlerLines(props, ["on_press", "on_release"], python)
            if actions.isEmpty {
                head = ["Button(\(title)) {}"]
            } else if actions.count == 1, !actions[0].hasPrefix("//") {
                head = ["Button(\(title)) { \(actions[0]) }"]
            } else {
                head = ["Button(\(title)) {"] + actions.map { $0.indented(1) } + ["}"]
            }
            modifiers += fontModifiers(props, python, isText: false)
            if let color = color("color") { modifiers.append(".foregroundColor(\(color))") }
            if let tint = color("background_color") { modifiers.append(".tint(\(tint))") }

        case "ToggleButton":
            use("text", "state", "font_size", "bold", "italic", "font_name", "color", "background_color", "group")
            head = ["Toggle(\(text("text") ?? "\"\""), isOn: $\(stateName()))"]
            modifiers.append(".toggleStyle(.button)")
            modifiers += fontModifiers(props, python, isText: false)
            if let tint = color("background_color") { modifiers.append(".tint(\(tint))") }
            if props["group"] != nil { comment("group: \(props["group"]!.value) — radio groups: use a Picker") }

        case "TextInput":
            use("text", "hint_text", "multiline", "password", "font_size", "font_name", "foreground_color")
            let binding = "$\(stateName())"
            let hint = text("hint_text") ?? "\"\""
            if props.bool("password") == true {
                head = ["SecureField(\(hint), text: \(binding))"]
            } else if props.bool("multiline") == false {
                head = ["TextField(\(hint), text: \(binding))"]
            } else {
                head = ["TextEditor(text: \(binding))"]
            }
            if props["text"] != nil, props.string("text") == nil {
                comment("text: \(props["text"]!.value) — the field owns its text; set it from a handler")
            }
            modifiers += fontModifiers(props, python, isText: false)
            if let color = color("foreground_color") { modifiers.append(".foregroundColor(\(color))") }

        case "Slider":
            use("value", "min", "max", "step", "orientation")
            let low = props.number("min") ?? 0
            let high = props.number("max") ?? 100
            var call = "Slider(value: $\(stateName()), in: \(swiftNumber(low))...\(swiftNumber(high))"
            if let step = props.number("step"), step > 0 { call += ", step: \(swiftNumber(step))" }
            head = [call + ")"]
            if props["value"] != nil, props.number("value") == nil {
                comment("value: \(props["value"]!.value) — the slider owns its value")
            }
            if props.string("orientation") == "vertical" { comment("orientation: 'vertical' — sliders are horizontal") }

        case "Switch", "CheckBox":
            use("active", "group")
            head = ["Toggle(\"\", isOn: $\(stateName()))"]
            modifiers.append(widget.name == "Switch" ? ".toggleStyle(.switch)" : ".toggleStyle(.checkbox)")
            if props["group"] != nil { comment("group: \(props["group"]!.value) — radio groups: use a Picker with .pickerStyle(.radioGroup)") }

        case "ProgressBar":
            use("value", "max")
            let value = code("value") ?? "0"
            let high = swiftNumber(props.number("max") ?? 100)
            head = [
                "ZStack(alignment: .leading) {",
                "Capsule().fill(Color.fill)".indented(1),
                "Capsule().fill(Color.blue)".indented(1),
                ".relativeSize(width: min(1, max(0, Double(\(value)) / \(high))))".indented(2),
                "}",
            ]
            modifiers.append(".frame(height: 6)")

        case "Spinner":
            use("text", "values")
            let values = props.expression("values").map { kvItems($0).compactMap(python.expression) } ?? []
            head = [
                "Picker(\"\", selection: $\(stateName())) {",
                "ForEach([\(values.joined(separator: ", "))], id: \\.self) { value in".indented(1),
                "Text(value).tag(value)".indented(2),
                "}".indented(1),
                "}",
            ]

        case "Image":
            use("source", "allow_stretch", "keep_ratio", "fit_mode", "color")
            if let source = text("source") {
                usesFoundation = true
                let fit = props.string("fit_mode") == "cover" || props.string("fit_mode") == "fill" ? ".scaledToFill()" : ".scaledToFit()"
                let scaled = props.bool("keep_ratio") == false || props.string("fit_mode") == "fill" ? "" : fit
                head = [
                    "Group {",
                    "if let image = RasterImage(contentsOf: URL(fileURLWithPath: \(source))) {".indented(1),
                    "Image(image).resizable()\(scaled)".indented(2),
                    "}".indented(1),
                    "}",
                ]
            } else {
                head = ["Color.clear"]
                comment("Image without a source")
            }

        case "AsyncImage":
            use("source")
            head = ["Rectangle().fill(Color.fill)"]
            comment("AsyncImage source: \(props["source"]?.value ?? "") — load it into a RasterImage and show it with Image")

        case "BoxLayout":
            use("orientation", "spacing", "padding")
            let vertical = props.string("orientation") == "vertical"
            container("\(vertical ? "VStack" : "HStack")(spacing: \(code("spacing") ?? "0"))", .box(vertical: vertical))

        case "GridLayout":
            // Kivy shares a grid's width between its columns and its height
            // between its rows, as stacks share theirs: rows of HStacks in a
            // VStack say that directly, where a lazy grid would size rows to
            // their content.
            use("cols", "rows", "spacing", "padding", "row_default_height", "row_force_default", "col_default_width", "col_force_default")
            let spacing = props.expression("spacing").map { kvItems($0).compactMap(python.expression) } ?? []
            let across = spacing.first ?? "0"
            let down = spacing.count > 1 ? spacing[1] : across
            let perRow: Int
            if let cols = props.number("cols"), cols >= 1 {
                perRow = Int(cols)
            } else if let rows = props.number("rows"), rows >= 1 {
                perRow = max(1, Int((Double(children.count) / rows).rounded(.up)))
            } else {
                comment("GridLayout without cols or rows")
                perRow = 1
            }
            let rowHeight = props.bool("row_force_default") == true ? props.number("row_default_height") : nil
            guard !children.isEmpty else {
                head = ["Color.clear"]
                break
            }
            head = ["VStack(spacing: \(down)) {"]
            for start in stride(from: 0, to: children.count, by: perRow) {
                let row = children[start..<min(start + perRow, children.count)]
                head.append("HStack(spacing: \(across)) {".indented(1))
                for child in row {
                    head += view(child, parent: .box(vertical: false), scope: scope).map { $0.isEmpty ? $0 : $0.indented(2) }
                }
                for _ in row.count..<perRow {
                    head.append("Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)".indented(2))
                }
                head.append("}".indented(1))
                if let rowHeight { head.append(".frame(height: \(swiftNumber(rowHeight)))".indented(2)) }
            }
            head.append("}")

        case "StackLayout":
            use("spacing", "padding", "orientation")
            comment("StackLayout — wrapping children into rows; an adaptive grid is the nearest built-in layout")
            container("LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: \(code("spacing") ?? "0"))", .grid)

        case "FloatLayout", "RelativeLayout", "Screen":
            use("name")
            container("ZStack", .free)

        case "AnchorLayout":
            use("anchor_x", "anchor_y", "padding")
            let alignment = alignmentName(
                horizontal: props.string("anchor_x").map { horizontalName($0) } ?? "center",
                vertical: props.string("anchor_y").map { verticalName($0) } ?? "center"
            )
            container(alignment.map { "ZStack(alignment: \($0))" } ?? "ZStack", .free)

        case "ScrollView":
            use("do_scroll_x", "do_scroll_y")
            let horizontal = props.bool("do_scroll_x") == true && props.bool("do_scroll_y") != true
            let both = props.bool("do_scroll_x") == true && props.bool("do_scroll_y") == true
            let axes = both ? "[.horizontal, .vertical]" : horizontal ? ".horizontal" : ".vertical"
            container("ScrollView(\(axes))", .scroll(vertical: !horizontal))

        case "ScreenManager", "PageLayout":
            use("current", "transition")
            comment("\(widget.name) — showing its first screen; move between screens with NavigationStack and NavigationLink")
            if let first = children.first {
                head = view(first, parent: .window, scope: scope)
            } else {
                head = ["Color.clear"]
            }

        case "Widget":
            if children.isEmpty, canvasBefore == nil, canvas == nil, canvasAfter == nil, case .box = parent {
                head = ["Spacer()"]
                sizes = props["size_hint"] != nil || props["size_hint_x"] != nil || props["size_hint_y"] != nil
            } else {
                container("ZStack", .free)
            }

        default:
            if let decl = plan.classDecl(named: widget.name) {
                var arguments: [String] = []
                for member in decl.members {
                    guard let kvName = props.order.first(where: { $0.lowerCamel == member.name }) else { continue }
                    use(kvName)
                    guard member.kind == .parameter else {
                        comment("\(kvName): \(props[kvName]!.value) — \(decl.name) changes \(member.name) itself")
                        continue
                    }
                    let value: String? = switch member.type {
                    case "String": text(kvName)
                    case "Color": color(kvName)
                    default: code(kvName)
                    }
                    if let value { arguments.append("\(member.name): \(value)") }
                }
                head = ["\(widget.name)(\(arguments.joined(separator: ", ")))"]
                if !widget.children.isEmpty { comment("children added where \(widget.name) is used are not carried over") }
            } else {
                if options.includeComments { head.append("// kv: \(widget.name) has no NucleantUI counterpart") }
                let inner = head
                container("VStack(spacing: 0)", .box(vertical: true))
                head = inner + head
            }
        }

        // Handlers other than a button's press have nowhere to go yet.
        for name in props.order where name.hasPrefix("on_") && !consumed.contains(name) {
            use(name)
            comment("\(name): \(props[name]!.value)")
        }

        if sizes {
            modifiers += layoutModifiers(props, parent: parent, python: python, textAlignment: textAlignment, consumed: &consumed, comment: comment)
        }
        modifiers += canvasModifiers(before: canvasBefore, main: canvas, after: canvasAfter, python: python, comment: comment)
        if widget.name == "Label", let background = color("background_color") {
            use("background_color")
            modifiers.append(".background(\(background))")
        }
        use("opacity", "disabled")
        if let opacity = code("opacity") { modifiers.append(".opacity(\(opacity))") }
        if let disabled = props.expression("disabled").flatMap(python.condition), disabled != "false" {
            modifiers.append(disabled == "true" ? ".disabled()" : ".disabled(\(disabled))")
        }

        for name in props.order where !consumed.contains(name) && !silentlyIgnored.contains(name) {
            comment("\(name): \(props[name]!.value)")
        }

        return head + modifiers.map { $0.indented(1) }
    }

    // MARK: - Handlers

    private func handlerLines(_ props: Props, _ names: [String], _ python: PythonToSwift) -> [String] {
        names.flatMap { name in props[name].map { python.statements($0.value) } ?? [] }
    }

    // MARK: - Text

    private func fontModifiers(_ props: Props, _ python: PythonToSwift, isText: Bool) -> [String] {
        let size = props.number("font_size").map(swiftNumber) ?? props.expression("font_size").flatMap(python.expression)
        let bold = props.bool("bold") == true
        let italic = props.bool("italic") == true
        var modifiers: [String] = []
        if let family = props.string("font_name") {
            modifiers.append(".font(.custom(\(family.swiftLiteral), size: \(size ?? "15"))\(bold ? ".bold()" : "")\(italic ? ".italic()" : ""))")
        } else if let size {
            modifiers.append(".font(.system(size: \(size)\(bold ? ", weight: .bold" : ""))\(italic ? ".italic()" : ""))")
        } else if isText {
            if bold { modifiers.append(".bold()") }
            if italic { modifiers.append(".italic()") }
        } else if bold || italic {
            modifiers.append(".font(.system(size: 15\(bold ? ", weight: .bold" : ""))\(italic ? ".italic()" : ""))")
        }
        return modifiers
    }

    private func isString(_ code: String, scope: ViewScope) -> Bool {
        if scope.member(named: code)?.type == "String" { return true }
        return false
    }

    // MARK: - Size, place, padding

    private func layoutModifiers(
        _ props: Props,
        parent: Parent,
        python: PythonToSwift,
        textAlignment: Bool,
        consumed: inout Swift.Set<String>,
        comment: (String) -> Void
    ) -> [String] {
        consumed.formUnion(["size_hint", "size_hint_x", "size_hint_y", "size", "width", "height", "pos_hint", "padding", "halign", "valign"])
        var modifiers: [String] = []

        // Padding sits inside the widget's box, so it comes before the frame.
        if let padding = props.expression("padding") {
            let items = kvItems(padding).map(python.expression)
            if !items.contains(where: { $0 == nil }) {
                let values = items.compactMap { $0 }
                switch values.count {
                case 1: modifiers.append(".padding(\(values[0]))")
                case 2: modifiers.append(".padding(horizontal: \(values[0]), vertical: \(values[1]))")
                case 4: modifiers.append(".padding(EdgeInsets(top: \(values[1]), leading: \(values[0]), bottom: \(values[3]), trailing: \(values[2])))")
                default: comment("padding: \(props["padding"]!.value)")
                }
            } else {
                comment("padding: \(props["padding"]!.value)")
            }
        }

        // size_hint: a number is a share of the parent, None means width /
        // height say the size.
        let hint = props.expression("size_hint").map(kvItems) ?? []
        let hintX = props.expression("size_hint_x") ?? (hint.count == 2 ? hint[0] : nil)
        let hintY = props.expression("size_hint_y") ?? (hint.count == 2 ? hint[1] : nil)
        let size = props.expression("size").map(kvItems) ?? []
        let widthExpression = props.expression("width") ?? (size.count == 2 ? size[0] : nil)
        let heightExpression = props.expression("height") ?? (size.count == 2 ? size[1] : nil)

        func axis(_ hint: Expression?, _ length: Expression?, name: String, fills: Bool) -> (fixed: String?, relative: String?, fill: Bool) {
            if let hint, isKvNone(hint) {
                guard let length else { return (nil, nil, false) }
                if let code = python.expression(length) { return (code, nil, false) }
                let raw = props[name]?.value ?? props["size"]?.value ?? ""
                if !raw.contains("minimum_") { comment("\(name): \(raw)") }
                return (nil, nil, false)
            }
            if length != nil, props[name] != nil {
                comment("\(name): \(props[name]!.value) — ignored while size_hint_\(name == "width" ? "x" : "y") is not None")
            }
            let share = hint.flatMap(kvNumber) ?? 1
            if share < 1 { return (nil, "\(swiftNumber(share))", false) }
            return (nil, nil, fills)
        }
        let width = axis(hintX, widthExpression, name: "width", fills: parent.fillsWidth)
        let height = axis(hintY, heightExpression, name: "height", fills: parent.fillsHeight)

        var textAlign: String?
        if textAlignment || props["halign"] != nil || props["valign"] != nil {
            textAlign = alignmentName(
                horizontal: props.string("halign").map { horizontalName($0) } ?? "center",
                vertical: props.string("valign").map { verticalName($0) } ?? "center"
            )
        }
        var placeAlign: String?
        if case .free = parent, let posHint = props.expression("pos_hint"), case .dict(let dict) = posHint {
            var horizontal = "center"
            var vertical = "center"
            for (key, value) in zip(dict.keys, dict.values) {
                guard let key = key.flatMap(kvString), let number = kvNumber(value) else { continue }
                switch key {
                case "x", "left": horizontal = number < 0.34 ? "leading" : number > 0.66 ? "trailing" : "center"
                case "right": horizontal = number > 0.66 ? "trailing" : number < 0.34 ? "leading" : "center"
                case "y", "bottom": vertical = number < 0.34 ? "bottom" : number > 0.66 ? "top" : "center"
                case "top": vertical = number > 0.66 ? "top" : number < 0.34 ? "bottom" : "center"
                default: break
                }
            }
            placeAlign = alignmentName(horizontal: horizontal, vertical: vertical)
        }

        let hasFixed = width.fixed != nil || height.fixed != nil
        let hasRelative = width.relative != nil || height.relative != nil
        let hasFill = width.fill || height.fill || (placeAlign != nil && (hasFixed || hasRelative))
        if hasFixed {
            var arguments: [String] = []
            if let w = width.fixed { arguments.append("width: \(w)") }
            if let h = height.fixed { arguments.append("height: \(h)") }
            // The text's alignment belongs to whichever frame has room around
            // it; a placement from pos_hint takes the outer one.
            if let a = textAlign, !hasFill || placeAlign != nil { arguments.append("alignment: \(a)") }
            modifiers.append(".frame(\(arguments.joined(separator: ", ")))")
        }
        if hasRelative {
            var arguments: [String] = []
            if let w = width.relative { arguments.append("width: \(w)") }
            if let h = height.relative { arguments.append("height: \(h)") }
            modifiers.append(".relativeSize(\(arguments.joined(separator: ", ")))")
        }
        if hasFill {
            var arguments: [String] = []
            if width.fill || placeAlign != nil { arguments.append("maxWidth: .infinity") }
            if height.fill || placeAlign != nil { arguments.append("maxHeight: .infinity") }
            if let a = placeAlign ?? textAlign { arguments.append("alignment: \(a)") }
            modifiers.append(".frame(\(arguments.joined(separator: ", ")))")
        }
        return modifiers
    }

    // MARK: - Canvas

    private func canvasModifiers(before: KvCanvas?, main: KvCanvas?, after: KvCanvas?, python: PythonToSwift, comment: (String) -> Void) -> [String] {
        var modifiers: [String] = []
        let below = [before, main].compactMap { $0 }.flatMap { shapes($0, python, comment: comment) }
        let above = after.map { shapes($0, python, comment: comment) } ?? []
        modifiers += decoration(".background", below)
        modifiers += decoration(".overlay", above)
        return modifiers
    }

    private func decoration(_ modifier: String, _ shapes: [String]) -> [String] {
        switch shapes.count {
        case 0: return []
        case 1: return ["\(modifier)(\(shapes[0]))"]
        default: return ["\(modifier)(ZStack {"] + shapes.map { $0.indented(1) } + ["})"]
        }
    }

    /// Canvas instructions as shape views, drawn in the widget's box.
    private func shapes(_ canvas: KvCanvas, _ python: PythonToSwift, comment: (String) -> Void) -> [String] {
        var color = "Color.white"
        var shapes: [String] = []
        for instruction in canvas.instructions {
            let props = Props(instruction.properties)
            func sized(_ shape: String) -> String {
                guard let size = props.expression("size"), props["size"]!.value.replacingSpaces != "self.size" else { return shape }
                let items = kvItems(size).map(python.expression)
                guard items.count == 2, let w = items[0], let h = items[1] else {
                    comment("\(instruction.instructionType) size: \(props["size"]!.value)")
                    return shape
                }
                return "\(shape).frame(width: \(w), height: \(h))"
            }
            switch instruction.instructionType {
            case "Color":
                if let rgba = props.expression("rgba").flatMap({ colorCode($0, python) }) {
                    color = rgba
                } else if let rgb = props.expression("rgb").flatMap({ colorCode($0, python) }) {
                    color = rgb
                } else if let hsv = props["hsv"] {
                    comment("Color hsv: \(hsv.value)")
                }
            case "Rectangle":
                shapes.append(sized("Rectangle().fill(\(color))"))
            case "RoundedRectangle":
                let radius = props.expression("radius").flatMap { kvItems($0).first }.flatMap(python.expression) ?? "10"
                shapes.append(sized("RoundedRectangle(cornerRadius: \(radius)).fill(\(color))"))
            case "Ellipse":
                shapes.append(sized("Ellipse().fill(\(color))"))
            case "Line":
                let width = props.expression("width").flatMap(python.expression) ?? "1"
                if props["rectangle"] != nil {
                    shapes.append("Rectangle().stroke(\(color), lineWidth: \(width))")
                } else if let rounded = props.expression("rounded_rectangle") {
                    let items = kvItems(rounded)
                    let radius = items.count >= 5 ? python.expression(items[4]) ?? "10" : "10"
                    shapes.append("RoundedRectangle(cornerRadius: \(radius)).stroke(\(color), lineWidth: \(width))")
                } else if props["circle"] != nil {
                    shapes.append("Circle().stroke(\(color), lineWidth: \(width))")
                } else if props["ellipse"] != nil {
                    shapes.append("Ellipse().stroke(\(color), lineWidth: \(width))")
                } else {
                    comment("Line \(props.order.map { "\($0): \(props[$0]!.value)" }.joined(separator: ", ")) — draw it with PathShape")
                }
            default:
                comment("canvas \(instruction.instructionType)")
            }
        }
        return shapes
    }

    private func colorCode(_ expression: Expression, _ python: PythonToSwift) -> String? {
        if let color = literalColor(expression) { return color }
        if let text = kvString(expression), let color = hexColor(text) { return color }
        let items = kvItems(expression)
        if items.count == 3 || items.count == 4 {
            let channels = items.map(python.expression)
            guard !channels.contains(where: { $0 == nil }) else { return nil }
            let c = channels.compactMap { $0 }
            return "Color(red: \(c[0]), green: \(c[1]), blue: \(c[2])\(c.count == 4 ? ", opacity: \(c[3])" : ""))"
        }
        return python.expression(expression)
    }
}

// MARK: - Alignment names

private func horizontalName(_ kv: String) -> String {
    switch kv {
    case "left", "justify": "leading"
    case "right": "trailing"
    default: "center"
    }
}

private func verticalName(_ kv: String) -> String {
    switch kv {
    case "top": "top"
    case "bottom": "bottom"
    default: "center"
    }
}

/// `.topLeading`, `.leading`, `.top` — or nil for the centre, the default.
private func alignmentName(horizontal: String, vertical: String) -> String? {
    switch (horizontal, vertical) {
    case ("center", "center"): nil
    case (_, "center"): ".\(horizontal)"
    case ("center", _): ".\(vertical)"
    default: ".\(vertical)\(horizontal.prefix(1).uppercased())\(horizontal.dropFirst())"
    }
}

private func textAlignmentName(_ halign: String) -> String? {
    switch halign {
    case "left", "justify": ".leading"
    case "center": ".center"
    case "right": ".trailing"
    default: nil
    }
}

private extension String {
    var replacingSpaces: String { filter { !$0.isWhitespace } }
}
