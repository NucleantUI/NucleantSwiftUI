//
//  ViewMacro.swift
//  NucleantSwiftUIMacros
//
//  The compiler plugin behind `@View`. Everything here runs inside the
//  compiler; the framework never links it. See `Core/ViewID.swift` in
//  `NucleantSwiftUI` for what the generated members mean to the runtime.
//

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `#viewID` — the identity of the place it is written, as one literal.
///
/// Nested magic literals resolve to where they are *written*, so
/// `ViewID(line: Int = #line)` used as a default argument always names the
/// declaration. A macro used as a default argument is expanded at the call
/// site instead (SE-0422), which is the whole reason this is a macro and not
/// an initializer with defaults — and the compiler hands the expansion that
/// call site's file, line and column as literals, so the hash is taken here,
/// once, and the program only ever carries the `Int`. Inside another macro's
/// expansion the "file" is the expansion buffer, unique per expansion; `@View`
/// hashes its struct's real location instead (`declarationViewID`).
public struct ViewIDMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        guard let location = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .fileID) else {
            return "ViewID.unknown"
        }
        return viewIDLiteral(location)
    }
}

/// `ViewID(hash: <literal>)` for a source location the compiler reported.
func viewIDLiteral(_ location: AbstractSourceLocation) -> ExprSyntax {
    let file = location.file.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        ?? location.file.trimmedDescription
    let line = location.line.trimmedDescription
    let column = location.column.trimmedDescription
    return "ViewID(hash: \(raw: sourceHash("\(file):\(line):\(column)")))"
}

/// FNV-1a, 64 bit: fixed, not seeded, so a call site hashes the same in
/// every build and every run. Rendered as a signed literal that fits `Int`.
func sourceHash(_ text: String) -> Int {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
    }
    return Int(bitPattern: UInt(hash))
}

/// `@View` — turns a struct into an identified, comparable view.
///
/// Three roles, all on the struct it is attached to:
///
/// * **extension**: conformance to `View` (if not already declared).
/// * **memberAttribute**: `@MainActor` on every computed property, function
///   and initializer. A conformance declared in an extension does not infer
///   the protocol's actor onto the type the way `struct S: View` does, and
///   `View` is a main-actor protocol — without this, `body` would be
///   nonisolated and unable to call anything in the framework.
/// * **member**: `_viewID`, `_isEquivalent(to:)`, `_bindDynamicProperties`,
///   and — only when the struct declares no initializer of its own — a
///   memberwise-style init whose last parameter is `_viewID: ViewID =
///   #viewID`. (The usual source of the call site is `ViewBuilder`, which
///   stamps every view expression in a body; the parameter covers views
///   constructed outside one.)
///
/// A stored closure is left out of `_isEquivalent(to:)`: there is nothing
/// to compare two closures by, and a view whose only difference is a closure
/// is treated as unchanged — see `Core/ViewID.swift` for what that asks of
/// the closure.
public struct ViewMacro: ExtensionMacro, MemberMacro, MemberAttributeMacro {

    // MARK: Extension

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: ViewMacroMessage.notAStruct))
            return []
        }
        // The compiler hands over only the conformances still missing.
        guard !protocols.isEmpty else { return [] }
        let list = protocols.map { $0.trimmedDescription }.joined(separator: ", ")
        return [try ExtensionDeclSyntax("extension \(type.trimmed): \(raw: list) {}")]
    }

    // MARK: Member attributes

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        let modifiers: DeclModifierListSyntax
        let attributes: AttributeListSyntax
        var added: [AttributeSyntax] = []
        if let variable = member.as(VariableDeclSyntax.self) {
            // Stored properties can't carry an actor; computed ones must.
            guard variable.bindings.contains(where: { $0.accessorBlock != nil }) else { return [] }
            modifiers = variable.modifiers
            attributes = variable.attributes
            // `body` gets the builder spelled out. The compiler infers
            // `@ViewBuilder` from the protocol requirement for a witness, but
            // not when the conformance arrives through this macro's extension
            // and the body has statements (`let x = …` before the view) — that
            // body then fails with "no return statements".
            let isBody = variable.bindings.contains {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body"
            }
            if isBody, !attributes.contains(where: { attribute in
                attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "ViewBuilder"
            }) {
                added.append("@ViewBuilder")
            }
        } else if let function = member.as(FunctionDeclSyntax.self) {
            modifiers = function.modifiers
            attributes = function.attributes
        } else if let initializer = member.as(InitializerDeclSyntax.self) {
            modifiers = initializer.modifiers
            attributes = initializer.attributes
        } else if let subscriptDecl = member.as(SubscriptDeclSyntax.self) {
            modifiers = subscriptDecl.modifiers
            attributes = subscriptDecl.attributes
        } else {
            return []
        }
        // Respect an explicit choice either way.
        if modifiers.contains(where: { $0.name.text == "nonisolated" }) { return added }
        if attributes.contains(where: { attribute in
            attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor"
        }) {
            return added
        }
        return added + ["@MainActor"]
    }

    // MARK: Members

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else { return [] }

        let access = accessPrefix(of: structDecl.modifiers)
        let properties = storedProperties(of: structDecl)

        var members: [DeclSyntax] = []

        // No call site until something supplies one: the generated init
        // below, an author's init taking `_viewID`, or `ViewBuilder`
        // stamping the expression. Not the declaration's own location —
        // that is one value for every instance of the type, and the type is
        // already part of every identity the builder forms, so it would say
        // nothing while looking like it did. (A `#viewID` written into this
        // expansion is worse still: it sees the expansion buffer.)
        members.append("\(raw: access)var _viewID: ViewID = .unknown")

        members.append(equivalenceFunction(access: access, properties: properties))
        members.append(bindingFunction(access: access, properties: properties))

        let initializers = structDecl.memberBlock.members.compactMap {
            $0.decl.as(InitializerDeclSyntax.self)
        }
        if initializers.isEmpty {
            members.append(memberwiseInitializer(access: access, properties: properties))
        }
        // An init that does not take the call site cannot know it: a view it
        // makes outside a `@ViewBuilder` body carries `.unknown`. The macro
        // cannot add the parameter to an init the author wrote, so it says so.
        for initializer in initializers where !takesViewID(initializer) {
            context.diagnose(Diagnostic(
                node: initializer.initKeyword,
                message: ViewMacroMessage.initWithoutViewID,
                fixIt: .replace(
                    message: ViewMacroFixIt.addViewIDParameter,
                    oldNode: initializer,
                    newNode: withViewIDParameter(initializer)
                )
            ))
        }
        return members
    }

    // MARK: - Pieces

    /// `func _isEquivalent(to:)` — one `_areEquivalent` per stored property.
    ///
    /// `@State` is skipped: it lives in the store, not the struct, and a
    /// write to it dirties the owner directly. `@Environment` is skipped
    /// because the environment is compared separately by the builder. A
    /// closure is skipped because two closures cannot be compared at all:
    /// rather than making the view "never equivalent" (and so rebuilt every
    /// time its parent is), a closure counts for nothing, and the view is
    /// as equivalent as its other properties say. Every other wrapper is
    /// compared through its backing storage, which is where `Binding` keeps
    /// the source it points at.
    private static func equivalenceFunction(access: String, properties: [StoredProperty]) -> DeclSyntax {
        let checks = properties.compactMap { property -> String? in
            if property.isFunctionTyped { return nil }
            switch property.wrapper {
            case "State", "Environment":
                return nil
            case .some:
                return "_areEquivalent(self._\(property.name), other._\(property.name))"
            case .none:
                return "_areEquivalent(self.\(property.name), other.\(property.name))"
            }
        }
        let body = checks.isEmpty ? "true" : checks.joined(separator: "\n            && ")
        // Generated members are outside the reach of the memberAttribute
        // role, so the isolation is spelled out here.
        return """
            @MainActor \(raw: access)func _isEquivalent(to other: Self) -> Bool {
                \(raw: body)
            }
            """
    }

    /// `func _bindDynamicProperties(_:)` — one `binder.bind` per wrapped
    /// property, with its ordinal among the stored properties. The binder's
    /// unconstrained overload absorbs wrappers that are not the framework's.
    private static func bindingFunction(access: String, properties: [StoredProperty]) -> DeclSyntax {
        let binds = properties.enumerated().compactMap { index, property -> String? in
            guard property.wrapper != nil else { return nil }
            return "binder.bind(self._\(property.name), index: \(index))"
        }
        let body = binds.isEmpty ? "" : "\n    " + binds.joined(separator: "\n    ")
        return """
            @MainActor \(raw: access)func _bindDynamicProperties(_ binder: DynamicPropertyBinder) {\(raw: body)
            }
            """
    }

    /// The init the compiler would have synthesised, plus a trailing
    /// `_viewID` parameter that captures the call site — as visible as the
    /// struct, unlike the compiler's, which is never more than internal.
    ///
    /// Follows the memberwise rules where the syntax allows: a `let` with a
    /// value is fixed, a `var` with a value becomes a defaulted parameter, a
    /// `@State` takes its wrapped value, a `@Binding` takes the binding. A
    /// property whose type is only inferred from its initializer is left at
    /// that value rather than guessed at — the macro sees syntax, not types.
    /// For the same reason a parameter whose *type* is less visible than
    /// the struct is not caught here: the compiler reports it on the
    /// generated init, and the author writes the init by hand.
    private static func memberwiseInitializer(access: String, properties: [StoredProperty]) -> DeclSyntax {
        var parameters: [String] = []
        var assignments: [String] = []

        for property in properties {
            guard let type = property.type else { continue }
            // A closure parameter is non-escaping by default and so can't be
            // stored — in the struct or in a wrapper's `wrappedValue`; an
            // optional function type is already escaping.
            let escaping = property.isFunctionTyped && !property.isOptional ? "@escaping " : ""
            switch property.wrapper {
            case "State":
                let defaultValue = property.initializer.map { " = \($0)" } ?? ""
                parameters.append("\(property.name): \(escaping)\(type)\(defaultValue)")
                assignments.append("self._\(property.name) = State(wrappedValue: \(property.name))")
            case "Binding":
                parameters.append("\(property.name): Binding<\(type)>")
                assignments.append("self._\(property.name) = \(property.name)")
            case "Environment":
                // Initialised by its own attribute arguments.
                continue
            case .some(let other):
                // An unknown wrapper: take the wrapped value if it has no
                // initializer of its own, the same bet the compiler makes.
                guard property.initializer == nil else { continue }
                parameters.append("\(property.name): \(escaping)\(type)")
                assignments.append("self._\(property.name) = \(other)(wrappedValue: \(property.name))")
            case .none:
                if property.isLet && property.initializer != nil { continue }
                let defaultValue = property.initializer.map { " = \($0)" } ?? ""
                parameters.append("\(property.name): \(escaping)\(type)\(defaultValue)")
                assignments.append("self.\(property.name) = \(property.name)")
            }
        }
        parameters.append("_viewID: ViewID = #viewID")
        assignments.append("self._viewID = _viewID")

        return """
            @MainActor \(raw: access)init(
                \(raw: parameters.joined(separator: ",\n    "))
            ) {
                \(raw: assignments.joined(separator: "\n    "))
            }
            """
    }

    private struct StoredProperty {
        let name: String
        let type: String?
        let initializer: String?
        let isLet: Bool
        /// The property wrapper's base name — `State` for `@State`,
        /// `Environment` for `@Environment(\.font)` — if any.
        let wrapper: String?
        /// Declared with a function type (`() -> Void`, `(Int) -> Bool`).
        let isFunctionTyped: Bool
        /// Declared optional (`T?`), including an optional closure.
        let isOptional: Bool
        let node: Syntax
    }

    private static func storedProperties(of decl: StructDeclSyntax) -> [StoredProperty] {
        var result: [StoredProperty] = []
        for member in decl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if variable.modifiers.contains(where: { $0.name.text == "static" }) { continue }
            let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
            let wrapper = variable.attributes.lazy.compactMap { attribute -> String? in
                guard let attribute = attribute.as(AttributeSyntax.self) else { return nil }
                let name = attribute.attributeName.trimmedDescription
                // Attributes that aren't wrappers but commonly sit on views.
                return ["ViewBuilder", "MainActor", "nonisolated"].contains(name) ? nil : name
            }.first
            for binding in variable.bindings {
                // A computed property has an accessor block; a stored one
                // has none (or only observers).
                if let accessors = binding.accessorBlock {
                    switch accessors.accessors {
                    case .getter:
                        continue
                    case .accessors(let list):
                        let observersOnly = list.allSatisfy {
                            ["willSet", "didSet"].contains($0.accessorSpecifier.text)
                        }
                        if !observersOnly { continue }
                    }
                }
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                let name = pattern.identifier.text
                if name == "_viewID" { continue }
                let type = binding.typeAnnotation?.type
                let isFunctionTyped = type.map { type in
                    type.is(FunctionTypeSyntax.self)
                        || type.as(AttributedTypeSyntax.self)?.baseType.is(FunctionTypeSyntax.self) == true
                        || type.as(OptionalTypeSyntax.self)?.wrappedType.as(TupleTypeSyntax.self)?
                            .elements.first?.type.is(FunctionTypeSyntax.self) == true
                } ?? false
                let isOptional = type?.is(OptionalTypeSyntax.self) == true
                result.append(StoredProperty(
                    name: name,
                    type: type?.trimmedDescription,
                    initializer: binding.initializer?.value.trimmedDescription,
                    isLet: isLet,
                    wrapper: wrapper,
                    isFunctionTyped: isFunctionTyped,
                    isOptional: isOptional,
                    node: Syntax(binding)
                ))
            }
        }
        return result
    }

    /// `public ` for a public struct, otherwise nothing — a generated member
    /// is as visible as the type, never more.
    private static func accessPrefix(of modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            switch modifier.name.text {
            case "public", "open":
                return "public "
            case "package":
                return "package "
            default:
                continue
            }
        }
        return ""
    }
}

enum ViewMacroMessage: DiagnosticMessage {
    case notAStruct
    case initWithoutViewID

    var message: String {
        switch self {
        case .notAStruct:
            return "@View can only be applied to a struct"
        case .initWithoutViewID:
            return """
                this initializer cannot see where the view is constructed; \
                views it makes outside a @ViewBuilder body have no call-site \
                identity
                """
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .notAStruct:
            return MessageID(domain: "NucleantSwiftUIMacros", id: "notAStruct")
        case .initWithoutViewID:
            return MessageID(domain: "NucleantSwiftUIMacros", id: "initWithoutViewID")
        }
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .notAStruct: return .error
        case .initWithoutViewID: return .warning
        }
    }
}

enum ViewMacroFixIt: FixItMessage {
    case addViewIDParameter

    var message: String { "add '_viewID: ViewID = #viewID' and store it" }

    var fixItID: MessageID {
        MessageID(domain: "NucleantSwiftUIMacros", id: "addViewIDParameter")
    }
}

/// Does this initializer take the call site?
private func takesViewID(_ initializer: InitializerDeclSyntax) -> Bool {
    initializer.signature.parameterClause.parameters.contains {
        ($0.secondName ?? $0.firstName).text == "_viewID"
    }
}

/// The same initializer with `_viewID: ViewID = #viewID` added — before a
/// trailing closure parameter, which has to stay last to still be written as
/// one — and `self._viewID = _viewID` at the end of its body.
private func withViewIDParameter(_ initializer: InitializerDeclSyntax) -> InitializerDeclSyntax {
    var result = initializer
    var parameters = Array(initializer.signature.parameterClause.parameters)
    var parameter = FunctionParameterSyntax("_viewID: ViewID = #viewID")
    if let last = parameters.last {
        // A closure last in the list is the one a caller may write trailing,
        // so the new parameter goes in front of it rather than after.
        if isClosure(last.type) {
            parameter.leadingTrivia = last.leadingTrivia
            parameter.trailingComma = .commaToken(trailingTrivia: last.leadingTrivia.isEmpty ? .space : [])
            parameters.insert(parameter, at: parameters.count - 1)
        } else {
            parameters[parameters.count - 1].trailingComma = .commaToken()
            parameter.leadingTrivia = last.leadingTrivia.isEmpty ? .space : last.leadingTrivia
            parameters.append(parameter)
        }
    } else {
        parameters.append(parameter)
    }
    result.signature.parameterClause.parameters = FunctionParameterListSyntax(parameters)

    if var body = result.body {
        // Same line-up as the statement before it, or one level in when the
        // body was empty.
        let indent = body.statements.last?.leadingTrivia.indentation(isOnNewline: false)
            ?? Trivia.spaces(8)
        var statement: CodeBlockItemSyntax = "self._viewID = _viewID"
        statement.leadingTrivia = .newline + indent
        body.statements.append(statement)
        if body.rightBrace.leadingTrivia.isEmpty {
            body.rightBrace.leadingTrivia = .newline + (initializer.leadingTrivia.indentation(isOnNewline: false) ?? [])
        }
        result.body = body
    }
    return result
}

private func isClosure(_ type: TypeSyntax) -> Bool {
    type.is(FunctionTypeSyntax.self)
        || type.as(AttributedTypeSyntax.self).map { isClosure($0.baseType) } == true
        || type.as(OptionalTypeSyntax.self).map { isClosure($0.wrappedType) } == true
}

@main
struct NucleantSwiftUIPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ViewMacro.self,
        ViewIDMacro.self,
    ]
}
