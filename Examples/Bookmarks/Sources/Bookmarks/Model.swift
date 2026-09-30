//
//  Model.swift
//  Bookmarks
//
//  The library: bookmarks, each with tags, read and favourite flags, and
//  notes. `Library` is the `@Observable` model, changed only through its
//  methods; a `Bookmark` is a record inside it.
//

import Foundation
import NucleantUI
import Observation

/// One saved page.
struct Bookmark: Identifiable, Equatable {
    let id: Int
    var title: String
    var url: String
    var summary: String
    var tags: [String]
    var isRead = false
    var isFavorite = false
    /// Shown as a wide card, two columns across.
    var isFeatured = false
    var notes = ""
    /// The article's length, for the reading time.
    var wordCount: Int
    let added: Date

    /// The site, without scheme, `www.` or path.
    var host: String {
        var rest = url
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if rest.hasPrefix("www.") { rest.removeFirst(4) }
        return String(rest.prefix { $0 != "/" })
    }

    /// Minutes to read, at 230 words a minute.
    var readingMinutes: Int { max(1, Int((Double(wordCount) / 230).rounded())) }

    /// The site's colour, the same every run for the same site.
    var siteColor: Color {
        let palette: [UInt32] = [0x5E6AD2, 0xE5484D, 0x30A46C, 0xF76B15, 0x8E4EC6, 0x0090FF, 0xD6409F, 0x12A594, 0xAD7F58, 0x3E63DD]
        let sum = host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hex: palette[sum % palette.count])
    }

    /// The site's first letter, for its badge.
    var initial: String { host.first.map { String($0).uppercased() } ?? "?" }
}

/// A tag, and how many bookmarks carry it.
struct TagCount: Identifiable, Hashable {
    let name: String
    let count: Int

    var id: String { name }
}

/// What the shelf shows.
enum Scope: Hashable {
    case all
    case unread
    case favorites
    case tag(String)

    var title: String {
        switch self {
        case .all:           return "All Bookmarks"
        case .unread:        return "Unread"
        case .favorites:     return "Favorites"
        case .tag(let name): return "#\(name)"
        }
    }
}

@MainActor
@Observable
final class Library {
    private(set) var bookmarks: [Bookmark]
    private var nextID: Int

    init() {
        let seeded = Library.seed()
        bookmarks = seeded
        nextID = (seeded.map(\.id).max() ?? 0) + 1
    }

    func bookmark(_ id: Bookmark.ID) -> Bookmark? {
        bookmarks.first { $0.id == id }
    }

    /// The bookmarks in `scope` whose title, site, summary or tags contain
    /// `query`, newest first.
    func bookmarks(in scope: Scope, matching query: String = "") -> [Bookmark] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        return bookmarks
            .filter { bookmark in
                switch scope {
                case .all:           return true
                case .unread:        return !bookmark.isRead
                case .favorites:     return bookmark.isFavorite
                case .tag(let name): return bookmark.tags.contains(name)
                }
            }
            .filter { bookmark in
                query.isEmpty
                    || bookmark.title.lowercased().contains(query)
                    || bookmark.host.lowercased().contains(query)
                    || bookmark.summary.lowercased().contains(query)
                    || bookmark.tags.contains { $0.contains(query) }
            }
            .sorted { $0.added > $1.added }
    }

    func count(in scope: Scope) -> Int {
        bookmarks(in: scope).count
    }

    /// Every tag in use, with how many bookmarks carry it, by name.
    var tags: [TagCount] {
        var counts: [String: Int] = [:]
        for bookmark in bookmarks {
            for tag in bookmark.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { TagCount(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }

    // MARK: - Changes

    /// Saves `address` as a new, unread bookmark titled after its site.
    /// Returns its id, or `nil` when `address` doesn't look like a URL.
    @discardableResult
    func add(_ address: String) -> Bookmark.ID? {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("."), !address.contains(" ") else { return nil }
        if !address.contains("://") { address = "https://" + address }
        var bookmark = Bookmark(
            id: nextID,
            title: "",
            url: address,
            summary: "Saved just now. Add a summary in the notes, or tag it so it turns up where you look for it.",
            tags: [],
            wordCount: 1200,
            added: Date()
        )
        bookmark.title = bookmark.host
        nextID += 1
        bookmarks.append(bookmark)
        return bookmark.id
    }

    func delete(_ id: Bookmark.ID) {
        bookmarks.removeAll { $0.id == id }
    }

    func toggleRead(_ id: Bookmark.ID) {
        update(id) { $0.isRead.toggle() }
    }

    func toggleFavorite(_ id: Bookmark.ID) {
        update(id) { $0.isFavorite.toggle() }
    }

    func toggleFeatured(_ id: Bookmark.ID) {
        update(id) { $0.isFeatured.toggle() }
    }

    func addTag(_ tag: String, to id: Bookmark.ID) {
        let tag = tag.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
        guard !tag.isEmpty else { return }
        update(id) { bookmark in
            if !bookmark.tags.contains(tag) { bookmark.tags.append(tag) }
        }
    }

    func removeTag(_ tag: String, from id: Bookmark.ID) {
        update(id) { $0.tags.removeAll { $0 == tag } }
    }

    /// A binding to one field of one bookmark, for the inspector's controls.
    func binding<Value>(_ id: Bookmark.ID, _ field: WritableKeyPath<Bookmark, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { [weak self] in self?.bookmark(id)?[keyPath: field] ?? fallback },
            set: { [weak self] value in self?.update(id) { $0[keyPath: field] = value } }
        )
    }

    private func update(_ id: Bookmark.ID, _ change: (inout Bookmark) -> Void) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        change(&bookmarks[index])
    }

    // MARK: - Seed

    private static func seed() -> [Bookmark] {
        let entries: [(String, String, String, [String], Int, Bool, Bool, Bool)] = [
            ("Local-first software", "https://www.inkandswitch.com/local-first/",
             "Why the apps we build should keep working offline, keep the user's data on the user's device, and still collaborate in real time — and what CRDTs can and can't do about it yet. Seven ideals, measured against the tools people use today.",
             ["essays", "databases", "sync"], 11000, false, true, true),
            ("Swift concurrency: behind the scenes", "https://developer.apple.com/videos/play/wwdc2021/10254/",
             "How the cooperative thread pool avoids thread explosion, what a continuation costs, and why actors hop.",
             ["swift", "concurrency"], 3200, true, false, false),
            ("Out of the Tar Pit", "https://curtclifton.net/papers/MoseleyMarks06a.pdf",
             "Complexity is the root of most software trouble, and most of it is accidental: state and control flow nobody needed. A long argument for functional relational programming.",
             ["essays", "research"], 17000, false, true, false),
            ("Designing a Vulkan renderer that doesn't fight you", "https://vkguide.dev/docs/new_chapter_1/",
             "Frames in flight, per-frame resources and one big command buffer.",
             ["graphics", "vulkan"], 5400, false, false, false),
            ("The Rust borrow checker, explained with pictures", "https://blog.logrocket.com/rust-borrow-checker/",
             "Ownership, borrows and lifetimes drawn as boxes and arrows until they stop being mysterious. Ends with the three errors everyone meets in the first week, and what each one is really telling you.",
             ["rust"], 4100, true, false, false),
            ("Practical typography: line length", "https://practicaltypography.com/line-length.html",
             "Forty-five to ninety characters.",
             ["typography", "design"], 900, false, false, false),
            ("Things you should never do, part I", "https://www.joelonsoftware.com/2000/04/06/things-you-should-never-do-part-i/",
             "Rewriting from scratch throws away years of bug fixes nobody remembers making. Netscape did it and lost the browser war while the rewrite shipped.",
             ["essays"], 2200, true, true, false),
            ("How SQLite is tested", "https://www.sqlite.org/testing.html",
             "Six hundred times more test code than library code, out-of-memory and I/O fault injection, fuzzing, and 100% branch coverage — the reason it runs on every phone on earth without anyone worrying about it.",
             ["databases", "testing"], 6800, false, false, true),
            ("A Swift tour of Observation", "https://www.swift.org/blog/observation/",
             "What @Observable expands to, and how withObservationTracking decides what changed.",
             ["swift", "ui"], 2600, false, false, false),
            ("Real-time audio programming 101: time waits for nothing", "http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing",
             "No locks, no allocation, no file or network I/O on the audio thread. Why each of them can take longer than a buffer lasts, and what to do instead: lock-free queues, preallocated pools, and a lot of discipline.",
             ["audio", "performance", "concurrency"], 3900, false, true, false),
            ("ThorVG: a lightweight vector graphics engine", "https://www.thorvg.org/about",
             "Shapes, gradients, text and Lottie on a tiny footprint, with CPU, OpenGL and WebGPU backends.",
             ["graphics", "tools"], 1500, true, false, false),
            ("Crafting Interpreters", "https://craftinginterpreters.com/",
             "A tree-walking interpreter in Java, then a bytecode VM in C, for the same small language.",
             ["books", "compilers"], 90000, false, true, true),
            ("The Pragmatic Programmer's tracer bullets", "https://pragprog.com/titles/tpp20/",
             "Build a thin end-to-end path first.",
             ["essays", "tools"], 800, true, false, false),
            ("Laws of UX", "https://lawsofux.com/",
             "Fitts's law, Hick's law, Jakob's law and the rest, one page each, with the research behind them and what they mean for a real interface.",
             ["design", "ui"], 3000, false, false, false),
            ("What every programmer should know about memory", "https://people.freebsd.org/~lstewart/articles/cpumemory.pdf",
             "Caches, TLBs, NUMA and prefetching in more depth than you'll ever need, until the day a profile says you do. The chapter on what programmers can do is the one to read first.",
             ["performance", "research"], 52000, false, false, false),
            ("Figma's multiplayer technology", "https://www.figma.com/blog/how-figmas-multiplayer-technology-works/",
             "Not quite CRDTs: a central server, last-writer-wins per property, and fractional indexing for order.",
             ["sync", "design"], 3600, true, false, false),
            ("SwiftUI's Layout protocol", "https://developer.apple.com/documentation/swiftui/layout",
             "sizeThatFits and placeSubviews, a cache, and layout values.",
             ["swift", "ui"], 2000, false, false, false),
            ("Rust atomics and locks", "https://marabos.nl/atomics/",
             "Memory ordering from first principles: what Relaxed, Acquire, Release and SeqCst actually promise, then building a spin lock, channels, Arc and a condition variable from scratch.",
             ["rust", "concurrency", "books"], 70000, false, false, false),
            ("Butterick's line spacing", "https://practicaltypography.com/line-spacing.html",
             "120–145% of the point size.",
             ["typography"], 600, true, false, false),
            ("Lottie and the case for animation as data", "https://airbnb.design/introducing-lottie/",
             "Designers export After Effects animations as JSON and engineers play them natively, at any size, without redrawing a frame by hand.",
             ["design", "graphics"], 1400, false, false, false),
            ("Postgres: the good parts", "https://www.crunchydata.com/blog/postgres-the-good-parts",
             "JSONB, partial indexes, generated columns, and LISTEN/NOTIFY.",
             ["databases"], 2400, false, false, false),
            ("How to write a good commit message", "https://cbea.ms/git-commit/",
             "Seven rules: a short imperative subject, a blank line, and a body that says why.",
             ["tools"], 1900, true, false, false),
            ("Physically based rendering, in brief", "https://learnopengl.com/PBR/Theory",
             "Microfacets, energy conservation, and the Cook-Torrance BRDF — what each term does to a highlight, with the GLSL for it and pictures of spheres at every roughness from mirror to chalk.",
             ["graphics"], 5200, false, true, false),
            ("The Elm architecture", "https://guide.elm-lang.org/architecture/",
             "Model, view, update.",
             ["ui", "essays"], 1100, false, false, false),
            ("Oboe: low-latency audio on Android", "https://github.com/google/oboe",
             "AAudio where it exists, OpenSL ES where it doesn't, and one C++ API over both.",
             ["audio", "tools"], 1300, false, false, false),
            ("Simple made easy", "https://www.infoq.com/presentations/Simple-Made-Easy/",
             "Simple means one fold, not few parts; easy means near at hand. We keep choosing easy and paying for the complexity later, and the talk is an hour on how to stop.",
             ["essays"], 7000, true, true, false),
            ("A guide to Swift macros", "https://www.swift.org/documentation/macros/",
             "Freestanding and attached macros, and testing their expansions.",
             ["swift", "compilers"], 4500, false, false, false),
            ("Color spaces for UI people", "https://ciechanow.ski/color-spaces/",
             "Why sRGB isn't linear, what a gamut is, and how Display P3 fits.",
             ["design", "graphics"], 9000, false, true, false),
            ("Gamedev: fix your timestep", "https://gafferongames.com/post/fix_your_timestep/",
             "Integrate physics at a fixed step, render at whatever rate you get, and interpolate between the two states so motion stays smooth.",
             ["graphics", "performance"], 2300, true, false, false),
            ("Understanding CRDTs", "https://crdt.tech/",
             "Papers, implementations and talks, in one place.",
             ["sync", "research"], 1000, false, false, false),
        ]
        let now = Date()
        return entries.enumerated().map { index, entry in
            Bookmark(
                id: index + 1,
                title: entry.0,
                url: entry.1,
                summary: entry.2,
                tags: entry.3,
                isRead: entry.5,
                isFavorite: entry.6,
                isFeatured: entry.7,
                wordCount: entry.4,
                // Two or three a day, going back.
                added: now.addingTimeInterval(-Double(index) * 9.5 * 3600)
            )
        }
    }
}
