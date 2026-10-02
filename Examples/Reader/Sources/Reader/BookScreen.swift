//
//  BookScreen.swift
//  Reader
//
//  A book's page: the cover on a field of its colour running to the top of
//  the window, what the book is, a button into it and its contents. The
//  stack's bar is hidden for this screen, so the page draws its own header
//  and its own way back.
//

import NucleantUI

@View
struct BookScreen {
    let library: Library
    let book: Book
    @Environment(\.navigationRouter) private var router

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                header
                details
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.shelf)
        // The bar's 44 points go to the header — and with the bar goes its
        // Back button, which `backButton` stands in for.
        .toolbar(.hidden, for: .navigationBar)
    }

    var header: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 10) {
                Cover(book: book, width: 120)
                    .padding(.bottom, 10)
                Text(book.title)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundColor(book.coverInk)
                    .multilineTextAlignment(.center)
                Text("\(book.author) · \(book.year)")
                    .font(.subheadline)
                    .foregroundColor(book.coverInk.opacity(0.75))
            }
            .padding(horizontal: 24, vertical: 0)
            .padding(.top, 64)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background(
                Rectangle()
                    .fill(.linearGradient(colors: [book.coverShade, book.cover], startPoint: .top, endPoint: .bottom))
            )

            backButton
                .padding(14)
        }
    }

    var backButton: some View {
        Text("‹ Library")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(book.coverInk)
            .padding(horizontal: 12, vertical: 6)
            .background(Color(white: 0, opacity: 0.22))
            .cornerRadius(14)
            .onTapGesture { router?.pop() }
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(book.blurb)
                .font(.system(size: 16, design: .serif))
                .foregroundColor(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            NavigationLink(value: ReadingRoute(book: book.id, chapter: library.resumeChapter(of: book))) {
                Text(readTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(horizontal: 0, vertical: 12)
                    .background(Theme.accent)
                    .cornerRadius(10)
            }

            Text("Contents")
                .font(.headline)
                .padding(.top, 6)

            VStack(spacing: 0) {
                ForEach(0..<book.chapters.count) { index in
                    NavigationLink(value: ReadingRoute(book: book.id, chapter: index)) {
                        ChapterRow(
                            number: index + 1,
                            name: book.name(ofChapter: index),
                            minutes: book.chapters[index].minutes,
                            isOpen: library.status(of: book) == .reading(chapter: index),
                            isLast: index == book.chapters.count - 1
                        )
                    }
                }
            }
            .background(Theme.card)
            .cornerRadius(10)
        }
        .padding(20)
    }

    var readTitle: String {
        switch library.status(of: book) {
        case .new:                  "Start Reading"
        case .reading(let chapter): "Continue · Chapter \(chapter + 1)"
        case .finished:             "Read Again"
        }
    }
}

@View
struct ChapterRow {
    let number: Int
    let name: String
    let minutes: Int
    /// The chapter the book was left at.
    let isOpen: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(name)
                .font(.system(size: 15, design: .serif))
                .foregroundColor(Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isOpen {
                Text("Reading")
                    .font(.caption)
                    .foregroundColor(Theme.accent)
            }
            Text("\(minutes) min")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(horizontal: 14, vertical: 12)
        .overlay(alignment: .bottom) {
            if !isLast {
                Color.separator.frame(height: 1).padding(.leading, 48)
            }
        }
    }
}
