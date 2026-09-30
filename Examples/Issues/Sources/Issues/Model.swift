//
//  Model.swift
//  Issues
//
//  The tracker: people, a tree of projects, and the issues filed against
//  them. `Tracker` is the `@Observable` model, changed only through its
//  methods; an `Issue` is a record inside it. The inspector edits one
//  through `binding(_:_:)`, which goes through `update` — so every edit
//  also stamps the issue as updated now.
//

import Foundation
import NucleantUI
import Observation

// MARK: - Values

struct Person: Identifiable, Hashable {
    let id: Int
    let name: String
    let initials: String
    let color: Color

    static func == (a: Person, b: Person) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum Status: Int, CaseIterable, Identifiable, Comparable {
    case backlog, todo, inProgress, inReview, done, canceled

    var id: Self { self }

    var name: String {
        switch self {
        case .backlog:    return "Backlog"
        case .todo:       return "Todo"
        case .inProgress: return "In Progress"
        case .inReview:   return "In Review"
        case .done:       return "Done"
        case .canceled:   return "Canceled"
        }
    }

    var color: Color {
        switch self {
        case .backlog:    return Color(white: 0.6)
        case .todo:       return Color(hex: 0x8E8E93)
        case .inProgress: return Color(hex: 0xF5A623)
        case .inReview:   return Color(hex: 0x4C8DFF)
        case .done:       return Color(hex: 0x34C759)
        case .canceled:   return Color(hex: 0xB0B0B8)
        }
    }

    var isOpen: Bool { self != .done && self != .canceled }

    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
}

enum Priority: Int, CaseIterable, Identifiable, Comparable {
    case none, low, medium, high, urgent

    var id: Self { self }

    var name: String {
        switch self {
        case .none:   return "None"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        case .urgent: return "Urgent"
        }
    }

    /// Bars lit in the priority glyph, out of three; urgent is its own mark.
    var bars: Int { min(rawValue, 3) }

    static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

/// A project, and the projects under it.
struct Project: Identifiable, Hashable {
    let id: Int
    let name: String
    let color: Color
    var subprojects: [Project]?

    static func == (a: Project, b: Project) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// This project and every project under it, depth first.
    var flattened: [Project] {
        [self] + (subprojects ?? []).flatMap(\.flattened)
    }
}

/// What the sidebar shows the issues of.
enum Scope: Hashable {
    case all
    case mine
    case open
    case closed
    case project(Int)
    case settings
}

// MARK: - Issues

/// One issue — a record the tracker holds and changes.
struct Issue: Identifiable, Equatable {
    let id: Int
    var title: String
    var status: Status
    var priority: Priority
    var assignee: Person?
    var projectID: Int
    var points: Int
    var isBlocked = false
    var notes = ""
    let created: Date
    var updated: Date

    /// The assignee's name, for sorting by; unassigned issues sort last.
    var assigneeName: String { assignee?.name ?? "~" }

    /// The issue's key, as the table shows it: `NUI-142`.
    var key: String { "NUI-\(id)" }

    static func == (a: Issue, b: Issue) -> Bool {
        a.id == b.id && a.title == b.title && a.status == b.status && a.priority == b.priority
            && a.assignee == b.assignee && a.projectID == b.projectID && a.points == b.points
            && a.isBlocked == b.isBlocked && a.notes == b.notes && a.updated == b.updated
    }
}

// MARK: - The tracker

/// Settings for the whole app, edited in the Settings pane.
@MainActor
@Observable
final class Preferences {
    var me: Person
    var defaultPriority = Priority.medium
    var defaultPoints = 2
    var showsCanceled = false
    var showsBadges = true
    var dateStyle = DateStyle.relative

    enum DateStyle: CaseIterable, Identifiable {
        case relative, short, long
        var id: Self { self }
        var name: String {
            switch self {
            case .relative: return "Relative (3 days ago)"
            case .short:    return "Short (12/9/26)"
            case .long:     return "Long (Dec 9, 2026)"
            }
        }
    }

    init(me: Person) {
        self.me = me
    }

    func format(_ date: Date) -> String {
        switch dateStyle {
        case .relative:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: Date())
        case .short:
            return date.formatted(date: .numeric, time: .omitted)
        case .long:
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

@MainActor
@Observable
final class Tracker {
    let people: [Person]
    let projects: [Project]
    private(set) var issues: [Issue]
    let preferences: Preferences

    private var nextID: Int

    init() {
        let ada = Person(id: 1, name: "Ada Lovelace", initials: "AL", color: Color(hex: 0xAF52DE))
        let grace = Person(id: 2, name: "Grace Hopper", initials: "GH", color: Color(hex: 0x30B0C7))
        let alan = Person(id: 3, name: "Alan Turing", initials: "AT", color: Color(hex: 0xFF9500))
        let edsger = Person(id: 4, name: "Edsger Dijkstra", initials: "ED", color: Color(hex: 0x34C759))
        let barbara = Person(id: 5, name: "Barbara Liskov", initials: "BL", color: Color(hex: 0xFF2D55))
        people = [ada, grace, alan, edsger, barbara]
        preferences = Preferences(me: ada)

        projects = [
            Project(id: 100, name: "NucleantUI", color: Color(hex: 0x4C8DFF), subprojects: [
                Project(id: 101, name: "Collections", color: Color(hex: 0x4C8DFF), subprojects: nil),
                Project(id: 102, name: "Controls", color: Color(hex: 0x4C8DFF), subprojects: nil),
                Project(id: 103, name: "Text", color: Color(hex: 0x4C8DFF), subprojects: nil),
            ]),
            Project(id: 200, name: "NucleantVulkan", color: Color(hex: 0xFF6B6B), subprojects: [
                Project(id: 201, name: "Swapchain", color: Color(hex: 0xFF6B6B), subprojects: nil),
                Project(id: 202, name: "Render nodes", color: Color(hex: 0xFF6B6B), subprojects: nil),
            ]),
            Project(id: 300, name: "PyShader", color: Color(hex: 0x34C759), subprojects: nil),
        ]

        let day = 86_400.0
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }
        let seed: [(String, Status, Priority, Person?, Int, Int, Bool, Double, Double)] = [
            ("List selection with Command- and Shift-click", .done, .high, ada, 101, 3, false, 12, 1),
            ("Table columns resize by dragging the header edge", .inReview, .medium, grace, 101, 5, false, 9, 0.2),
            ("OutlineGroup rows in a sidebar", .inProgress, .medium, ada, 101, 3, false, 7, 0.5),
            ("Form label column on macOS", .inProgress, .high, barbara, 101, 2, false, 6, 1.5),
            ("Section headers collapse from their chevron", .todo, .low, nil, 101, 1, false, 5, 5),
            ("Stepper repeats while held", .done, .medium, alan, 102, 2, false, 30, 20),
            ("Segmented picker keyboard support", .backlog, .low, nil, 102, 3, false, 25, 25),
            ("Slider tick marks", .todo, .none, edsger, 102, 2, false, 14, 3),
            ("Marked text for input methods", .backlog, .urgent, grace, 103, 8, true, 40, 2),
            ("Caret blink and I-beam cursor", .todo, .medium, alan, 103, 2, false, 18, 6),
            ("TextEditor find bar", .canceled, .low, nil, 103, 5, false, 60, 45),
            ("Recreate the swapchain on display change", .inProgress, .urgent, edsger, 201, 5, false, 4, 0.1),
            ("HDR swapchain formats", .backlog, .medium, nil, 201, 8, false, 33, 33),
            ("Render node reuse across frames", .inReview, .high, barbara, 202, 5, false, 11, 0.8),
            ("External textures from IOSurface", .done, .high, grace, 202, 3, false, 21, 9),
            ("Loop unrolling in the compiler", .todo, .medium, alan, 300, 5, false, 16, 4),
            ("Matrix intrinsics", .inProgress, .medium, edsger, 300, 3, true, 13, 2),
            ("Error messages point at the Python line", .todo, .high, ada, 300, 2, false, 8, 8),
        ]
        var issues: [Issue] = []
        for (index, item) in seed.enumerated() {
            issues.append(Issue(
                id: 101 + index,
                title: item.0,
                status: item.1,
                priority: item.2,
                assignee: item.3,
                projectID: item.4,
                points: item.5,
                isBlocked: item.6,
                created: ago(item.7),
                updated: ago(item.8)
            ))
        }
        self.issues = issues
        self.nextID = 101 + seed.count
    }

    // MARK: Reading

    func project(_ id: Int) -> Project? {
        projects.flatMap(\.flattened).first { $0.id == id }
    }

    func issue(_ id: Issue.ID) -> Issue? {
        issues.first { $0.id == id }
    }

    /// The issues `scope` shows, with the text filter applied.
    func issues(in scope: Scope, matching filter: String) -> [Issue] {
        let shown = issues.filter { issue in
            switch scope {
            case .all, .settings:
                return preferences.showsCanceled || issue.status != .canceled
            case .mine:
                return issue.assignee == preferences.me && issue.status.isOpen
            case .open:
                return issue.status.isOpen
            case .closed:
                return !issue.status.isOpen
            case .project(let id):
                let ids = project(id).map { Set($0.flattened.map(\.id)) } ?? []
                return ids.contains(issue.projectID)
                    && (preferences.showsCanceled || issue.status != .canceled)
            }
        }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return shown }
        return shown.filter { issue in
            issue.title.localizedCaseInsensitiveContains(needle)
                || issue.key.localizedCaseInsensitiveContains(needle)
                || (issue.assignee?.name.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    /// How many issues `scope` holds, for the sidebar's badges.
    func count(in scope: Scope) -> Int {
        issues(in: scope, matching: "").count
    }

    // MARK: Changing

    /// File a new issue, in `scope`'s project when it is one, and hand it
    /// back so it can be selected.
    @discardableResult
    func newIssue(in scope: Scope) -> Issue {
        let projectID: Int
        if case .project(let id) = scope {
            projectID = id
        } else {
            projectID = projects[0].id
        }
        let issue = Issue(
            id: nextID,
            title: "New issue",
            status: .todo,
            priority: preferences.defaultPriority,
            assignee: scope == .mine ? preferences.me : nil,
            projectID: projectID,
            points: preferences.defaultPoints,
            created: Date(),
            updated: Date()
        )
        nextID += 1
        issues.append(issue)
        return issue
    }

    func delete(_ ids: Set<Issue.ID>) {
        issues.removeAll { ids.contains($0.id) }
    }

    func setStatus(_ status: Status, of ids: Set<Issue.ID>) {
        for id in ids { update(id) { $0.status = status } }
    }

    func setPriority(_ priority: Priority, of ids: Set<Issue.ID>) {
        for id in ids { update(id) { $0.priority = priority } }
    }

    func assign(_ person: Person?, to ids: Set<Issue.ID>) {
        for id in ids { update(id) { $0.assignee = person } }
    }

    /// Change the issue `id`; one that comes out different is stamped as
    /// updated now.
    func update(_ id: Issue.ID, _ change: (inout Issue) -> Void) {
        guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
        var issue = issues[index]
        change(&issue)
        guard issue != issues[index] else { return }
        issue.updated = Date()
        issues[index] = issue
    }

    /// A binding to one field of the issue `id`, for the inspector's
    /// controls — writes go through `update`.
    func binding<Value>(_ id: Issue.ID, _ field: WritableKeyPath<Issue, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { [weak self] in self?.issue(id)?[keyPath: field] ?? fallback },
            set: { [weak self] value in self?.update(id) { $0[keyPath: field] = value } }
        )
    }
}
