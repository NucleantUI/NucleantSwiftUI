//
//  Model.swift
//  Finder
//
//  The file tree as `@Observable` classes the views read directly. A row
//  that reads `node.name`, `node.size` or `node.children` in its body is
//  rebuilt when that property changes — from a toolbar button, or from
//  the download timer below, which writes to a node no view asked it to.
//  A folder's open/closed state lives on its node too, so a
//  `DisclosureGroup` binds straight to `$node.isExpanded`.
//

import Foundation
import Observation
import NucleantUI

// MARK: - Nodes

enum FileKind: Equatable {
    case folder, application, swift, markdown, image, pdf, audio, archive, text, font

    var name: String {
        switch self {
        case .folder:      return "Folder"
        case .application: return "Application"
        case .swift:       return "Swift Source"
        case .markdown:    return "Markdown"
        case .image:       return "PNG image"
        case .pdf:         return "PDF Document"
        case .audio:       return "WAVE audio"
        case .archive:     return "Archive"
        case .text:        return "Plain Text"
        case .font:        return "Font"
        }
    }

    /// The band across the bottom of a document icon, or an app's tile.
    var color: Color {
        switch self {
        case .folder:      return Theme.folder
        case .application: return Color(hex: 0x5E5CE6)
        case .swift:       return Color(hex: 0xF05138)
        case .markdown:    return Color(hex: 0x6C7A89)
        case .image:       return Color(hex: 0x34C759)
        case .pdf:         return Color(hex: 0xE5484D)
        case .audio:       return Color(hex: 0xFF2D55)
        case .archive:     return Color(hex: 0xA2845E)
        case .text:        return Color(hex: 0x8E8E93)
        case .font:        return Color(hex: 0x30B0C7)
        }
    }
}

/// Finder's colour tags, set from a row's context menu.
enum Tag: CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple

    var id: Self { self }

    var name: String {
        switch self {
        case .red:    return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .blue:   return "Blue"
        case .purple: return "Purple"
        }
    }

    var color: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        }
    }
}

/// A file or a folder. Everything a row shows is a stored property, so
/// observation tracks each one on its own: the download growing touches
/// `size` and `progress` on one node, and only that row rebuilds.
@MainActor
@Observable
final class FileNode: Identifiable {
    /// Stable across renames and moves, which a path is not.
    let id: Int
    var name: String
    var kind: FileKind
    var modified: String
    /// Bytes; `nil` for a folder, which Finder shows as "--".
    var size: Int?
    /// `nil` for a file. An empty folder is `[]` and still discloses.
    private(set) var children: [FileNode]?
    /// Whether this folder is open in the list.
    var isExpanded = false
    /// 0…1 while downloading, `nil` once it is a whole file.
    var progress: Double?
    var tag: Tag?
    /// The folders Finder will not move to the Trash.
    let isLocked: Bool

    @ObservationIgnored private(set) weak var parent: FileNode?

    private static var nextID = 0

    init(
        name: String,
        kind: FileKind,
        modified: String,
        size: Int? = nil,
        children: [FileNode]? = nil,
        isLocked: Bool = false
    ) {
        self.id = FileNode.nextID
        FileNode.nextID += 1
        self.name = name
        self.kind = kind
        self.modified = modified
        self.size = size
        self.children = children.map(FileNode.sorted)
        self.isLocked = isLocked
        for child in children ?? [] { child.parent = self }
    }

    var isFolder: Bool { children != nil }

    /// Adds `child` in name order, as Finder lists it.
    func insert(_ child: FileNode) {
        guard let children else { return }
        child.parent = self
        self.children = FileNode.sorted(children + [child])
    }

    /// Takes this node out of its folder.
    func removeFromParent() {
        parent?.children?.removeAll { $0 === self }
        parent = nil
    }

    /// This node, or the one below it with `id`.
    func find(_ id: Int) -> FileNode? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let found = child.find(id) { return found }
        }
        return nil
    }

    /// Opens or closes this folder and every folder in it.
    func setExpanded(_ expanded: Bool) {
        guard let children else { return }
        isExpanded = expanded
        for child in children { child.setExpanded(expanded) }
    }

    /// "untitled folder", then "untitled folder 2", 3… — the first free.
    func freeName(_ base: String) -> String {
        let taken = Set((children ?? []).map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A copy of this node and everything in it, named `name`.
    func copy(named name: String) -> FileNode {
        let copy = FileNode(
            name: name,
            kind: kind,
            modified: todayStamp(),
            size: size,
            children: children?.map { $0.copy(named: $0.name) }
        )
        copy.tag = tag
        return copy
    }

    private static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
func folder(_ name: String, _ modified: String, locked: Bool = false, _ children: [FileNode] = []) -> FileNode {
    FileNode(name: name, kind: .folder, modified: modified, children: children, isLocked: locked)
}

@MainActor
func file(_ name: String, _ kind: FileKind, _ size: Int, _ modified: String) -> FileNode {
    FileNode(name: name, kind: kind, modified: modified, size: size)
}

/// "Today at 9:41 AM" for now.
func todayStamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return "Today at " + formatter.string(from: Date())
}

// MARK: - The disk

/// The one disk, with handles on the folders the sidebar shows.
@MainActor
@Observable
final class FileSystem {
    static let shared = FileSystem()

    let root: FileNode
    let applications: FileNode
    let home: FileNode
    let desktop: FileNode
    let documents: FileNode
    let downloads: FileNode
    let iCloudDrive: FileNode
    let shared: FileNode

    /// Free space, shown in the status bar; the download eats into it.
    var available = 341_060_000_000

    init() {
        applications = folder("Applications", "Today at 7:03 AM", locked: true, [
            file("Calculator.app", .application, 6_214_880, "Mar 6, 2025 at 2:06 AM"),
            file("Finder.app", .application, 38_110_004, "Mar 6, 2025 at 2:06 AM"),
            file("Pomodoro.app", .application, 4_402_118, "Today at 7:03 AM"),
            folder("Utilities", "Mar 13, 2025 at 1:08 AM", [
                file("Terminal.app", .application, 10_882_310, "Mar 6, 2025 at 2:06 AM"),
                file("Disk Utility.app", .application, 8_541_207, "Mar 6, 2025 at 2:06 AM"),
            ]),
        ])
        desktop = folder("Desktop", "Today at 9:12 AM", locked: true, [
            file("Screenshot.png", .image, 1_204_870, "Today at 9:12 AM"),
            file("notes.txt", .text, 1_204, "Yesterday at 8:12 AM"),
        ])
        documents = folder("Documents", "Today at 9:41 AM", locked: true, [
            folder("NucleantUI", "Today at 9:41 AM", [
                file("Package.swift", .swift, 6_214, "Yesterday at 10:10 PM"),
                file("README.md", .markdown, 14_880, "Today at 9:41 AM"),
                folder("Sources", "Today at 9:30 AM", [
                    folder("Views", "Today at 9:30 AM", [
                        file("Button.swift", .swift, 9_120, "Sep 20, 2026 at 2:02 PM"),
                        file("DisclosureGroup.swift", .swift, 11_406, "Today at 9:30 AM"),
                        file("ForEach.swift", .swift, 3_318, "Sep 18, 2026 at 5:47 PM"),
                        file("Text.swift", .swift, 8_764, "Sep 15, 2026 at 8:59 AM"),
                    ]),
                    folder("Layout", "Sep 25, 2026 at 7:03 PM", [
                        file("Stacks.swift", .swift, 15_302, "Sep 25, 2026 at 7:03 PM"),
                    ]),
                ]),
                folder("Build", "Yesterday at 10:14 PM"),
            ]),
            folder("Invoices", "Aug 30, 2026 at 10:02 AM", [
                file("2026-07.pdf", .pdf, 88_412, "Aug 3, 2026 at 9:15 AM"),
                file("2026-08.pdf", .pdf, 91_207, "Aug 30, 2026 at 10:02 AM"),
            ]),
            file("Setlist.pdf", .pdf, 212_774, "Sep 5, 2026 at 5:40 PM"),
        ])
        downloads = folder("Downloads", "Yesterday at 11:15 PM", locked: true, [
            file("drums-backup.zip", .archive, 48_332_190, "Yesterday at 11:15 PM"),
            file("vinyl-crackle.wav", .audio, 5_120_344, "Sep 7, 2026 at 11:02 PM"),
            file("manual.pdf", .pdf, 3_874_120, "Sep 2, 2026 at 3:30 PM"),
        ])
        iCloudDrive = folder("iCloud Drive", "Sep 26, 2026 at 6:45 PM", locked: true, [
            file("Budget.pdf", .pdf, 120_553, "Sep 26, 2026 at 6:45 PM"),
        ])
        home = folder("codebuilder", "Today at 9:41 AM", locked: true, [
            desktop, documents, downloads, iCloudDrive,
            folder("Music", "Sep 8, 2026 at 8:31 PM", locked: true, [
                folder("Samples", "Sep 8, 2026 at 8:31 PM", [
                    file("kick-808.wav", .audio, 402_118, "Sep 8, 2026 at 8:31 PM"),
                    file("snare-tight.wav", .audio, 288_560, "Sep 8, 2026 at 8:30 PM"),
                ]),
            ]),
        ])
        shared = folder("Shared", "Mar 13, 2025 at 1:08 AM", locked: true)
        root = FileNode(name: "Macintosh HD", kind: .folder, modified: "", children: [
            applications,
            folder("Library", "Mar 13, 2025 at 1:08 AM", locked: true, [
                folder("Fonts", "Mar 13, 2025 at 1:08 AM", [
                    file("Inter.ttf", .font, 804_332, "Feb 2, 2025 at 4:12 PM"),
                    file("JetBrainsMono.ttf", .font, 273_900, "Feb 2, 2025 at 4:12 PM"),
                ]),
                folder("Audio", "Mar 13, 2025 at 1:08 AM", [
                    folder("Sounds", "Mar 13, 2025 at 1:08 AM", [
                        file("Chime.wav", .audio, 188_560, "Mar 13, 2025 at 1:08 AM"),
                    ]),
                ]),
                folder("Caches", "Today at 6:58 AM"),
            ]),
            folder("System", "Mar 6, 2025 at 2:06 AM", locked: true, [
                folder("Library", "Mar 6, 2025 at 2:06 AM", [
                    folder("CoreServices", "Mar 6, 2025 at 2:06 AM", [
                        file("SystemVersion.plist", .text, 478, "Mar 6, 2025 at 2:06 AM"),
                    ]),
                ]),
            ]),
            folder("Users", "Mar 13, 2025 at 1:08 AM", locked: true, [home, shared]),
        ], isLocked: true)
    }

    // MARK: Edits

    /// A new empty folder in `parent`, opened so it shows.
    @discardableResult
    func newFolder(in parent: FileNode) -> FileNode {
        let node = folder(parent.freeName("untitled folder"), todayStamp())
        parent.insert(node)
        parent.isExpanded = true
        return node
    }

    /// "notes.txt" → "notes copy.txt", next to the original.
    @discardableResult
    func duplicate(_ node: FileNode) -> FileNode? {
        guard let parent = node.parent, node.progress == nil else { return nil }
        let name = node.name
        let dot = node.isFolder ? nil : name.lastIndex(of: ".")
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        var candidate = "\(stem) copy\(ext)"
        var n = 2
        let taken = Set((parent.children ?? []).map(\.name))
        while taken.contains(candidate) {
            candidate = "\(stem) copy \(n)\(ext)"
            n += 1
        }
        let copy = node.copy(named: candidate)
        parent.insert(copy)
        available -= totalSize(copy)
        return copy
    }

    func moveToTrash(_ node: FileNode) {
        guard !node.isLocked else { return }
        available += node.progress == nil ? totalSize(node) : 0
        node.removeFromParent()
    }

    private func totalSize(_ node: FileNode) -> Int {
        (node.size ?? 0) + (node.children ?? []).reduce(0) { $0 + totalSize($1) }
    }

    // MARK: A download in progress

    /// A file that fills in over a minute — written from a timer, not a
    /// view, to show that any change to a node reaches the rows showing it.
    @ObservationIgnored private var download: FileNode?
    private let downloadTotal = 3_120_000_000

    func startDownload() {
        guard download == nil else { return }
        let node = FileNode(name: "Xcode_27.xip", kind: .archive, modified: todayStamp(), size: 0)
        node.progress = 0
        downloads.insert(node)
        download = node
        Ticker.shared.start(every: 0.25) { [weak self] in self?.stepDownload() }
    }

    private func stepDownload() {
        guard let node = download, let progress = node.progress else { return }
        let next = min(1, progress + 0.25 / 60)
        let step = Int(Double(downloadTotal) * (next - progress))
        node.progress = next < 1 ? next : nil
        node.size = (node.size ?? 0) + step
        available -= step
        if next >= 1 {
            node.modified = todayStamp()
            Ticker.shared.stop()
        }
    }
}

/// One main-run-loop timer, the way Pomodoro ticks.
@MainActor
final class Ticker {
    static let shared = Ticker()
    private var timer: Timer?
    private var onTick: @MainActor () -> Void = {}

    func start(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        onTick = tick
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            // The main run loop fires this on the main thread.
            MainActor.assumeIsolated { Ticker.shared.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Finder's size column: decimal units, "--" for a folder.
func formattedSize(_ bytes: Int?) -> String {
    guard let bytes else { return "--" }
    if bytes < 1_000 { return "\(bytes) bytes" }
    if bytes < 1_000_000 { return "\((bytes + 500) / 1_000) KB" }
    let tenths = (bytes + 50_000) / 100_000
    if tenths < 10_000 { return "\(tenths / 10).\(tenths % 10) MB" }
    let hundredths = (bytes + 5_000_000) / 10_000_000
    let fraction = hundredths % 100
    return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction) GB"
}

/// The rows `node` takes up: itself, plus its children's while it is open.
@MainActor
func visibleRowCount(_ node: FileNode) -> Int {
    guard let children = node.children, node.isExpanded else { return 1 }
    return 1 + children.reduce(0) { $0 + visibleRowCount($1) }
}
