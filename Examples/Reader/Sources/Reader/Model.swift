//
//  Model.swift
//  Reader
//
//  The library: books of chapters, where each one was left, which are
//  finished, and the reading text size. `Library` is the `@Observable`
//  model, changed only through its methods; a `Book` and its `Chapter`s
//  are the records inside it. The screens are pushed by value, as a
//  `BookRoute` or a `ReadingRoute`.
//

import NucleantUI
import Observation

struct Chapter: Equatable {
    /// `nil` for a book whose chapters are only numbered.
    let title: String?
    let paragraphs: [String]

    /// Minutes to read, at 230 words a minute.
    var minutes: Int {
        let words = paragraphs.reduce(0) { $0 + $1.split(separator: " ").count }
        return max(1, Int((Double(words) / 230).rounded()))
    }
}

struct Book: Identifiable, Equatable {
    let id: Int
    let title: String
    let author: String
    let year: Int
    let blurb: String
    /// The cover: a field shading from `cover` to `coverShade`, lettered in
    /// `coverInk`. Fixed colors — a printed cover is the same in the dark.
    let cover: Color
    let coverShade: Color
    let coverInk: Color
    let chapters: [Chapter]

    func name(ofChapter index: Int) -> String {
        chapters[index].title ?? "Chapter \(index + 1)"
    }

    /// "The Pool of Tears · Chapter 2 of 2" — just the count for a book
    /// whose chapters are only numbered.
    func place(ofChapter index: Int) -> String {
        let count = "Chapter \(index + 1) of \(chapters.count)"
        guard let title = chapters[index].title else { return count }
        return "\(title) · \(count)"
    }

    var minutes: Int { chapters.reduce(0) { $0 + $1.minutes } }
}

/// How far into a book the reader is.
enum ReadingStatus: Equatable {
    case new
    case reading(chapter: Int)
    case finished
}

/// Pushes a book's page.
struct BookRoute: Hashable {
    let book: Book.ID
}

/// Pushes the reading screen, open at `chapter`.
struct ReadingRoute: Hashable {
    let book: Book.ID
    let chapter: Int
}

@MainActor
@Observable
final class Library {
    let books: [Book]

    /// The chapter each book in progress was left at.
    private(set) var positions: [Book.ID: Int]
    private(set) var finished: Set<Book.ID> = []
    /// The book read last, for Continue Reading.
    private(set) var lastRead: Book.ID?

    /// The reading text, in points.
    private(set) var textSize: Double = 19
    static let textSizes: ClosedRange<Double> = 15...29

    init(books: [Book] = Book.shelf) {
        self.books = books
        // Part of the way into one book, so there is something to continue.
        let started = books[1]
        positions = [started.id: 1]
        lastRead = started.id
    }

    func book(_ id: Book.ID) -> Book {
        books.first { $0.id == id }!
    }

    func status(of book: Book) -> ReadingStatus {
        if finished.contains(book.id) { return .finished }
        if let chapter = positions[book.id] { return .reading(chapter: chapter) }
        return .new
    }

    /// Where opening the book picks up: the chapter it was left at, or the
    /// start for a new or finished one.
    func resumeChapter(of book: Book) -> Int {
        if case .reading(let chapter) = status(of: book) { return chapter }
        return 0
    }

    var continueReading: Book? {
        lastRead.map(book)
    }

    /// The reader has `chapter` of `book` open.
    func read(_ book: Book, at chapter: Int) {
        positions[book.id] = chapter
        finished.remove(book.id)
        lastRead = book.id
    }

    func finish(_ book: Book) {
        finished.insert(book.id)
        positions[book.id] = nil
        if lastRead == book.id { lastRead = nil }
    }

    var canEnlargeText: Bool { textSize < Self.textSizes.upperBound }
    var canShrinkText: Bool { textSize > Self.textSizes.lowerBound }

    func enlargeText() {
        textSize = min(textSize + 2, Self.textSizes.upperBound)
    }

    func shrinkText() {
        textSize = max(textSize - 2, Self.textSizes.lowerBound)
    }
}
