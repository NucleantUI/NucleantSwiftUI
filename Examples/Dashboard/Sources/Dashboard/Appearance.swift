//
//  Appearance.swift
//
//  A System / Light / Dark switch, the same in every example, as a View
//  menu in the menu bar. "System" hands down the scheme the window was
//  seeded with — which follows System Settings as it changes — and the
//  other two fix one. The menu writes the choice to `AppearanceModel`; the
//  root view reads it and applies the result with `.colorScheme(_:)` under
//  itself, so every dynamic color in the app resolves against it.
//

import NucleantSwiftUI
import Observation

enum Appearance: CaseIterable {
    case system, light, dark

    var name: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// `nil` for System — the caller substitutes the window's own scheme.
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// The chosen appearance. One per app: a menu command has no view to hold
/// state in, so the choice lives here, and the root view that reads it is
/// rebuilt when it changes like on any `@Observable` write.
@MainActor
@Observable
final class AppearanceModel {
    static let shared = AppearanceModel()

    var appearance = Appearance.system
}

/// The View menu: one row per appearance.
struct AppearanceCommands: Commands {
    var body: some Commands {
        CommandMenu("View") {
            ForEach(Appearance.allCases, id: \.self) { choice in
                Button(choice.name) { AppearanceModel.shared.appearance = choice }
            }
        }
    }
}
