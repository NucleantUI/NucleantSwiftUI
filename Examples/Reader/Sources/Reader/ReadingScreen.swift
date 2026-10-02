//
//  ReadingScreen.swift
//  Reader
//
//  A chapter on a page, the bar above it titled with the chapter and the
//  controls below it. A tap on the page hides the bar and the controls and
//  gives the page the whole window; another tap brings them back. The
//  chapter on screen is the one the route named until the reader turns to
//  another — that is this screen's own state; where the book was left is
//  the library's.
//

import NucleantUI

@View
struct ReadingScreen {
    let library: Library
    let book: Book
    /// The chapter the screen was pushed to open.
    let opened: Int
    /// The chapter turned to with the controls, once there is one.
    @State private var turnedTo: Int? = nil
    /// The page alone: no bar above it, no controls below.
    @State private var isImmersive = false
    @Environment(\.navigationRouter) private var router

    var chapter: Int { turnedTo ?? opened }

    var body: some View {
        VStack(spacing: 0) {
            // One element, keyed by the chapter: turning to another chapter
            // is a new scroll view, starting at its top.
            ForEach([chapter], id: \.self) { index in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ChapterPage(book: book, index: index, textSize: library.textSize)
                            .onTapGesture { isImmersive.toggle() }
                        endOfChapter(index)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isImmersive {
                Text("\(book.title) · \(chapter + 1) of \(book.chapters.count)")
                    .font(.caption)
                    .foregroundColor(Theme.faint)
                    .lineLimit(1)
                    .padding(horizontal: 16, vertical: 10)
            } else {
                controls
            }
        }
        .background(Theme.page)
        .navigationTitle(book.name(ofChapter: chapter))
        .toolbarVisibility(isImmersive ? .hidden : .visible, for: .navigationBar)
        .onAppear { library.read(book, at: chapter) }
    }

    /// Under the page: the previous and next chapter, the text size.
    var controls: some View {
        HStack(spacing: 8) {
            Button("‹ Previous") { turn(to: chapter - 1) }
                .tint(Theme.accent)
                .disabled(chapter == 0)

            VStack(spacing: 1) {
                Text("Chapter \(chapter + 1) of \(book.chapters.count)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("Tap the page to hide")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.faint)
            }
            .frame(maxWidth: .infinity)

            Button("A−") { library.shrinkText() }
                .tint(Theme.control)
                .disabled(!library.canShrinkText)
            Button("A+") { library.enlargeText() }
                .tint(Theme.control)
                .disabled(!library.canEnlargeText)

            Button("Next ›") { turn(to: chapter + 1) }
                .tint(Theme.accent)
                .disabled(chapter == book.chapters.count - 1)
        }
        .padding(horizontal: 12, vertical: 0)
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        .background(Color.secondaryBackground)
        .overlay(alignment: .top) {
            Color.separator.frame(height: 1)
        }
    }

    func endOfChapter(_ index: Int) -> some View {
        VStack(spacing: 12) {
            Rectangle()
                .fill(Theme.faint)
                .frame(width: 40, height: 1)
            if index + 1 < book.chapters.count {
                Text("Next")
                    .font(.caption)
                    .foregroundColor(Theme.faint)
                Button("\(book.name(ofChapter: index + 1)) ›") { turn(to: index + 1) }
                    .tint(Theme.accent)
            } else {
                Text("End of the sample")
                    .font(.system(size: 15, design: .serif).italic())
                    .foregroundColor(Theme.faint)
                Button("Mark as Finished") { finish() }
                    .tint(Theme.accent)
            }
        }
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity)
    }

    func turn(to index: Int) {
        turnedTo = index
        library.read(book, at: index)
    }

    /// Done with the book: back to the library, where it shows as finished.
    func finish() {
        library.finish(book)
        router?.popToRoot()
    }
}

/// The text of one chapter, in a column that stops widening at a
/// comfortable measure.
@View
struct ChapterPage {
    let book: Book
    let index: Int
    let textSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: textSize * 0.8) {
            Text("CHAPTER \(index + 1)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.faint)
            if let title = book.chapters[index].title {
                Text(title)
                    .font(.system(size: textSize * 1.5, weight: .bold, design: .serif))
                    .foregroundColor(Theme.ink)
            }
            ForEach(0..<book.chapters[index].paragraphs.count) { paragraph in
                Text(book.chapters[index].paragraphs[paragraph])
                    .font(.system(size: textSize, design: .serif))
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(horizontal: 36, vertical: 36)
        .frame(maxWidth: .infinity)
        // The gaps between paragraphs are page too.
        .contentShape(Rectangle())
    }
}
