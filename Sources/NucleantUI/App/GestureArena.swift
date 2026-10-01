//
//  GestureArena.swift
//  NucleantUI
//
//  Runs the gestures attached with `.gesture` and its kin, and decides which
//  of them a press belongs to. Platform-free: `ViewHost` feeds it the same
//  pointer events it handles itself, plus the trackpad's pinch and rotation.
//
//  Every gesture a press reaches, and the pointer target it presses (a
//  `Button`, an `.onTapGesture` — the "press"), is a participant. They
//  compete, SwiftUI's way:
//
//  * a `.highPriorityGesture` goes before the gestures inside it (outermost
//    first), and while it may still be recognized, they wait;
//  * a `.gesture` goes after those inside it (innermost first);
//  * a `.simultaneousGesture` competes with nothing.
//
//  Within that order the first to recognize wins and the rest are cancelled
//  — so a long press on a tappable card is a long press, and a drag from a
//  button inside a draggable panel is a drag. Two exceptions keep the usual
//  idioms working: a tap (or a press) waits for a tap or press before it
//  that is still undecided — `.onTapGesture(count: 2)` then `.onTapGesture`
//  is a double tap or, once a second tap can no longer come, a single one —
//  and a drag that starts on press waits until it has moved a few points
//  before it takes a press from a button inside it.
//

import Foundation
import Dispatch
import NucleantWindow

/// Where a press lands: the pointer target it presses — the frontmost, as
/// it always was — and every gesture attached around it, innermost first,
/// each with its depth in the tree for ordering.
@MainActor
struct PressChain {
    var press: HitResult?
    var pressDepth = 0
    var gestures: [(hit: Hit<GestureAttachment>, depth: Int)] = []
}

extension ViewNode {

    /// The press chain at `point` (window coordinates).
    func pressChain(at point: Point) -> PressChain {
        let leaf = hitTest(point) { node -> ViewNode? in
            if let target = node.content.hitTarget, target.isEnabled, target.handlesPointer { return node }
            if let attachment = node.content.gestureAttachment, attachment.includesGesture { return node }
            return nil
        }
        var chain = PressChain()
        guard let leaf else { return chain }
        var lineage: [ViewNode] = []
        var cursor: ViewNode? = leaf.node
        while let node = cursor {
            lineage.append(node)
            cursor = node.parent
        }
        for (index, node) in lineage.enumerated() {
            let depth = lineage.count - 1 - index
            if chain.press == nil, let target = node.content.hitTarget, target.isEnabled, target.handlesPointer,
               let hit = node.hitRecord(target, at: point) {
                chain.press = hit
                chain.pressDepth = depth
            }
            guard let attachment = node.content.gestureAttachment else { continue }
            // `including: .gesture` — what is inside does not take part.
            if !attachment.includesSubviews {
                chain = PressChain()
            }
            if attachment.includesGesture, let hit = node.hitRecord(attachment, at: point) {
                chain.gestures.append((hit, depth))
            }
        }
        return chain
    }

    /// `value` found on this node at `point`, as a hit test reports it.
    fileprivate func hitRecord<Value>(_ value: Value, at point: Point) -> Hit<Value>? {
        guard let local = mapIntoLocalSpace(point) else { return nil }
        return Hit(
            value: value,
            node: self,
            localPoint: Point(x: local.x - frame.minX, y: local.y - frame.minY),
            frame: frame,
            transform: transform
        )
    }

    /// The gesture attachment at `path` in this subtree, if that view still
    /// stands.
    fileprivate func gestureAttachment(at path: [Int]) -> GestureAttachment? {
        if let attachment = content.gestureAttachment, attachment.path == path { return attachment }
        for child in children {
            if let found = child.gestureAttachment(at: path) { return found }
        }
        return nil
    }
}

/// Which trackpad gesture an event belongs to.
enum TrackpadGestureKind {
    case magnify
    case rotate
}

@MainActor
final class GestureArena {

    /// A gesture won over the press on `pointer`: let it go without a tap,
    /// with the pointer at `point`.
    var cancelPress: (_ pointer: Int, _ point: Point) -> Void = { _, _ in }

    /// A gesture that excludes others recognized on these pointers: the
    /// press is that gesture now, not a scroll, a drag-and-drop or a held
    /// context menu.
    var didClaim: (_ pointers: Set<Int>) -> Void = { _ in }

    /// How far a press moves before it is no longer a tap.
    static let tapSlop = 10.0
    /// How long after one tap the next may start, for a multi-tap gesture.
    static let tapInterval = 0.35

    private enum Key: Hashable {
        case press(Int)
        case gesture([Int])
    }

    @MainActor
    private final class Participant {
        enum State {
            /// May still be recognized.
            case possible
            /// Would be recognized, but something before it is undecided.
            case waiting
            /// Recognized, and still reporting.
            case active
            /// Over: ended, failed or cancelled.
            case finished
        }

        let key: Key
        let depth: Int
        let priority: GestureAttachment.Priority
        var state = State.possible
        var competitors: Set<Key> = []

        /// The gesture: its attachment (refreshed after rebuilds) and the
        /// view space it measures in, fixed at the first press.
        var attachment: GestureAttachment?
        var hit: Hit<GestureAttachment>?

        /// The press: its pointer, and whether it is a drag that reports
        /// as it goes (a slider) rather than a tap on release.
        var pressPointer: Int?
        /// A press released inside but waiting: how to tell it, `true` for
        /// a tap and `false` when something else won.
        var deliverRelease: ((Bool) -> Void)?

        /// The pointers on it — where each started and is now, in the
        /// gesture view's space.
        var pointers: [Int: (start: Point, current: Point)] = [:]
        /// What to run once recognized.
        var pending: (() -> Void)?
        /// Bumped to void a timer that was started for an earlier state.
        var serial = 0
        var movedBeyondSlop = false

        var tapCount = 0
        var lastDrag: DragGesture.Value?

        /// Two fingers: which, and how far apart and at what angle they
        /// started.
        var fingers: (first: Int, second: Int)?
        var startDistance = 0.0
        var startAngle = 0.0
        /// The rotation so far, unwrapped through ±π.
        var turned = 0.0
        var lastAngle = 0.0
        var startLocation = Point(x: 0, y: 0)
        /// A trackpad gesture's running total of AppKit's deltas.
        var trackpadTotal = 0.0
        var lastSample: (value: Double, time: Date)?
        var lastMagnify: MagnifyGesture.Value?
        var lastRotate: RotateGesture.Value?

        init(key: Key, depth: Int, priority: GestureAttachment.Priority) {
            self.key = key
            self.depth = depth
            self.priority = priority
        }

        var kind: _GestureRecognition.Kind? { attachment?.recognition.kind }
        var isPress: Bool { pressPointer != nil }
        var isAlive: Bool { state != .finished }
        var isExclusive: Bool { priority != .simultaneous }

        var isTap: Bool {
            if case .tap = kind { return true }
            return false
        }

        var isDrag: Bool {
            if case .drag = kind { return true }
            return false
        }

        /// A gesture recognized on release — waits for a counting tap
        /// before it.
        var recognizesOnRelease: Bool { isPress || isTap }

        /// Whether this one goes before `other`.
        func precedes(_ other: Participant) -> Bool {
            switch (priority, other.priority) {
            case (.high, .high): return depth < other.depth
            case (.high, _): return true
            case (_, .high): return false
            default: return depth > other.depth
            }
        }

        /// Its place in event order: high priority outermost first, then
        /// the rest innermost first, simultaneous ones last.
        var order: (Int, Int) {
            switch priority {
            case .high: return (0, depth)
            case .normal: return (1, -depth)
            case .simultaneous: return (2, -depth)
            }
        }
    }

    private var participants: [Key: Participant] = [:]
    /// The press participant of each pointer that has one.
    private var pressKeys: [Int: Key] = [:]
    private var nextPress = 0
    /// Where each pointer down is, in window coordinates.
    private var locations: [Int: Point] = [:]
    /// The participants of the trackpad gesture in flight, of each kind.
    private var trackpadKeys: [TrackpadGestureKind: [Key]] = [:]

    var isIdle: Bool { participants.isEmpty }

    // MARK: - Pointers

    /// A pointer went down at `point` (window) on `chain`. The press, if
    /// any, has been pressed already; `pressReports` says it is a drag
    /// that reported on press — recognized from the start.
    func pointerDown(_ id: Int, at point: Point, chain: PressChain, pressReports: Bool) {
        locations[id] = point
        guard !chain.gestures.isEmpty else { return }

        var members: [Participant] = []
        if chain.press != nil {
            nextPress += 1
            let participant = Participant(key: .press(nextPress), depth: chain.pressDepth, priority: .normal)
            participant.pressPointer = id
            participants[participant.key] = participant
            pressKeys[id] = participant.key
            members.append(participant)
        }

        var joined: [Participant] = []
        for link in chain.gestures {
            let key = Key.gesture(link.hit.value.path)
            if let existing = participants[key], existing.isAlive {
                guard accepts(existing) else { continue }
                existing.attachment = link.hit.value
                let local = existing.hit?.localPoint(for: point) ?? link.hit.localPoint
                existing.pointers[id] = (local, local)
                members.append(existing)
                joined.append(existing)
            } else {
                let participant = Participant(key: key, depth: link.depth, priority: link.hit.value.priority)
                participant.attachment = link.hit.value
                participant.hit = link.hit
                participant.pointers[id] = (link.hit.localPoint, link.hit.localPoint)
                participants[key] = participant
                members.append(participant)
                joined.append(participant)
            }
        }

        for member in members {
            for other in members where other !== member {
                member.competitors.insert(other.key)
            }
        }

        if pressReports, let key = pressKeys[id], let press = participants[key] {
            grant(press)
        }
        for participant in joined.sorted(by: { $0.order < $1.order }) where participant.isAlive {
            begin(participant, pointer: id)
        }
        reevaluateWaiting()
    }

    /// Whether a gesture already in flight takes another pointer: a tap
    /// between its taps, a pinch or twist with a finger still to come.
    private func accepts(_ participant: Participant) -> Bool {
        switch participant.kind {
        case .tap: return participant.pointers.isEmpty && participant.state == .possible
        case .magnify, .rotate: return participant.fingers == nil && participant.pointers.count < 2
        default: return false
        }
    }

    /// `pointer` has just joined `participant`.
    private func begin(_ participant: Participant, pointer: Int) {
        switch participant.kind {
        case .tap:
            // A tap pressed again is not one that timed out.
            participant.serial += 1
        case .longPress(let gesture):
            gesture.changedAction?(true)
            gesture.pressingAction?(true)
            participant.serial += 1
            let serial = participant.serial
            let key = participant.key
            DispatchQueue.main.asyncAfter(deadline: .now() + gesture.minimumDuration) { [weak self] in
                MainActor.assumeIsolated { self?.holdElapsed(key, serial: serial) }
            }
        case .drag(let gesture):
            if gesture.minimumDistance <= 0 {
                want(participant) { [weak self] in self?.reportDrag(participant, pointer: pointer, ended: false) }
            }
        case .magnify, .rotate:
            let ids = participant.pointers.keys.sorted()
            if ids.count == 2, let a = participant.pointers[ids[0]]?.current, let b = participant.pointers[ids[1]]?.current {
                participant.fingers = (ids[0], ids[1])
                participant.startDistance = Self.distance(a, b)
                participant.startAngle = atan2(b.y - a.y, b.x - a.x)
                participant.lastAngle = participant.startAngle
                participant.turned = 0
                participant.startLocation = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                participant.lastSample = nil
            }
        case nil:
            break
        }
    }

    func pointerMoved(_ id: Int, to point: Point) {
        guard locations[id] != nil else { return }
        locations[id] = point
        guard !participants.isEmpty else { return }
        for participant in sorted() where participant.isAlive {
            guard let track = participant.pointers[id],
                  let local = participant.hit?.localPoint(for: point)
            else { continue }
            participant.pointers[id]?.current = local
            let moved = Self.distance(track.start, local)
            if moved >= Self.tapSlop { participant.movedBeyondSlop = true }

            switch participant.kind {
            case .tap:
                if moved > Self.tapSlop { fail(participant) }
            case .longPress(let gesture):
                if participant.state != .active, moved > gesture.maximumDistance { fail(participant) }
            case .drag(let gesture):
                if participant.state == .active {
                    reportDrag(participant, pointer: id, ended: false)
                } else if participant.state == .possible, moved >= gesture.minimumDistance {
                    want(participant) { [weak self] in self?.reportDrag(participant, pointer: id, ended: false) }
                }
            case .magnify(let gesture):
                guard participant.fingers != nil else { continue }
                let value = pinchMagnification(participant)
                if participant.state == .active {
                    reportMagnify(participant, magnification: value, ended: false)
                } else if participant.state == .possible, abs(value - 1) >= gesture.minimumScaleDelta {
                    want(participant) { [weak self] in
                        guard let self else { return }
                        self.reportMagnify(participant, magnification: self.pinchMagnification(participant), ended: false)
                    }
                }
            case .rotate(let gesture):
                guard participant.fingers != nil else { continue }
                let value = pinchRotation(participant)
                if participant.state == .active {
                    reportRotate(participant, radians: value, ended: false)
                } else if participant.state == .possible, abs(value) >= abs(gesture.minimumAngleDelta.radians) {
                    want(participant) { [weak self] in
                        self?.reportRotate(participant, radians: participant.turned, ended: false)
                    }
                }
            case nil:
                break
            }
        }
        reevaluateWaiting()
    }

    /// A pointer went up at `point`. Called before the press on it is
    /// released (`pressReleased`), so a gesture recognized by this release
    /// goes first.
    func pointerUp(_ id: Int, at point: Point) {
        guard locations[id] != nil else { return }
        locations[id] = point
        defer { locations[id] = nil }
        guard !participants.isEmpty else { return }

        for participant in sorted() where participant.isAlive {
            guard participant.pointers[id] != nil else { continue }
            let local = participant.hit?.localPoint(for: point) ?? participant.pointers[id]!.current
            participant.pointers[id]?.current = local

            switch participant.kind {
            case .tap(let gesture):
                participant.pointers[id] = nil
                guard participant.state == .possible else { continue }
                guard participant.hit?.contains(point) == true else {
                    fail(participant)
                    continue
                }
                participant.tapCount += 1
                if participant.tapCount >= gesture.count {
                    want(participant) { [weak self] in
                        gesture.endedAction?()
                        gesture.locatedAction?(local)
                        self?.finish(participant)
                    }
                } else {
                    participant.serial += 1
                    let serial = participant.serial
                    let key = participant.key
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapInterval) { [weak self] in
                        MainActor.assumeIsolated { self?.tapIntervalElapsed(key, serial: serial) }
                    }
                }
            case .longPress:
                // Let go before the hold was long enough, or while
                // something before it was still undecided.
                fail(participant)
            case .drag:
                if participant.state == .active {
                    reportDrag(participant, pointer: id, ended: true)
                    finish(participant)
                } else {
                    fail(participant)
                }
            case .magnify:
                if participant.state == .active {
                    reportMagnify(participant, magnification: pinchMagnification(participant), ended: true)
                    finish(participant)
                } else {
                    fail(participant)
                }
            case .rotate:
                if participant.state == .active {
                    reportRotate(participant, radians: participant.turned, ended: true)
                    finish(participant)
                } else {
                    fail(participant)
                }
            case nil:
                break
            }
        }
        reevaluateWaiting()
    }

    /// The pointer is no longer a press at all — the system took it, or it
    /// became a scroll, a drag-and-drop or a context menu.
    func cancelPointer(_ id: Int) {
        locations[id] = nil
        if let key = pressKeys.removeValue(forKey: id), let press = participants[key] {
            // `ViewHost` lets its own press go.
            remove(press)
        }
        for participant in sorted() where participant.isAlive && participant.pointers[id] != nil {
            cancel(participant)
        }
        reevaluateWaiting()
    }

    // MARK: - The press

    /// The press on `pointer` has started reporting a drag: it is
    /// recognized, and the gestures after it are out.
    func pressReports(_ pointer: Int) {
        guard let key = pressKeys[pointer], let press = participants[key], press.state != .active else { return }
        grant(press)
        reevaluateWaiting()
    }

    /// The press on `pointer` was released, inside it or not. `deliver`
    /// tells its target — at once, or once the gestures before it are
    /// decided; with `false` if one of them wins.
    func pressReleased(_ pointer: Int, inside: Bool, deliver: @escaping (Bool) -> Void) {
        guard let key = pressKeys.removeValue(forKey: pointer), let press = participants[key], press.isAlive else {
            deliver(inside)
            return
        }
        if press.state == .active || !inside {
            deliver(inside)
            if press.state == .active {
                finish(press)
            } else {
                fail(press)
            }
            reevaluateWaiting()
            return
        }
        press.deliverRelease = deliver
        want(press) { [weak self] in
            deliver(true)
            self?.finish(press)
        }
        reevaluateWaiting()
    }

    /// `ViewHost` let the press on `pointer` go itself.
    func pressDropped(_ pointer: Int) {
        guard let key = pressKeys.removeValue(forKey: pointer), let press = participants[key] else { return }
        remove(press)
        reevaluateWaiting()
    }

    /// Whether any gesture is following `pointer`.
    func follows(pointer: Int) -> Bool {
        participants.values.contains { $0.isAlive && $0.pointers[pointer] != nil }
    }

    /// Whether a press on `chain` would start a long press gesture — then
    /// holding it means that, not the context menu.
    func timesHoldAhead(of chain: PressChain) -> Bool {
        chain.gestures.contains { link in
            if case .longPress = link.hit.value.recognition.kind { return true }
            return false
        }
    }

    /// Whether a drag gesture is following `pointer` — then a moving finger
    /// is that drag, not a scroll.
    func followsDrags(of pointer: Int) -> Bool {
        participants.values.contains { $0.isAlive && $0.isDrag && $0.pointers[pointer] != nil }
    }

    /// Point the gestures in flight at the actions of the latest build.
    func refreshAttachments(from root: ViewNode) {
        for participant in participants.values where participant.isAlive && !participant.isPress {
            guard let path = participant.attachment?.path,
                  let current = root.gestureAttachment(at: path)
            else { continue }
            participant.attachment = current
        }
    }

    // MARK: - Trackpad

    /// A trackpad pinch or rotation at `point`. `chain` is asked for only
    /// when one begins.
    func trackpad(
        _ kind: TrackpadGestureKind,
        phase: TrackpadGesturePhase,
        delta: Double,
        at point: Point,
        chain: () -> PressChain
    ) {
        switch phase {
        case .began:
            for key in trackpadKeys[kind] ?? [] {
                if let participant = participants[key] { cancel(participant) }
            }
            var members: [Participant] = []
            for link in chain().gestures {
                switch (kind, link.hit.value.recognition.kind) {
                case (.magnify, .magnify), (.rotate, .rotate): break
                default: continue
                }
                let key = Key.gesture(link.hit.value.path)
                if let existing = participants[key] { cancel(existing) }
                let participant = Participant(key: key, depth: link.depth, priority: link.hit.value.priority)
                participant.attachment = link.hit.value
                participant.hit = link.hit
                participant.startLocation = link.hit.localPoint
                participants[key] = participant
                members.append(participant)
            }
            for member in members {
                for other in members where other !== member {
                    member.competitors.insert(other.key)
                }
            }
            trackpadKeys[kind] = members.map(\.key)

        case .changed:
            for key in trackpadKeys[kind] ?? [] {
                guard let participant = participants[key], participant.isAlive else { continue }
                participant.trackpadTotal += delta
                switch participant.kind {
                case .magnify(let gesture):
                    let value = 1 + participant.trackpadTotal
                    if participant.state == .active {
                        reportMagnify(participant, magnification: value, ended: false)
                    } else if participant.state == .possible, abs(value - 1) >= gesture.minimumScaleDelta {
                        want(participant) { [weak self] in
                            self?.reportMagnify(participant, magnification: 1 + participant.trackpadTotal, ended: false)
                        }
                    }
                case .rotate(let gesture):
                    // AppKit turns counterclockwise for positive; the view
                    // space is clockwise.
                    let value = -participant.trackpadTotal * .pi / 180
                    if participant.state == .active {
                        reportRotate(participant, radians: value, ended: false)
                    } else if participant.state == .possible, abs(value) >= abs(gesture.minimumAngleDelta.radians) {
                        want(participant) { [weak self] in
                            self?.reportRotate(participant, radians: -participant.trackpadTotal * .pi / 180, ended: false)
                        }
                    }
                default:
                    break
                }
            }
            reevaluateWaiting()

        case .ended, .cancelled:
            for key in trackpadKeys.removeValue(forKey: kind) ?? [] {
                guard let participant = participants[key], participant.isAlive else { continue }
                if phase == .ended, participant.state == .active {
                    switch participant.kind {
                    case .magnify:
                        reportMagnify(participant, magnification: 1 + participant.trackpadTotal, ended: true)
                    case .rotate:
                        reportRotate(participant, radians: -participant.trackpadTotal * .pi / 180, ended: true)
                    default:
                        break
                    }
                    finish(participant)
                } else {
                    cancel(participant)
                }
            }
            reevaluateWaiting()
        }
    }

    // MARK: - Deciding

    /// `participant` would be recognized now, running `action` when it is.
    private func want(_ participant: Participant, _ action: @escaping () -> Void) {
        participant.pending = action
        evaluate(participant)
    }

    private func rivals(of participant: Participant) -> [Participant] {
        participant.competitors.compactMap { key in
            guard let other = participants[key], other.isAlive, other.isExclusive, other !== participant else { return nil }
            return other
        }
    }

    /// Recognize `participant` if nothing before it stands in the way;
    /// otherwise let it wait, or — behind one already recognized — drop it.
    private func evaluate(_ participant: Participant) {
        guard participant.state == .possible || participant.state == .waiting else { return }
        guard participant.isExclusive else {
            grant(participant)
            return
        }
        let before = rivals(of: participant).filter { $0.precedes(participant) }
        if before.contains(where: { $0.state == .active }) {
            cancel(participant)
            return
        }
        let mustWait =
            // A high-priority gesture goes first until it is decided.
            before.contains(where: { $0.priority == .high })
            // A tap — or a press — still down or still counting goes
            // before a tap after it: both are decided on release, and the
            // one before is the one that gets it.
            || (participant.recognizesOnRelease && before.contains(where: \.recognizesOnRelease))
            // A drag that would start on press takes nothing from a button
            // inside it until it has really moved.
            || (participant.isDrag && !participant.movedBeyondSlop && !before.isEmpty)
        if mustWait {
            participant.state = .waiting
            return
        }
        grant(participant)
    }

    /// `participant` is recognized: everything it competes with is
    /// cancelled — except a high-priority gesture before it, which a press
    /// that reports on its own (a slider) can't overrule.
    private func grant(_ participant: Participant) {
        participant.state = .active
        if participant.isExclusive {
            for rival in rivals(of: participant) where !(rival.priority == .high && rival.precedes(participant)) {
                cancel(rival)
            }
            var pointers = Set(participant.pointers.keys)
            if let pointer = participant.pressPointer { pointers.insert(pointer) }
            if !pointers.isEmpty { didClaim(pointers) }
        }
        let action = participant.pending
        participant.pending = nil
        action?()
    }

    /// Run again everything that is waiting, until nothing changes.
    private func reevaluateWaiting() {
        var rounds = 0
        while rounds < 8 {
            rounds += 1
            let waiting = sorted().filter { $0.state == .waiting }
            guard !waiting.isEmpty else { return }
            var changed = false
            for participant in waiting {
                evaluate(participant)
                if participant.state != .waiting { changed = true }
            }
            guard changed else { return }
        }
    }

    /// Over without being recognized.
    private func fail(_ participant: Participant) {
        guard participant.isAlive else { return }
        if case .longPress(let gesture) = participant.kind {
            gesture.pressingAction?(false)
        }
        remove(participant)
    }

    /// Over because something else won. A press is let go without its tap;
    /// a gesture that was reporting reports its end, so whatever it moved
    /// can settle.
    private func cancel(_ participant: Participant) {
        guard participant.isAlive else { return }
        let wasActive = participant.state == .active
        if let pointer = participant.pressPointer {
            remove(participant)
            if let deliver = participant.deliverRelease {
                deliver(false)
            } else if let point = locations[pointer] {
                cancelPress(pointer, point)
            }
            return
        }
        switch participant.kind {
        case .longPress(let gesture):
            gesture.pressingAction?(false)
        case .drag:
            if wasActive, let pointer = participant.lastDrag?.id {
                reportDrag(participant, pointer: pointer, ended: true)
            }
        case .magnify:
            if wasActive, let last = participant.lastMagnify {
                reportMagnify(participant, magnification: last.magnification, ended: true)
            }
        case .rotate:
            if wasActive, let last = participant.lastRotate {
                reportRotate(participant, radians: last.rotation.radians, ended: true)
            }
        default:
            break
        }
        remove(participant)
    }

    /// Over, recognized.
    private func finish(_ participant: Participant) {
        guard participant.isAlive else { return }
        if case .longPress(let gesture) = participant.kind {
            gesture.pressingAction?(false)
        }
        remove(participant)
    }

    private func remove(_ participant: Participant) {
        participant.state = .finished
        participant.serial += 1
        participant.pending = nil
        if participants[participant.key] === participant {
            participants[participant.key] = nil
        }
        if let pointer = participant.pressPointer, pressKeys[pointer] == participant.key {
            pressKeys[pointer] = nil
        }
    }

    private func sorted() -> [Participant] {
        participants.values.sorted { $0.order < $1.order }
    }

    // MARK: - Timers

    private func holdElapsed(_ key: Key, serial: Int) {
        guard let participant = participants[key], participant.serial == serial,
              participant.state == .possible, !participant.pointers.isEmpty,
              case .longPress(let gesture) = participant.kind
        else { return }
        want(participant) { [weak self] in
            gesture.endedAction?(true)
            self?.finish(participant)
        }
        reevaluateWaiting()
    }

    private func tapIntervalElapsed(_ key: Key, serial: Int) {
        guard let participant = participants[key], participant.serial == serial,
              participant.state == .possible, participant.pointers.isEmpty
        else { return }
        fail(participant)
        reevaluateWaiting()
    }

    // MARK: - Reporting

    private func reportDrag(_ participant: Participant, pointer: Int, ended: Bool) {
        guard case .drag(let gesture) = participant.kind else { return }
        let value: DragGesture.Value
        if let track = participant.pointers[pointer], let hit = participant.hit {
            value = DragGesture.Value(
                id: pointer,
                startLocation: track.start,
                location: track.current,
                translation: Size(width: track.current.x - track.start.x, height: track.current.y - track.start.y),
                bounds: Rect(origin: .zero, size: hit.frame.size)
            )
        } else if let last = participant.lastDrag {
            value = last
        } else {
            return
        }
        participant.lastDrag = value
        (ended ? gesture.endedAction : gesture.changedAction)?(value)
    }

    private func reportMagnify(_ participant: Participant, magnification: Double, ended: Bool) {
        guard case .magnify(let gesture) = participant.kind else { return }
        let value = MagnifyGesture.Value(
            time: Date(),
            magnification: magnification,
            velocity: velocity(participant, value: magnification),
            startAnchor: anchor(participant),
            startLocation: participant.startLocation
        )
        participant.lastMagnify = value
        (ended ? gesture.endedAction : gesture.changedAction)?(value)
    }

    private func reportRotate(_ participant: Participant, radians: Double, ended: Bool) {
        guard case .rotate(let gesture) = participant.kind else { return }
        let value = RotateGesture.Value(
            time: Date(),
            rotation: .radians(radians),
            velocity: .radians(velocity(participant, value: radians)),
            startAnchor: anchor(participant),
            startLocation: participant.startLocation
        )
        participant.lastRotate = value
        (ended ? gesture.endedAction : gesture.changedAction)?(value)
    }

    /// The scale between the two fingers now and when they started.
    private func pinchMagnification(_ participant: Participant) -> Double {
        guard let fingers = participant.fingers,
              let a = participant.pointers[fingers.first]?.current,
              let b = participant.pointers[fingers.second]?.current,
              participant.startDistance > 0
        else { return 1 }
        return Self.distance(a, b) / participant.startDistance
    }

    /// The turn of the line between the two fingers since they started,
    /// unwrapped so it can pass half a turn.
    private func pinchRotation(_ participant: Participant) -> Double {
        guard let fingers = participant.fingers,
              let a = participant.pointers[fingers.first]?.current,
              let b = participant.pointers[fingers.second]?.current
        else { return participant.turned }
        let angle = atan2(b.y - a.y, b.x - a.x)
        var step = angle - participant.lastAngle
        if step > .pi { step -= 2 * .pi }
        if step < -.pi { step += 2 * .pi }
        participant.lastAngle = angle
        participant.turned += step
        return participant.turned
    }

    private func velocity(_ participant: Participant, value: Double) -> Double {
        let now = Date()
        defer { participant.lastSample = (value, now) }
        guard let last = participant.lastSample else { return 0 }
        let elapsed = now.timeIntervalSince(last.time)
        return elapsed > 0 ? (value - last.value) / elapsed : 0
    }

    private func anchor(_ participant: Participant) -> UnitPoint {
        let size = participant.hit?.frame.size ?? .zero
        return UnitPoint(
            x: size.width > 0 ? participant.startLocation.x / size.width : 0.5,
            y: size.height > 0 ? participant.startLocation.y / size.height : 0.5
        )
    }

    private static func distance(_ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
