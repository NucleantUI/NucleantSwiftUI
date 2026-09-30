//
//  IssuesApp.swift
//  Issues
//
//  An issue tracker, in the three panes of a desktop app:
//
//  * a sidebar `List` in `.sidebar` style, its rows in `Section`s — the
//    issue views with `.badge` counts, and the projects as an
//    `OutlineGroup` that opens to show subprojects (→ and ← do it from the
//    keyboard);
//  * the issues in a `Table` — sortable by every column but the last,
//    columns that resize from their header edges, ⌘/⇧-click and ⇧-arrow
//    multiple selection, a `.contextMenu(forSelectionType:)` that sets the
//    status, priority or assignee of the whole selection and opens an issue
//    on a double click, and Delete to delete;
//  * an inspector: a grouped `Form` editing the selected issue — a title
//    `TextField`, `Picker`s for status, priority, project and assignee, a
//    `Stepper` for the estimate, a `Toggle`, `LabeledContent` for the
//    dates and a `TextEditor` for notes.
//
//  Settings, the last row of the sidebar, is a `Form` in the desktop's
//  `.columns` style: labels in a column of their own, section headers
//  beside their first row.
//

import Foundation
import NucleantUI

enum Theme {
    static let sidebar = Color.dynamic(light: Color(hex: 0xEEEEF2), dark: Color(hex: 0x16181D))
    static let bar = Color.dynamic(light: Color(hex: 0xF7F7F9), dark: Color(hex: 0x1B1D23))
    static let accent = Color(hex: 0x5E6AD2)
}

@View
struct IssuesView {
    @State private var tracker = Tracker()
    @State private var scope: Scope? = .all
    @State private var selection: Set<Issue.ID> = []
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\Issue.updated, order: .reverse)]
    /// The issue open full-window, if one is.
    @State private var opened: Issue.ID? = nil
    @Environment(\.colorScheme) private var system

    var body: some View {
        // Choosing somewhere in the sidebar closes an issue open full-window.
        let scope = Binding(get: { self.scope }, set: { self.scope = $0; self.opened = nil })
        HStack(spacing: 0) {
            Sidebar(tracker: tracker, scope: scope)
                .frame(width: 230)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)
            Divider()
            if self.scope == .settings {
                SettingsPane(preferences: tracker.preferences, people: tracker.people)
            } else if let opened {
                IssueDetail(tracker: tracker, id: opened) { self.opened = nil }
            } else {
                IssueBrowser(
                    tracker: tracker,
                    scope: self.scope ?? .all,
                    selection: $selection,
                    filter: $filter,
                    sortOrder: $sortOrder,
                    open: { id in
                        selection = [id]
                        opened = id
                    }
                )
                Divider()
                Inspector(tracker: tracker, selection: $selection)
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondaryBackground)
        .tint(Theme.accent)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }
}

@main
struct IssuesApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Issues", width: 1280, height: 780) {
            IssuesView()
        }
        .commands { AppearanceCommands() }
    }
}

// MARK: - Small shared pieces

/// A person's initials in a circle of their colour.
@View
struct Avatar {
    let person: Person?
    var size: Double = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(person?.color ?? Color.clear)
            if let person {
                Text(person.initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Circle()
                    .stroke(Color.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A status as a ring, its middle filled more the further the work has
/// got.
@View
struct StatusGlyph {
    let status: Status

    var body: some View {
        ZStack {
            Circle()
                .stroke(status.color, lineWidth: 1.5)
            switch status {
            case .inProgress:
                Circle()
                    .fill(status.color)
                    .frame(width: 5, height: 5)
            case .inReview:
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
            case .done:
                Circle()
                    .fill(status.color)
                Checkmark()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 7, height: 7)
            case .canceled:
                Circle()
                    .fill(status.color)
                Text("×")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            case .backlog, .todo:
                EmptyView()
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// A tick, drawn to fill its frame — the bundled face has no "✓".
@View
struct Checkmark: Shape {
    func path(in rect: Rect) -> Path {
        var path = Path()
        path.move(to: Point(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.55))
        path.addLine(to: Point(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.85))
        path.addLine(to: Point(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// Priority as three bars of rising height, the lit ones in the text
/// colour; urgent as a filled square with "!".
@View
struct PriorityGlyph {
    let priority: Priority

    var body: some View {
        if priority == .urgent {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: 0xFF6B3D))
                Text("!")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.white)
            }
            .frame(width: 13, height: 13)
        } else {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { bar in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(bar < priority.bars ? Color.primary : Color.tertiary.opacity(0.5))
                        .frame(width: 3, height: 5 + Double(bar) * 3)
                }
            }
            .frame(width: 13, height: 13, alignment: .bottom)
        }
    }
}
