//
//  NavigationPath.swift
//  NucleantUI
//

/// A type-erased list of the values pushed onto a `NavigationStack`.
///
/// ```swift
/// @State private var path = NavigationPath()
///
/// NavigationStack(path: $path) {
///     RecipeList()
///         .navigationDestination(for: Recipe.self) { RecipeDetail(recipe: $0) }
/// }
///
/// path.append(recipe)      // push
/// path.removeLast()        // pop
/// ```
///
/// Not codable: `CodableRepresentation` needs a value's type recovered from
/// its name, which this framework has no registry for.
public struct NavigationPath {

    /// One pushed value, with the type it was pushed as — the type
    /// `navigationDestination(for:)` matches on. Taken from the static type
    /// at `append`, so a value is looked up by what the caller pushed, not by
    /// whatever `AnyHashable` would unwrap to.
    struct Element: Hashable {
        let value: AnyHashable
        let type: ObjectIdentifier

        init<V: Hashable>(_ value: V) {
            self.value = AnyHashable(value)
            self.type = ObjectIdentifier(V.self)
        }
    }

    var elements: [Element] = []

    public var count: Int { elements.count }

    public var isEmpty: Bool { elements.isEmpty }

    public init() {}

    public init<S: Sequence>(_ elements: S) where S.Element: Hashable {
        self.elements = elements.map(Element.init)
    }

    public mutating func append<V: Hashable>(_ value: V) {
        elements.append(Element(value))
    }

    public mutating func removeLast(_ k: Int = 1) {
        elements.removeLast(k)
    }
}

extension NavigationPath: Equatable {}
