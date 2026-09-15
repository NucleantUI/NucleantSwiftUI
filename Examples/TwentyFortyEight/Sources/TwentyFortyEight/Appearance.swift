//
//  Appearance.swift
//
//  A System / Light / Dark switch, the same in every example. "System"
//  hands down the scheme the window was seeded with — which follows
//  System Settings as it changes — and the other two fix one. The root
//  view applies the result with `.colorScheme(_:)` under itself, so every
//  dynamic color in the app resolves against it.
//

import NucleantSwiftUI

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

/// A segmented control built from tap targets: the chosen segment takes
/// the tint, the rest sit on the panel color.
@View
struct AppearancePicker {
    @Binding var appearance: Appearance
    @Environment(\.tint) private var tint

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Appearance.allCases, id: \.self) { choice in
                Text(choice.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(appearance == choice ? .white : .secondary)
                    .padding(horizontal: 8, vertical: 4)
                    .background(appearance == choice ? tint : Color.clear)
                    .cornerRadius(5)
                    .onTapGesture { appearance = choice }
            }
        }
        .padding(2)
        .background(Color.tertiaryBackground)
        .cornerRadius(7)
    }
}
