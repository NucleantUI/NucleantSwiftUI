//
//  MoodboardApp.swift
//  Moodboard
//
//  A moodboard: boards of photos, notes and stickers, arranged by hand.
//
//  * The sidebar lists the boards; the toolbar names the board, writes new
//    notes, adds photos and stickers, locks the photos, zooms and presents.
//  * The board (BoardCanvas.swift) is where the gestures are: drag, pinch,
//    twist, double click, hold — on a trackpad or with two fingers — and
//    the keys.
//  * The inspector edits the selected card.
//
//  Where the keys are is one `@FocusState` for the window: the board, the
//  name and note fields in the toolbar, the inspector's fields. The board
//  takes them at launch; Return in the name or caption field hands them
//  back to it; `n` on the board goes to the note field, where Return pins
//  the note and stays for the next one. Tab walks through them all.
//
//  The swatches overlap, and each takes clicks only inside its circle
//  (`.contentShape(Circle())`) — the corner of one never steals a click
//  meant for the one beside it.
//

import NucleantUI

enum Theme {
    static let sidebar = Color.dynamic(light: Color(hex: 0xEEEEF2), dark: Color(hex: 0x16181D))
    static let bar = Color.dynamic(light: Color(hex: 0xF7F7F9), dark: Color(hex: 0x1B1D23))
    static let canvas = Color.dynamic(light: Color(hex: 0xE4E1DA), dark: Color(hex: 0x2A2A2E))
    static let accent = Color(hex: 0x2F7CF6)
}

/// Where the keys can be.
enum Field: Hashable {
    case board
    case boardName
    case newNote
    case caption
    case noteText
}

@View
struct MoodboardView {
    @State private var studio = Studio()
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var system

    var body: some View {
        let studio = self.studio
        HStack(spacing: 0) {
            BoardList(studio: studio)
                .frame(width: 210)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)
            Divider()
            if let board = studio.current {
                VStack(spacing: 0) {
                    Toolbar(board: board, focus: $focus)
                    Divider()
                    BoardCanvas(board: board, focus: $focus)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let card = board.selectedCard, !board.isPresenting {
                    Divider()
                    Inspector(board: board, card: card, focus: $focus)
                        .frame(width: 270)
                        .frame(maxHeight: .infinity)
                        .background(Theme.bar)
                }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondaryBackground)
        .tint(Theme.accent)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
        .onAppear { focus = .board }
    }
}

@main
struct MoodboardApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Moodboard", width: 1380, height: 860) {
            MoodboardView()
        }
        .commands { AppearanceCommands() }
    }
}

// MARK: - Toolbar

@View
struct Toolbar {
    @Bindable var board: Board
    @FocusState.Binding var focus: Field?
    /// The note being written.
    @State private var draft = ""

    var body: some View {
        let board = self.board
        VStack(alignment: .leading, spacing: 10) {
            // The board, and what is done to all of it.
            HStack(spacing: 10) {
                TextField("Board name", text: $board.name)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($focus, equals: .boardName)
                    .onSubmit { focus = .board }
                    .frame(minWidth: 160, maxWidth: 280)
                Spacer()
                Text("\(Int((board.zoom * 100).rounded()))%")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button("Actual Size") {
                    withAnimation(.snappy) { board.resetZoom() }
                }
                Button(board.isPresenting ? "Stop" : "Present") {
                    if board.isPresenting {
                        board.stopPresenting()
                    } else {
                        board.startPresenting()
                    }
                    focus = .board
                }
            }
            // What goes on it.
            HStack(spacing: 10) {
                TextField("Write a note — Return pins it", text: $draft)
                    .focused($focus, equals: .newNote)
                    .onSubmit {
                        let text = draft
                        guard !text.isEmpty else { return }
                        board.addNote(text)
                        draft = ""
                    }
                    .frame(minWidth: 160, maxWidth: 320)
                Button("Add Photo") {
                    board.addPhoto()
                    focus = .board
                }
                SwatchRow(board: board)
                Spacer()
                Toggle("Lock Photos", isOn: $board.photosLocked)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(Theme.bar)
    }
}

/// The palette as overlapping round swatches. A click recolours the
/// selected note or sticker, or puts a new sticker down.
@View
struct SwatchRow {
    let board: Board

    var body: some View {
        let board = self.board
        HStack(spacing: -7) {
            ForEach(Palette.colors.indices, id: \.self) { index in
                Swatch(color: Palette.colors[index]) {
                    board.applySwatch(Palette.colors[index])
                }
            }
        }
    }
}

@View
struct Swatch {
    let color: Color
    let action: () -> Void

    var body: some View {
        ZStack {
            Circle().fill(color)
            Circle().stroke(Color.white, lineWidth: 2)
        }
        .frame(width: 26, height: 26)
        // The square around the circle is not the swatch: its corners
        // overlap the neighbours, which must still get those clicks.
        .contentShape(Circle())
        .onTapGesture { action() }
    }
}

// MARK: - Sidebar

@View
struct BoardList {
    let studio: Studio

    var body: some View {
        let studio = self.studio
        VStack(spacing: 0) {
            List(selection: Binding(get: { studio.currentID }, set: { studio.currentID = $0 })) {
                Section("Boards") {
                    ForEach(studio.boards) { board in
                        BoardRow(board: board)
                            .tag(board.id)
                            .badge(board.cards.count)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("New Board") { studio.addBoard() }
                Spacer()
            }
            .padding(12)
        }
    }
}

@View
struct BoardRow {
    let board: Board

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.accent)
                .frame(width: 12, height: 12)
            Text(board.name)
                .lineLimit(1)
        }
    }
}

// MARK: - Inspector

/// The selected card: its caption, a note's text, its size and turn, and
/// whether it is pinned.
@View
struct Inspector {
    let board: Board
    let card: Card
    @FocusState.Binding var focus: Field?

    var body: some View {
        let board = self.board
        let id = card.id
        VStack(alignment: .leading, spacing: 12) {
            Text(card.kindName)
                .font(.headline)
            Text("Caption")
                .foregroundColor(.secondary)
            TextField("Caption", text: Binding(
                get: { board.card(id)?.caption ?? "" },
                set: { board.setCaption(id, $0) }
            ))
            .focused($focus, equals: .caption)
            .onSubmit { focus = .board }
            if case .note(let text, _) = card.kind {
                Text("Note")
                    .foregroundColor(.secondary)
                TextField("Note", text: Binding(
                    get: { text },
                    set: { board.setNoteText(id, $0) }
                ), axis: .vertical)
                .lineLimit(2...6)
                .focused($focus, equals: .noteText)
            }
            Text("Size  \(Int((card.scale * 100).rounded()))%")
                .foregroundColor(.secondary)
            Slider(value: Binding(get: { card.scale }, set: { board.setScale(id, $0) }), in: 0.3...4)
            Text("Turn  \(Int(card.rotation.degrees.rounded()))°")
                .foregroundColor(.secondary)
            Slider(value: Binding(get: { card.rotation.degrees }, set: { board.setRotation(id, .degrees($0)) }), in: -180...180)
            Toggle("Pinned in place", isOn: Binding(get: { card.isPinned }, set: { board.setPinned(id, $0) }))
            HStack(spacing: 8) {
                Button("Reset") {
                    withAnimation(.snappy) { board.resetTransform(id) }
                }
                Button("Delete") { board.deleteSelection() }
            }
            Spacer()
        }
        .padding(16)
    }
}
