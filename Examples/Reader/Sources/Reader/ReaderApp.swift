//
//  ReaderApp.swift
//  Reader
//
//  An e-book reader: a library, a page for each book, and the reading
//  screen. Its one `NavigationStack` shows its bar where a bar helps and
//  hides it where it would be in the way:
//
//  * The library has the bar: "Library" over a Continue Reading card and
//    the shelf.
//  * A book's page hides it for good — `.toolbar(.hidden, for:
//    .navigationBar)` — so the cover's colour runs to the top of the
//    window. The page draws its own header, and its own "‹ Library" control
//    in place of the bar's Back button, popping through `navigationRouter`.
//  * The reading screen has the bar, titled with the chapter, and controls
//    under the page: previous / next chapter and the text size. A tap on
//    the page hides both — `.toolbarVisibility(isImmersive ? .hidden :
//    .visible, for: .navigationBar)` — and the page takes the whole window;
//    another tap brings them back.
//
//  Each screen keeps its own setting: Back from the reading screen to the
//  book's page hides the bar again, Back from there shows it.
//

import NucleantUI

enum Theme {
    static let shelf = Color.dynamic(light: Color(hex: 0xF3EFE7), dark: Color(hex: 0x141518))
    static let card = Color.dynamic(light: Color.white, dark: Color(hex: 0x212329))
    static let page = Color.dynamic(light: Color(hex: 0xFBF7EF), dark: Color(hex: 0x1B1B1E))
    static let ink = Color.dynamic(light: Color(hex: 0x2A2621), dark: Color(hex: 0xDCD6CB))
    static let faint = Color.dynamic(light: Color(white: 0, opacity: 0.42), dark: Color(white: 1, opacity: 0.4))
    static let track = Color.dynamic(light: Color(white: 0, opacity: 0.1), dark: Color(white: 1, opacity: 0.12))
    static let accent = Color(hex: 0xB4532A)
    static let control = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.32))
}

/// A book's cover, drawn: a shaded field, the title, a rule, the author.
@View
struct Cover {
    let book: Book
    /// It is half as tall again.
    let width: Double

    var body: some View {
        let scale = width / 100
        ZStack {
            Rectangle()
                .fill(.linearGradient(colors: [book.cover, book.coverShade], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 8 * scale) {
                Text(book.title)
                    .font(.system(size: 13 * scale, weight: .bold, design: .serif))
                    .foregroundColor(book.coverInk)
                    .multilineTextAlignment(.center)
                Rectangle()
                    .fill(book.coverInk.opacity(0.6))
                    .frame(width: 28 * scale, height: max(1, scale))
                Text(book.author.uppercased())
                    .font(.system(size: 7 * scale, weight: .medium))
                    .foregroundColor(book.coverInk.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .padding(10 * scale)
        }
        .frame(width: width, height: width * 1.5)
        .cornerRadius(3 * scale)
    }
}

/// A book's chapters as segments: those read, the one open, those to come.
@View
struct ChapterProgress {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count) { index in
                Rectangle()
                    .fill(index < current ? Theme.accent : index == current ? Theme.accent.opacity(0.45) : Theme.track)
                    .frame(height: 4)
                    .cornerRadius(2)
            }
        }
    }
}

/// Owns the library and applies the chosen appearance under itself — the
/// navigation bar included.
@View
struct RootView {
    @State private var library = Library()
    @Environment(\.colorScheme) private var system

    var body: some View {
        NavigationStack("Library") {
            LibraryScreen(library: library)
        }
        .background(Theme.shelf)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }
}

@main
struct ReaderApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Reader", width: 560, height: 760) {
            RootView()
        }
        .commands { AppearanceCommands() }
    }
}
