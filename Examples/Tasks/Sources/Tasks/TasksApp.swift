//
//  TasksApp.swift
//  Tasks
//
//  A to-do list: filters, a scrolling list of rows that toggle on tap, and
//  a detail screen pushed with NavigationLink that edits the same task
//  through a Binding and can delete it (popping itself via the router).
//
//  There is no text input in the framework yet, so "Add" pulls the next
//  title from a backlog instead of a text field.
//
//  Deleting from the detail screen goes through the same Binding as every
//  other edit: the task is flagged and the list stops showing it. The list
//  stays alive under a pushed screen, so it sees the write immediately —
//  there is no "on return" moment to hook.
//

import NucleantSwiftUI

// MARK: - Model

enum Priority: Int, CaseIterable, Comparable {
    case low, normal, high

    static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

    var name: String {
        switch self {
        case .low:    return "Low"
        case .normal: return "Normal"
        case .high:   return "High"
        }
    }

    var color: Color {
        switch self {
        case .low:    return Color(hex: 0x6C7A89)
        case .normal: return Color(hex: 0x4C8DFF)
        case .high:   return Color(hex: 0xFF5C5C)
        }
    }
}

struct Task: Identifiable, Equatable {
    let id: Int
    var title: String
    var notes: String
    var isDone: Bool
    var priority: Priority
    var isDeleted = false
}

enum Filter: CaseIterable {
    case all, active, done

    var name: String {
        switch self {
        case .all:    return "All"
        case .active: return "Active"
        case .done:   return "Done"
        }
    }
}

let initialTasks: [Task] = [
    Task(id: 1, title: "Write the launch post", notes: "Draft is in the shared doc; needs the numbers from Friday's run.", isDone: false, priority: .high),
    Task(id: 2, title: "Review pull request #42", notes: "The shader-slot pooling change. Check the canvas retarget cost.", isDone: false, priority: .normal),
    Task(id: 3, title: "Book the dentist", notes: "", isDone: true, priority: .low),
    Task(id: 4, title: "Renew the domain", notes: "Expires on the 30th.", isDone: false, priority: .high),
    Task(id: 5, title: "Water the plants", notes: "The fern wants more than the others.", isDone: true, priority: .low),
    Task(id: 6, title: "Plan the offsite", notes: "Three days, somewhere with a whiteboard.", isDone: false, priority: .normal),
]

/// What "Add" pulls from, in order, since there is no keyboard yet.
let backlog = [
    "Fix the flaky test", "Call the accountant", "Order more coffee",
    "Update the roadmap", "Clean the workbench", "Read the Vulkan spec chapter 12",
    "Back up the NAS", "Try the new bakery",
]

/// Surfaces are the framework's semantic colors, so the list follows the
/// system's light or dark appearance; the accents are fixed.
struct Theme {
    static let background = Color.background
    static let panel = Color.secondaryBackground
    static let row = Color.tertiaryBackground
    static let ring = Color.dynamic(light: Color(white: 0, opacity: 0.25), dark: Color(white: 1, opacity: 0.25))
    static let muted = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.3))
    static let accent = Color(hex: 0x4C8DFF)
    static let done = Color(hex: 0x3DD68C)
}

// MARK: - Rows

/// The tick box. A ring when open, a filled disc with a check when done.
@View
struct Checkbox {
    let isDone: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(isDone ? Theme.done : Theme.ring, lineWidth: 2)
            if isDone {
                Circle().fill(Theme.done)
                PathShape { size in
                    // A check mark drawn into the circle's box.
                    var path = Path()
                    path.move(to: Point(x: size.width * 0.28, y: size.height * 0.52))
                    path.addLine(to: Point(x: size.width * 0.44, y: size.height * 0.68))
                    path.addLine(to: Point(x: size.width * 0.73, y: size.height * 0.34))
                    return path
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 22, height: 22)
    }
}

@View
struct TaskRow {
    @Binding var task: Task

    var body: some View {
        HStack(spacing: 12) {
            Checkbox(isDone: task.isDone)
                .onTapGesture { task.isDone.toggle() }

            // The growing part of the row. A `.frame(maxWidth: .infinity)`
            // rather than a Spacer: the stack sizes its fixed children first
            // and hands this one whatever is left, so the title is offered the
            // full remaining width instead of an equal share with a spacer.
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(task.isDone ? .secondary : .primary)
                    .lineLimit(1)
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PriorityDot(priority: task.priority)

            NavigationLink(title: task.title) {
                TaskDetail(task: $task)
            } label: {
                Text("›")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                    .frame(width: 24)
            }
        }
        .padding(horizontal: 14, vertical: 10)
        .background(Theme.row)
        .cornerRadius(10)
        .opacity(task.isDone ? 0.6 : 1)
    }
}

@View
struct PriorityDot {
    let priority: Priority

    var body: some View {
        Circle()
            .fill(priority.color)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Detail

@View
struct TaskDetail {
    @Binding var task: Task
    @Environment(\.navigationRouter) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Checkbox(isDone: task.isDone)
                    .onTapGesture { task.isDone.toggle() }
                Text(task.title)
                    .font(.title2)
                    .foregroundColor(task.isDone ? .secondary : .primary)
            }

            Text(task.notes.isEmpty ? "No notes." : task.notes)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.panel)
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 8) {
                Text("Priority").font(.footnote).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(Priority.allCases, id: \.self) { priority in
                        Button(priority.name) { task.priority = priority }
                            .tint(task.priority == priority ? priority.color : Theme.muted)
                    }
                }
            }

            Spacer()

            Button("Delete task") {
                task.isDeleted = true
                router?.pop()
            }
            .tint(Color(hex: 0xC03A3A))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}

// MARK: - List

@View
struct TaskList {
    @Binding var appearance: Appearance
    @State private var tasks = initialTasks
    @State private var filter = Filter.all
    @State private var nextBacklog = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            filters
            list
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.system(size: 26, weight: .bold))
                Text("\(remaining) of \(live.count) left")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("+ Add") { add() }
                .tint(Theme.accent)
                .disabled(nextBacklog >= backlog.count)
            Button("Clear done") { tasks.removeAll { $0.isDone || $0.isDeleted } }
                .tint(Theme.muted)
        }
    }

    var filters: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases, id: \.self) { f in
                Text(f.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(filter == f ? .white : .secondary)
                    .padding(horizontal: 12, vertical: 6)
                    .background(filter == f ? Theme.accent : Theme.panel)
                    .cornerRadius(14)
                    .onTapGesture { filter = f }
            }
            Spacer()
            AppearancePicker(appearance: $appearance)
        }
    }

    var list: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(visibleIndices, id: \.self) { index in
                    TaskRow(task: $tasks[index])
                }
                if visibleIndices.isEmpty {
                    Text(filter == .done ? "Nothing done yet." : "All clear.")
                        .foregroundColor(.secondary)
                        .padding(30)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    var live: [Task] { tasks.filter { !$0.isDeleted } }
    var remaining: Int { live.filter { !$0.isDone }.count }

    /// Sorted by priority, done ones last; indices into `tasks` so the rows
    /// can bind into the array.
    var visibleIndices: [Int] {
        tasks.indices
            .filter { index in
                if tasks[index].isDeleted { return false }
                switch filter {
                case .all:    return true
                case .active: return !tasks[index].isDone
                case .done:   return tasks[index].isDone
                }
            }
            .sorted { a, b in
                if tasks[a].isDone != tasks[b].isDone { return !tasks[a].isDone }
                return tasks[a].priority > tasks[b].priority
            }
    }

    func add() {
        guard nextBacklog < backlog.count else { return }
        let id = (tasks.map(\.id).max() ?? 0) + 1
        tasks.insert(Task(id: id, title: backlog[nextBacklog], notes: "", isDone: false, priority: .normal), at: 0)
        nextBacklog += 1
    }
}

/// Owns the appearance choice and applies it under itself — navigation
/// bar included.
@View
struct RootView {
    @State private var appearance = Appearance.system
    @Environment(\.colorScheme) private var system

    var body: some View {
        NavigationStack("Tasks") {
            TaskList(appearance: $appearance)
        }
        .background(Theme.background)
        .colorScheme(appearance.scheme ?? system)
    }
}

@main
struct TasksApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Tasks", width: 520, height: 640) {
            RootView()
        }
    }
}
