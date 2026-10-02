//
//  LibraryScreen.swift
//  Reader
//
//  The stack's root, under the "Library" bar: the book read last, to pick
//  up where it was left, and the shelf. Both destinations are registered
//  here, below every screen they serve.
//

import NucleantUI

@View
struct LibraryScreen {
    let library: Library

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                if let book = library.continueReading {
                    ContinueCard(book: book, chapter: library.resumeChapter(of: book))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("On the Shelf")
                        .font(.headline)
                    ForEach(library.books) { book in
                        NavigationLink(value: BookRoute(book: book.id)) {
                            BookRow(book: book, status: library.status(of: book))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.shelf)
        .navigationDestination(for: BookRoute.self) { route in
            BookScreen(library: library, book: library.book(route.book))
        }
        .navigationDestination(for: ReadingRoute.self) { route in
            ReadingScreen(library: library, book: library.book(route.book), opened: route.chapter)
        }
    }
}

/// The book read last, straight into the chapter it was left at.
@View
struct ContinueCard {
    let book: Book
    let chapter: Int

    var body: some View {
        NavigationLink(value: ReadingRoute(book: book.id, chapter: chapter)) {
            HStack(spacing: 16) {
                Cover(book: book, width: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONTINUE READING")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    Text(book.title)
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundColor(Theme.ink)
                        .lineLimit(2)
                    Text(book.place(ofChapter: chapter))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    ChapterProgress(count: book.chapters.count, current: chapter)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Theme.card)
            .cornerRadius(12)
        }
    }
}

@View
struct BookRow {
    let book: Book
    let status: ReadingStatus

    var body: some View {
        HStack(spacing: 14) {
            Cover(book: book, width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                Text("\(book.author) · \(book.year)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundColor(status == .new ? .secondary : Theme.accent)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("›")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Theme.card)
        .cornerRadius(10)
    }

    var statusLine: String {
        switch status {
        case .new:                  "\(book.chapters.count) chapters · \(book.minutes) min"
        case .reading(let chapter): "Reading · Chapter \(chapter + 1) of \(book.chapters.count)"
        case .finished:             "Finished"
        }
    }
}
