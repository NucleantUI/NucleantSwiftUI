//
//  Inspector.swift
//  Issues
//
//  The right-hand pane, and the full-window page an issue opens into.
//
//  One issue selected: a `Form` in `.grouped` style editing it — each
//  control bound to one field through `Tracker.binding`. Several: the same
//  pickers, changing all of them at once, showing "Mixed" where they
//  differ. None: a note saying so.
//

import Foundation
import NucleantUI

@View
struct Inspector {
    let tracker: Tracker
    @Binding var selection: Set<Issue.ID>

    var body: some View {
        let ids = selection.filter { tracker.issue($0) != nil }
        if ids.count == 1, let id = ids.first {
            IssueForm(tracker: tracker, id: id, showsTitleAndNotes: true)
        } else if ids.count > 1 {
            BulkEditForm(tracker: tracker, ids: ids)
        } else {
            VStack(spacing: 6) {
                Text("No Issue Selected")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Select an issue to see its details.")
                    .font(.system(size: 12))
                    .foregroundColor(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.background)
        }
    }
}

/// One issue's fields as a grouped form.
@View
struct IssueForm {
    let tracker: Tracker
    let id: Issue.ID
    /// The full page shows the title and notes beside the form instead.
    let showsTitleAndNotes: Bool

    var body: some View {
        let tracker = self.tracker
        let id = self.id
        if let issue = tracker.issue(id) {
            Form {
                if showsTitleAndNotes {
                    Section {
                        TextField("Title", text: tracker.binding(id, \.title, default: ""), axis: .vertical)
                            .lineLimit(1...4)
                    } header: {
                        Text(issue.key)
                    }
                }
                Section("Properties") {
                    Picker("Status", selection: tracker.binding(id, \.status, default: .todo)) {
                        ForEach(Status.allCases) { status in
                            HStack(spacing: 6) {
                                StatusGlyph(status: status)
                                Text(status.name)
                            }
                        }
                    }
                    Picker("Priority", selection: tracker.binding(id, \.priority, default: .none)) {
                        ForEach(Priority.allCases) { priority in
                            HStack(spacing: 6) {
                                PriorityGlyph(priority: priority)
                                Text(priority.name)
                            }
                        }
                    }
                    Picker("Assignee", selection: tracker.binding(id, \.assignee, default: nil)) {
                        Text("Unassigned").tag(Person?.none)
                        Divider()
                        ForEach(tracker.people) { person in
                            HStack(spacing: 6) {
                                Avatar(person: person, size: 16)
                                Text(person.name)
                            }
                            .tag(Person?.some(person))
                        }
                    }
                    Picker("Project", selection: tracker.binding(id, \.projectID, default: 0)) {
                        ForEach(tracker.projects) { project in
                            Section {
                                ForEach(project.flattened) { item in
                                    Text(item.name)
                                }
                            }
                        }
                    }
                    Stepper(
                        "Estimate: \(issue.points) \(issue.points == 1 ? "point" : "points")",
                        value: tracker.binding(id, \.points, default: 0),
                        in: 0...21
                    )
                    Toggle("Blocked", isOn: tracker.binding(id, \.isBlocked, default: false))
                }
                if showsTitleAndNotes {
                    Section("Notes") {
                        TextEditor(text: tracker.binding(id, \.notes, default: ""))
                            .frame(height: 110)
                    }
                }
                Section {
                    LabeledContent("Created", value: issue.created, format: .dateTime.day().month().year())
                    LabeledContent("Updated", value: tracker.preferences.format(issue.updated))
                } footer: {
                    Text("Every change stamps the issue as updated.")
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Several issues at once: status, priority and assignee for all of them.
@View
struct BulkEditForm {
    let tracker: Tracker
    let ids: Set<Issue.ID>

    var body: some View {
        let tracker = self.tracker
        let ids = self.ids
        let issues = ids.compactMap { tracker.issue($0) }
        Form {
            Section("\(ids.count) Issues Selected") {
                Picker("Status", selection: Binding(
                    get: { common(issues.map(\.status)) },
                    set: { if let status = $0 { tracker.setStatus(status, of: ids) } }
                )) {
                    Text("Mixed").tag(Status?.none)
                    Divider()
                    ForEach(Status.allCases) { status in
                        Text(status.name).tag(Status?.some(status))
                    }
                }
                Picker("Priority", selection: Binding(
                    get: { common(issues.map(\.priority)) },
                    set: { if let priority = $0 { tracker.setPriority(priority, of: ids) } }
                )) {
                    Text("Mixed").tag(Priority?.none)
                    Divider()
                    ForEach(Priority.allCases) { priority in
                        Text(priority.name).tag(Priority?.some(priority))
                    }
                }
                Picker("Assignee", selection: Binding(
                    get: { common(issues.map { $0.assignee?.id ?? 0 }) },
                    set: { id in
                        guard let id else { return }
                        tracker.assign(tracker.people.first { $0.id == id }, to: ids)
                    }
                )) {
                    Text("Mixed").tag(Int?.none)
                    Divider()
                    Text("Unassigned").tag(Int?.some(0))
                    ForEach(tracker.people) { person in
                        Text(person.name).tag(Int?.some(person.id))
                    }
                }
            }
            Section {
                LabeledContent("Estimate", value: "\(issues.map(\.points).reduce(0, +)) points in all")
                LabeledContent("Blocked", value: "\(issues.filter(\.isBlocked).count) of \(issues.count)")
            }
        }
        .formStyle(.grouped)
    }

    /// The one value every issue shares, or `nil` when they differ.
    private func common<V: Equatable>(_ values: [V]) -> V? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// An issue opened full-window: the title large and the notes under it on
/// the left, the rest of its fields as a form on the right.
@View
struct IssueDetail {
    let tracker: Tracker
    let id: Issue.ID
    let close: () -> Void

    var body: some View {
        let tracker = self.tracker
        let id = self.id
        let close = self.close
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button("‹ Issues") { close() }
                if let issue = tracker.issue(id) {
                    Text(issue.key)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.bar)
            Divider()
            if tracker.issue(id) != nil {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Title", text: tracker.binding(id, \.title, default: ""), axis: .vertical)
                            .font(.system(size: 22, weight: .semibold))
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                        Text("Notes")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        TextEditor(text: tracker.binding(id, \.notes, default: ""))
                            .frame(maxHeight: .infinity)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    IssueForm(tracker: tracker, id: id, showsTitleAndNotes: false)
                        .frame(width: 340)
                        .frame(maxHeight: .infinity)
                }
            } else {
                Text("This issue was deleted.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
