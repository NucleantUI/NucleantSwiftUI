//
//  TimelineView.swift
//  NucleantUI
//
//  A view rebuilt on a schedule rather than on a state change. After each
//  build it asks its schedule for the next date after now and files that
//  with the tree's `AnimationStore`; when the frame clock passes it, the
//  store dirties the view's path, and the next frame rebuilds it exactly as
//  a `@State` write would — its own subtree, nothing above.
//

import Foundation

/// When a `TimelineView` updates: a sequence of dates.
public protocol TimelineSchedule {
    typealias Mode = TimelineScheduleMode
    associatedtype Entries: Sequence where Entries.Element == Date

    /// The dates to update at, from `startDate` on, in order.
    func entries(from startDate: Date, mode: Mode) -> Entries
}

/// How often a schedule is asked to update. Only `.normal` is used here —
/// there is no reduced-rate state (an always-on display) to ask for less.
public enum TimelineScheduleMode: Sendable {
    case normal
    case lowFrequency
}

/// Every display frame, or every `minimumInterval` seconds at most.
public struct AnimationTimelineSchedule: TimelineSchedule, Sendable {
    let minimumInterval: Double?
    let paused: Bool

    public init(minimumInterval: Double? = nil, paused: Bool = false) {
        self.minimumInterval = minimumInterval
        self.paused = paused
    }

    public func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: paused ? nil : start, interval: minimumInterval ?? 1.0 / 120)
    }

    public struct Entries: Sequence, IteratorProtocol, Sendable {
        var upcoming: Date?
        let interval: Double

        public mutating func next() -> Date? {
            defer { upcoming = upcoming?.addingTimeInterval(interval) }
            return upcoming
        }
    }
}

/// Every `interval` seconds, counted from `startDate`.
public struct PeriodicTimelineSchedule: TimelineSchedule, Sendable {
    let startDate: Date
    let interval: Double

    public init(from startDate: Date, by interval: Double) {
        self.startDate = startDate
        self.interval = max(interval, 0.001)
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        // The first tick at or after `startDate`, still on the grid laid
        // from the schedule's own start.
        let elapsed = startDate.timeIntervalSince(self.startDate)
        let steps = max(0, (elapsed / interval).rounded(.up))
        return Entries(upcoming: self.startDate.addingTimeInterval(steps * interval), interval: interval)
    }

    public struct Entries: Sequence, IteratorProtocol, Sendable {
        var upcoming: Date
        let interval: Double

        public mutating func next() -> Date? {
            defer { upcoming = upcoming.addingTimeInterval(interval) }
            return upcoming
        }
    }
}

/// On the start of every minute.
public struct EveryMinuteTimelineSchedule: TimelineSchedule, Sendable {
    public init() {}

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> PeriodicTimelineSchedule.Entries {
        let minute = (startDate.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        return PeriodicTimelineSchedule(from: Date(timeIntervalSinceReferenceDate: minute), by: 60)
            .entries(from: startDate, mode: mode)
    }
}

/// At each of a given list of dates.
public struct ExplicitTimelineSchedule<Dates: Sequence>: TimelineSchedule where Dates.Element == Date {
    let dates: Dates

    public init(_ dates: Dates) {
        self.dates = dates
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Dates {
        dates
    }
}

extension TimelineSchedule where Self == AnimationTimelineSchedule {
    /// Every frame.
    public static var animation: AnimationTimelineSchedule { AnimationTimelineSchedule() }

    /// Every frame, no more often than `minimumInterval`; nothing at all
    /// while `paused`.
    public static func animation(minimumInterval: Double? = nil, paused: Bool = false) -> AnimationTimelineSchedule {
        AnimationTimelineSchedule(minimumInterval: minimumInterval, paused: paused)
    }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    public static func periodic(from startDate: Date, by interval: Double) -> PeriodicTimelineSchedule {
        PeriodicTimelineSchedule(from: startDate, by: interval)
    }
}

extension TimelineSchedule where Self == EveryMinuteTimelineSchedule {
    public static var everyMinute: EveryMinuteTimelineSchedule { EveryMinuteTimelineSchedule() }
}

extension TimelineSchedule {
    public static func explicit<S: Sequence>(_ dates: S) -> ExplicitTimelineSchedule<S>
    where Self == ExplicitTimelineSchedule<S> {
        ExplicitTimelineSchedule(dates)
    }
}

/// The context every `TimelineView`'s content closure receives. Named
/// through one fixed specialization, as SwiftUI does, so the closure's
/// parameter type does not depend on the `Content` being inferred from it.
public typealias TimelineViewDefaultContext = TimelineView<EveryMinuteTimelineSchedule, Never>.Context

/// A view that rebuilds its content on a schedule.
///
/// ```swift
/// TimelineView(.periodic(from: .now, by: 1)) { context in
///     Text(context.date.formatted(date: .omitted, time: .standard))
/// }
/// ```
@View
public struct TimelineView<Schedule: TimelineSchedule, Content: View>: View {

    /// What the content is built for.
    public struct Context {
        /// How often the view is updating.
        public enum Cadence: Comparable, Sendable {
            case live
            case seconds
            case minutes
        }

        /// The moment this build is for.
        public let date: Date

        public let cadence: Cadence
    }

    let schedule: Schedule
    let content: TimelineContent<Schedule, Content>

    public init(
        _ schedule: Schedule,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content
    ) {
        self.schedule = schedule
        self.content = TimelineContent(build: content)
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

/// A timeline's content closure, as a view input that is never equivalent
/// to another. The closure is how the parent's current values reach the
/// content — it captures them — so a timeline whose parent re-ran must run
/// the new one, not keep the last build's.
struct TimelineContent<Schedule: TimelineSchedule, Content: View>: ViewInput {
    let build: (TimelineViewDefaultContext) -> Content

    func _isEquivalent(to other: TimelineContent<Schedule, Content>) -> Bool { false }
}

extension TimelineView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let path = context.path
        let now = Date()
        let cadence: TimelineViewDefaultContext.Cadence
        switch schedule {
        case is EveryMinuteTimelineSchedule: cadence = .minutes
        case is AnimationTimelineSchedule: cadence = .live
        default: cadence = .seconds
        }
        // The content is user code and may read an `@Observable` model;
        // those reads are this view's, like a `body`'s.
        let built = trackingObservation(at: path) {
            content.build(TimelineViewDefaultContext(date: now, cadence: cadence))
        }
        let node = context.child(0) { ctx in buildNode(built, &ctx) }

        let next = schedule.entries(from: now, mode: .normal).first { $0 > now }
        context.animations.schedule(timelineAt: path, next: next)

        // Redrawn on its own clock: a node of its own, so the redraw lands
        // there rather than in whatever encloses it.
        guard !node.content.isTransparent else { return node }
        let boundary = ViewNode(
            content: RenderBoundaryContent(key: RenderNodeKey(path: path, identity: context.viewIdentity)),
            children: [node]
        )
        boundary.transitionTrait = node.transitionTrait
        return boundary
    }
}
