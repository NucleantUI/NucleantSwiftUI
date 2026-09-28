//
//  FlashcardsApp.swift
//  Flashcards
//
//  A study session over a deck of capital cities, where every change on
//  screen is animated and each one uses a different part of the animation
//  API:
//
//  The model is one `@Observable` class, `StudySession`, owned by the root
//  view and handed down; the views change it only through its methods.
//
//  * The card: dragged with a `DragGesture` and no animation at all (it
//    follows the pointer), sprung back with `withAnimation(.bouncy)` if
//    let go short, or flung off with `withAnimation(_:_:completion:)` —
//    whose completion then grades the card and brings on the next.
//  * The next card arrives through a `ForEach` over just the current one:
//    a new id is a removal and an insertion, so `.transition` applies.
//  * Tapping flips it: `FlipCard` is `Animatable`, so the face swaps at
//    the halfway point of a spring.
//  * Grading before revealing shakes it: an `AnimatableModifier` under
//    `.animation(_:value:)`, so its linear wobble runs alongside the
//    spring-back instead of under the same curve.
//  * The header: an animatable `ProgressArc`, counters that count, a
//    streak that grows and changes colour, and a `TimelineView` clock.
//  * The results slide up over the deck (an `if` with a transition); the
//    score ticks up under the custom `Ticking` animation, and the missed
//    cards come in one after another, each `.animation` delayed a little
//    more than the last.
//

import Foundation
import NucleantUI
import Observation

// MARK: - Model

struct Card: Identifiable, Equatable {
    let id: Int
    let category: String
    /// What the card is about, for the review list — "Chile".
    let subject: String
    let prompt: String
    let answer: String
}

let capitals: [Card] = [
    ("Japan", "Tokyo"), ("Canada", "Ottawa"), ("Australia", "Canberra"),
    ("Brazil", "Brasília"), ("Kenya", "Nairobi"), ("Norway", "Oslo"),
    ("Chile", "Santiago"), ("Vietnam", "Hanoi"), ("Morocco", "Rabat"),
    ("New Zealand", "Wellington"),
].enumerated().map { index, pair in
    Card(id: index, category: "Capital city", subject: pair.0, prompt: "What is the capital of \(pair.0)?", answer: pair.1)
}

enum Grade {
    case knew, missed
}

/// One pass through a deck — the app's model, changed only through its
/// methods. Every view that shows part of it reads it directly and is
/// rebuilt when what it read changes, so a single `withAnimation` around a
/// method call animates everything that call touches: the card, the
/// counters, the dots, the streak.
@MainActor
@Observable
final class StudySession {
    /// The cards in the order they are asked.
    private(set) var deck: [Card] = []
    /// The cards not yet graded; the first is on the table.
    private(set) var queue: [Card] = []
    private(set) var grades: [Int: Grade] = [:]
    private(set) var streak = 0
    private(set) var bestStreak = 0
    private(set) var started = Date()

    init(cards: [Card]) {
        restart(with: cards)
    }

    /// A new pass over `cards`, shuffled.
    func restart(with cards: [Card]) {
        deck = cards.shuffled()
        queue = deck
        grades = [:]
        streak = 0
        bestStreak = 0
        started = Date()
    }

    var current: Card? { queue.first }
    var isFinished: Bool { queue.isEmpty }
    var graded: Int { grades.count }
    var knew: Int { grades.values.filter { $0 == .knew }.count }
    var missed: [Card] { deck.filter { grades[$0.id] == .missed } }
    var progress: Double { deck.isEmpty ? 0 : Double(graded) / Double(deck.count) }

    func grade(_ grade: Grade) {
        guard let card = queue.first else { return }
        queue.removeFirst()
        grades[card.id] = grade
        streak = grade == .knew ? streak + 1 : 0
        bestStreak = max(bestStreak, streak)
    }
}

struct Theme {
    static let background = Color.background
    static let panel = Color.secondaryBackground
    static let card = Color.dynamic(light: Color.white, dark: Color(hex: 0x262B35))
    static let cardBehind = Color.dynamic(light: Color(hex: 0xDADDE4), dark: Color(hex: 0x1D2129))
    static let answerCard = Color(hex: 0x4C6FFF)
    static let onAnswer = Color.white
    static let good = Color(hex: 0x2FBF71)
    static let bad = Color(hex: 0xFF5C5C)
    static let hot = Color(hex: 0xFFA41B)
    static let muted = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.3))
    /// A card not reached yet — a dot, a ring's track.
    static let pending = Color.dynamic(light: Color(white: 0, opacity: 0.18), dark: Color(white: 1, opacity: 0.2))
}

// MARK: - Studying

@View
struct StudyView {
    let session: StudySession

    @State private var isFlipped = false
    /// How far the card has been dragged or flung, sideways.
    @State private var offset = 0.0
    /// Whole shakes played so far — one more plays another.
    @State private var shakes = 0
    @State private var showsHint = false
    /// A card is on its way off: input waits for the next.
    @State private var isFlinging = false

    /// Past this, a released drag grades the card.
    private let flingDistance = 120.0

    var body: some View {
        VStack(spacing: 22) {
            header
            deck
            Text("Reveal the answer first — tap the card")
                .font(.footnote)
                .foregroundColor(Theme.bad)
                .opacity(showsHint ? 1 : 0)
            controls
            dots
        }
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Theme.pending, lineWidth: 6)
                ProgressArc(progress: session.progress, inset: 3)
                    .stroke(Theme.answerCard, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                CountingText(value: Double(session.graded))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Capitals")
                    .font(.system(size: 20, weight: .bold))
                HStack(spacing: 6) {
                    CountingText(value: Double(session.knew), suffix: " known")
                    Text("·")
                    TimelineView(.periodic(from: session.started, by: 1)) { context in
                        Text(elapsed(since: session.started, at: context.date))
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            streakBadge
        }
        .frame(width: 400)
    }

    /// Grows with the streak and turns hot at three.
    var streakBadge: some View {
        let isHot = session.streak >= 3
        return Text("\(session.streak) in a row")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isHot ? .white : .secondary)
            .padding(horizontal: 12, vertical: 6)
            .background(isHot ? Theme.hot : Color.fill)
            .cornerRadius(14)
            .scaleEffect(1 + Double(min(session.streak, 5)) * 0.05)
    }

    // MARK: The deck

    var deck: some View {
        ZStack {
            // The cards still to come, as edges peeking out underneath.
            ForEach(depthsBehind, id: \.self) { depth in
                RoundedRectangle(cornerRadius: 20)
                    .fill(Theme.cardBehind)
                    .frame(width: 360 - Double(depth) * 24, height: 220)
                    .offset(y: Double(depth) * 9)
                    .transition(.opacity)
            }
            // Only the current card, keyed by its id: the next one is a
            // different element, so the change is a removal and an
            // insertion and the transition plays.
            ForEach(session.current.map { [$0] } ?? [], id: \.id) { card in
                FlipCard(card: card, angle: isFlipped ? 180 : 0)
                    .frame(width: 360, height: 220)
                    .modifier(Shake(shakes: Double(shakes)))
                    .animation(.linear(duration: 0.45), value: shakes)
                    .offset(x: offset)
                    .rotationEffect(.degrees(offset / 25), anchor: .bottom)
                    .gesture(drag)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(width: 400, height: 250)
    }

    var depthsBehind: [Int] {
        let behind = min(2, max(0, session.queue.count - 1))
        return behind == 0 ? [] : Array((1...behind).reversed())
    }

    /// Follows the pointer without animation; on release, a tap flips, a
    /// long throw grades, and anything else springs back.
    var drag: DragGesture {
        DragGesture()
            .onChanged { value in
                guard !isFlinging else { return }
                offset = value.translation.width
            }
            .onEnded { value in
                guard !isFlinging else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) < 6, abs(dy) < 6 {
                    offset = 0
                    flip()
                } else if abs(dx) > flingDistance {
                    fling(dx > 0 ? .knew : .missed)
                } else {
                    withAnimation(.bouncy) { offset = 0 }
                }
            }
    }

    // MARK: Controls

    var controls: some View {
        HStack(spacing: 10) {
            Button("Missed it") { fling(.missed) }
                .tint(Theme.bad)
            Button(isFlipped ? "Show question" : "Reveal") { flip() }
                .tint(Theme.muted)
            Button("Knew it") { fling(.knew) }
                .tint(Theme.good)
        }
    }

    /// One dot per card: filled by how it went, the current one larger.
    var dots: some View {
        HStack(spacing: 8) {
            ForEach(session.deck) { card in
                let isCurrent = card.id == session.current?.id
                Circle()
                    .fill(dotColor(card))
                    .frame(width: isCurrent ? 14 : 8, height: isCurrent ? 14 : 8)
            }
        }
        .frame(height: 16)
    }

    func dotColor(_ card: Card) -> Color {
        switch session.grades[card.id] {
        case .knew: return Theme.good
        case .missed: return Theme.bad
        case nil: return card.id == session.current?.id ? Theme.answerCard : Theme.pending
        }
    }

    // MARK: Actions

    func flip() {
        guard !isFlinging else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
            isFlipped.toggle()
            showsHint = false
        }
    }

    /// Throw the card off to the side it was graded to; once it is gone,
    /// grade it and deal the next. Not before the answer has been seen —
    /// then the card shakes its head and springs back.
    func fling(_ grade: Grade) {
        guard !isFlinging, session.current != nil else { return }
        guard isFlipped else {
            withAnimation(.bouncy) {
                offset = 0
                shakes += 1
                showsHint = true
            }
            return
        }
        isFlinging = true
        withAnimation(.easeIn(duration: 0.22)) {
            offset = grade == .knew ? 560 : -560
        } completion: {
            withAnimation(.snappy) {
                session.grade(grade)
                isFlipped = false
                offset = 0
            }
            isFlinging = false
        }
    }
}

func elapsed(since start: Date, at now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

// MARK: - Results

@View
struct ResultsView {
    let session: StudySession
    /// False on the frame the view arrives, true from the next — the
    /// change every entrance animation below is keyed to.
    @State private var revealed = false
    @State private var finishedAt = Date()

    var body: some View {
        let score = session.deck.isEmpty ? 0 : Double(session.knew) / Double(session.deck.count)
        VStack(spacing: 18) {
            Text("Session complete")
                .font(.system(size: 22, weight: .bold))

            ZStack {
                Circle().stroke(Theme.pending, lineWidth: 12)
                ProgressArc(progress: revealed ? score : 0, inset: 6)
                    .stroke(score >= 0.7 ? Theme.good : Theme.hot, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .animation(.smooth(duration: 1.4), value: revealed)
                CountingText(value: revealed ? score * 100 : 0, suffix: "%")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
            }
            .frame(width: 170, height: 170)

            Text("\(session.knew) of \(session.deck.count) known · best streak \(session.bestStreak) · \(elapsed(since: session.started, at: finishedAt))")
                .font(.footnote)
                .foregroundColor(.secondary)

            if !session.missed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("To review")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(Array(session.missed.enumerated()), id: \.element.id) { entry in
                        HStack(spacing: 10) {
                            Circle().fill(Theme.bad).frame(width: 8, height: 8)
                            Text(entry.element.subject)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.element.answer)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(horizontal: 14, vertical: 8)
                        .background(Theme.panel)
                        .cornerRadius(10)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 18)
                        // Each row a beat after the one above.
                        .animation(.snappy.delay(0.5 + Double(entry.offset) * 0.08), value: revealed)
                    }
                }
                .frame(width: 420)
            }

            HStack(spacing: 10) {
                if !session.missed.isEmpty {
                    Button("Review missed") {
                        withAnimation(.smooth) { session.restart(with: session.missed) }
                    }
                    .tint(Theme.bad)
                }
                Button("Study again") {
                    withAnimation(.smooth) { session.restart(with: capitals) }
                }
                .tint(Theme.answerCard)
            }
        }
        .onAppear {
            finishedAt = Date()
            // The number rolls up like an odometer; the ring and the rows
            // override it with animations of their own.
            withAnimation(Animation(Ticking(ticks: 30, duration: 1.4))) { revealed = true }
        }
    }
}

// MARK: - App

@View
struct FlashcardsView {
    @State private var session = StudySession(cards: capitals)
    @Environment(\.colorScheme) private var system

    var body: some View {
        ZStack {
            if session.isFinished {
                ResultsView(session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                StudyView(session: session)
                    .transition(.opacity)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }
}

@main
struct FlashcardsApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Flashcards", width: 640, height: 600) {
            FlashcardsView()
        }
        .commands { AppearanceCommands() }
    }
}
