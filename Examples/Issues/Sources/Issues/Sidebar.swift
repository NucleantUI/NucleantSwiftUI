//
//  Sidebar.swift
//  Issues
//
//  The sidebar: a `List` in `.sidebar` style, its selection the `Scope` the
//  rest of the window shows. The issue views are tagged rows with counts
//  as `.badge`s; the projects are an `OutlineGroup` over the project tree,
//  each row tagged with its project's scope. Each section collapses from
//  the chevron its header shows under the pointer.
//

import NucleantUI

@View
struct Sidebar {
    let tracker: Tracker
    @Binding var scope: Scope?

    var body: some View {
        let tracker = self.tracker
        let badges = tracker.preferences.showsBadges
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.accent)
                    Text("N")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 22, height: 22)
                Text("Nucleant")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Avatar(person: tracker.preferences.me, size: 22)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)

            List(selection: $scope) {
                Section("Issues") {
                    SidebarRow(title: "All Issues") { AllIssuesGlyph() }
                        .tag(Scope.all)
                        .badge(badges ? tracker.count(in: .all) : 0)
                    SidebarRow(title: "My Issues") { Avatar(person: tracker.preferences.me, size: 14) }
                        .tag(Scope.mine)
                        .badge(badges ? tracker.count(in: .mine) : 0)
                    SidebarRow(title: "Open") { StatusGlyph(status: .todo) }
                        .tag(Scope.open)
                        .badge(badges ? tracker.count(in: .open) : 0)
                    SidebarRow(title: "Closed") { StatusGlyph(status: .done) }
                        .tag(Scope.closed)
                }
                Section("Projects") {
                    OutlineGroup(tracker.projects, children: \.subprojects) { project in
                        SidebarRow(title: project.name) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(project.color)
                                .frame(width: 11, height: 11)
                        }
                        .tag(Scope.project(project.id))
                        .badge(badges ? tracker.count(in: .project(project.id)) : 0)
                    }
                }
                Section("App") {
                    SidebarRow(title: "Settings") { SettingsGlyph() }
                        .tag(Scope.settings)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

/// A sidebar row: a 16-point glyph and a title.
@View
struct SidebarRow<Glyph: View> {
    let title: String
    let glyph: Glyph

    init(title: String, _viewID: ViewID = #viewID, @ViewBuilder glyph: () -> Glyph) {
        self.title = title
        self.glyph = glyph()
        self._viewID = _viewID
    }

    var body: some View {
        HStack(spacing: 8) {
            glyph
                .frame(width: 16, height: 16)
            Text(title)
                .lineLimit(1)
        }
    }
}

/// Two cards, one behind the other.
@View
struct AllIssuesGlyph {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(Color.secondary, lineWidth: 1.3)
                .frame(width: 9, height: 9)
                .offset(x: 4, y: 0)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary)
                .frame(width: 9, height: 9)
                .offset(x: 0, y: 4)
        }
        .frame(width: 13, height: 13, alignment: .topLeading)
    }
}

/// A ring with a dot — a dial.
@View
struct SettingsGlyph {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary, lineWidth: 1.5)
            Circle()
                .fill(Color.secondary)
                .frame(width: 4, height: 4)
        }
        .frame(width: 12, height: 12)
    }
}
