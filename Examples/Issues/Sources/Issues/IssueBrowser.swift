//
//  IssueBrowser.swift
//  Issues
//
//  The middle pane: a bar with the scope's title, a filter field and New
//  Issue, over the issues in a `Table`.
//
//  The table sorts by `sortOrder`, which a click on a column header
//  changes; the rows handed to it are sorted by that order right here, as
//  in SwiftUI. Selection is a set: ⌘-click, ⇧-click, ⇧-arrows and ⌘A all
//  work. A right click opens a menu for the rows it is on — the whole
//  selection when the row is selected — and a double click or Return
//  opens the issue.
//

import Foundation
import NucleantUI

@View
struct IssueBrowser {
    let tracker: Tracker
    let scope: Scope
    @Binding var selection: Set<Issue.ID>
    @Binding var filter: String
    @Binding var sortOrder: [KeyPathComparator<Issue>]
    /// Open an issue full-window.
    let open: (Issue.ID) -> Void

    var body: some View {
        let tracker = self.tracker
        let issues = tracker.issues(in: scope, matching: filter).sorted(using: sortOrder)
        let preferences = tracker.preferences
        let selection = $selection
        let open = self.open
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(issues.count == 1 ? "1 issue" : "\(issues.count) issues")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                TextField("Filter", text: $filter, prompt: Text("Filter by title, key or person"))
                    .frame(width: 240)
                Button("New Issue") {
                    let issue = tracker.newIssue(in: scope)
                    selection.wrappedValue = [issue.id]
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.bar)
            Divider()

            if issues.isEmpty {
                VStack(spacing: 6) {
                    Text(filter.isEmpty ? "No issues here" : "No issues match “\(filter)”")
                        .font(.system(size: 15, weight: .medium))
                    Text(filter.isEmpty ? "New Issue files one." : "Try a shorter filter.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(issues, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("ID", value: \.id) { issue in
                        CellDetail(text: issue.key, monospaced: true)
                    }
                    .width(80)
                    TableColumn("Title", value: \.title) { issue in
                        HStack(spacing: 6) {
                            Text(issue.title)
                            if issue.isBlocked {
                                BlockedTag()
                            }
                        }
                    }
                    .width(min: 120, ideal: 320)
                    TableColumn("Status", value: \.status) { issue in
                        HStack(spacing: 6) {
                            StatusGlyph(status: issue.status)
                            Text(issue.status.name)
                        }
                    }
                    .width(min: 120, ideal: 126)
                    TableColumn("Priority", value: \.priority) { issue in
                        HStack(spacing: 6) {
                            PriorityGlyph(priority: issue.priority)
                            Text(issue.priority.name)
                        }
                    }
                    .width(min: 92, ideal: 96)
                    TableColumn("Assignee", value: \.assigneeName) { issue in
                        HStack(spacing: 6) {
                            Avatar(person: issue.assignee)
                            if let person = issue.assignee {
                                Text(person.name)
                            } else {
                                CellDetail(text: "Unassigned")
                            }
                        }
                    }
                    .width(min: 110, ideal: 150)
                    TableColumn("Est.", value: \.points) { issue in
                        Text("\(issue.points)")
                    }
                    .width(48)
                    TableColumn("Updated", value: \.updated) { issue in
                        CellDetail(text: preferences.format(issue.updated))
                    }
                    .width(min: 84, ideal: 100)
                }
                .contextMenu(forSelectionType: Issue.ID.self) { ids in
                    IssueMenu(tracker: tracker, ids: ids, scope: scope, selection: selection, open: open)
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { open(id) }
                }
                .onDeleteCommand {
                    tracker.delete(selection.wrappedValue)
                    selection.wrappedValue = []
                }
            }
        }
    }

    private var title: String {
        switch scope {
        case .all: return "All Issues"
        case .mine: return "My Issues"
        case .open: return "Open"
        case .closed: return "Closed"
        case .project(let id): return tracker.project(id)?.name ?? "Project"
        case .settings: return "Settings"
        }
    }
}

/// A cell's secondary text — white, like the rest of the row, on a
/// selected row of a table that has the keys.
@View
struct CellDetail {
    let text: String
    let monospaced: Bool

    @Environment(\.backgroundProminence) private var prominence

    init(text: String, monospaced: Bool = false, _viewID: ViewID = #viewID) {
        self.text = text
        self.monospaced = monospaced
        self._viewID = _viewID
    }

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundColor(prominence == .increased ? Color.white.opacity(0.85) : .secondary)
    }
}

/// "Blocked", in a small red capsule.
@View
struct BlockedTag {
    var body: some View {
        Text("Blocked")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color(hex: 0xE5484D))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(hex: 0xE5484D).opacity(0.14)))
    }
}

/// The menu for a right click on the table: what to do with the issues
/// under it — or, below the rows, New Issue.
@View
struct IssueMenu {
    let tracker: Tracker
    let ids: Set<Issue.ID>
    let scope: Scope
    let selection: Binding<Set<Issue.ID>>
    let open: (Issue.ID) -> Void

    var body: some View {
        let tracker = self.tracker
        let ids = self.ids
        if ids.isEmpty {
            Button("New Issue") {
                let issue = tracker.newIssue(in: scope)
                selection.wrappedValue = [issue.id]
            }
        } else {
            if ids.count == 1, let id = ids.first {
                Button("Open Issue") { open(id) }
                Divider()
            }
            Menu("Status") {
                ForEach(Status.allCases) { status in
                    Button(status.name) { tracker.setStatus(status, of: ids) }
                }
            }
            Menu("Priority") {
                ForEach(Priority.allCases) { priority in
                    Button(priority.name) { tracker.setPriority(priority, of: ids) }
                }
            }
            Menu("Assignee") {
                Button("Unassigned") { tracker.assign(nil, to: ids) }
                Divider()
                ForEach(tracker.people) { person in
                    Button(person.name) { tracker.assign(person, to: ids) }
                }
            }
            Divider()
            Button(ids.count == 1 ? "Delete Issue" : "Delete \(ids.count) Issues") {
                tracker.delete(ids)
                selection.wrappedValue.subtract(ids)
            }
        }
    }
}
