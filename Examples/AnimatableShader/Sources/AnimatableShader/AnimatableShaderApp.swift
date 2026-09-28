//
//  AnimatableShaderApp.swift
//  AnimatableShader
//
//  Shaders driven by an animation rather than by the clock.
//
//  Each `.py` here is a ShaderToy port with its `time` swapped for
//  `playhead`, a `ShaderArgument`. Nothing in them reads the real clock, so
//  on their own they stand still.
//
//  `ShaderCanvas` is an `Animatable` view whose `animatableData` is that
//  playhead, so while an animation runs its body is rebuilt at every value
//  in between, and each rebuild hands the shader the next one. A tap plays
//  the shader forward, and the animation's completion plays it back to
//  where it started — each scene with its own timing. The shader has no
//  idea it is being animated; it only sees a float change.
//
//  The radar's way back is a `CustomAnimation`, `SettleBounce`: it arrives
//  still moving, swings past where it started and bounces into place.
//
//  The last scene animates a point instead of a clock: a glow at `light`,
//  moved to wherever you tap by `LightCanvas`, whose `animatableData` is the
//  point's. The move is another `CustomAnimation`, `Wiggle`: most of the way
//  at once, then a few shrinking swings about the tap.
//
//  The tab bar picks the scene. Its highlight is a capsule offset by the
//  selected index, slid across by `withAnimation`; the scene itself changes
//  in that animation's completion, once the highlight has arrived, pushed
//  in from the side the highlight went — `.transition(.push(from:))`.
//

import Foundation
import NucleantUI

/// A shader and what a tap does to it.
struct ShaderScene: Identifiable {
    enum Motion {
        /// Play the shader's clock `forward` seconds, taking as long, then
        /// `rewind` it to 0.
        case playhead(forward: Double, rewind: Animation)
        /// Move the shader's `light` to where the tap landed.
        case follow(Animation)
    }

    /// The bundled .py it is read from.
    let id: String
    let title: String
    let function: ShaderFunction
    let motion: Motion

    init(_ resource: String, title: String, motion: Motion) {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "py"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("\(resource).py is missing from the bundle") }
        self.id = resource
        self.title = title
        self.function = ShaderFunction(pyshader: source)
        self.motion = motion
    }

    static let all = [
        ShaderScene("OrientedBox", title: "Oriented Box",
                    motion: .playhead(forward: 2, rewind: .easeInOut(duration: 2))),
        ShaderScene("LonelyWaters", title: "Lonely Waters",
                    motion: .playhead(forward: 8, rewind: .easeInOut(duration: 2))),
        ShaderScene("RadarTrace", title: "Radar Trace",
                    motion: .playhead(forward: 8, rewind: Animation(SettleBounce(duration: 2, settle: 1, bounce: 0.12)))),
        ShaderScene("LightFollows", title: "Light Follows",
                    motion: .follow(Animation(Wiggle(duration: 4, damping: 7)))),
    ]
}

// MARK: - Rewind

/// Back in `duration` seconds, speeding up all the way, then `settle`
/// more seconds swinging either side of the target and dying away.
///
/// `bounce` is how far the first swing would go past the target, as a
/// fraction of the whole change, were it not already fading. The way back
/// is an ease in steep enough to arrive at the speed that swing starts
/// with, so the two read as one motion. There are one and a half swings,
/// so the sine is back at zero — exactly on the target — when `settle`
/// runs out.
struct SettleBounce: CustomAnimation {
    var duration: Double
    var settle: Double
    var bounce: Double

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        let swing = 3 * .pi / settle
        if time < duration {
            // u^p arrives at p / duration; the swing leaves at bounce * swing.
            let power = max(1, bounce * swing * duration)
            return value.scaled(by: pow(time / duration, power))
        }
        let s = time - duration
        guard s < settle else { return nil }
        let decay = exp(-3 * s / settle)
        return value.scaled(by: 1 + bounce * sin(swing * s) * decay)
    }
}

/// Most of the way at once, then a few swings about the target, each
/// smaller than the last, all in `duration` seconds.
///
/// A cosine inside a decaying envelope: `1 - e^(-damping·u)·cos(4.5π·u)`
/// over `u` from 0 to 1. It leaves at full speed and first overshoots a
/// fifth of the way in; `damping` sets how far past it goes (7 is about a
/// fifth of the move, then a twentieth). 4.5π puts the cosine at zero when
/// `u` reaches 1, so it lands exactly on the target, not near it.
struct Wiggle: CustomAnimation {
    var duration: Double
    var damping: Double

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        let u = time / duration
        return value.scaled(by: 1 - exp(-damping * u) * cos(4.5 * .pi * u))
    }
}

// MARK: - Stages

/// A scene's stage, by what a tap does to it.
@View
struct SceneStage {
    let scene: ShaderScene

    var body: some View {
        switch scene.motion {
        case .playhead(let forward, let rewind):
            PlayheadStage(function: scene.function, forward: forward, rewind: rewind)
        case .follow(let animation):
            FollowStage(function: scene.function, animation: animation)
        }
    }
}

/// A caption in a dark capsule, over a shader.
@View
struct Readout {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .padding(16)
    }
}

/// A hint at the top of a stage, faded out while `isHidden`.
@View
struct Hint {
    let text: String
    let isHidden: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .opacity(isHidden ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: isHidden)
            .padding(.top, 20)
    }
}

/// A shader at `playhead`, and a readout of it.
@View
struct PlayheadCanvas: Animatable {
    let function: ShaderFunction
    /// Seconds of shader time.
    var playhead: Double

    var animatableData: Double {
        get { playhead }
        set { playhead = newValue }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Shader(function, arguments: [.float("playhead", Float(playhead))])
            Readout(text: String(format: "playhead  %.2f s", playhead))
        }
    }
}

/// A shader whose clock a tap plays forward and back.
@View
struct PlayheadStage {
    let function: ShaderFunction
    let forward: Double
    let rewind: Animation

    /// Where the shader is showing. 0 is where it started.
    @State private var playhead = 0.0
    @State private var isPlaying = false

    var body: some View {
        PlayheadCanvas(function: function, playhead: playhead)
            .onTapGesture { play() }
            .overlay(alignment: .top) {
                Hint(text: "Tap to play", isHidden: isPlaying)
            }
    }

    /// Forward, then back — each leg an ease in and out, the second
    /// started by the first's completion. A tap while it plays is ignored.
    private func play() {
        guard !isPlaying else { return }
        isPlaying = true
        withAnimation(.easeInOut(duration: forward)) {
            playhead = forward
        } completion: {
            withAnimation(rewind) {
                playhead = 0
            } completion: {
                isPlaying = false
            }
        }
    }
}

/// A glow at `light`, and a readout of it.
@View
struct LightCanvas: Animatable {
    let function: ShaderFunction
    /// In points, from the view's top left.
    var light: Point
    @Environment(\.displayScale) private var scale

    var animatableData: Point.AnimatableData {
        get { light.animatableData }
        set { light.animatableData = newValue }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The shader works in pixels.
            Shader(function, arguments: [.float2("light", Float2(light.x * scale, light.y * scale))])
            Readout(text: String(format: "light  %3.0f, %3.0f", light.x, light.y))
        }
    }
}

/// A glow that goes wherever it is tapped — from wherever it is showing,
/// so a tap mid-move turns it round.
@View
struct FollowStage {
    let function: ShaderFunction
    let animation: Animation

    /// Where it starts: the middle of the window as it opens.
    @State private var light = Point(x: 360, y: 260)
    @State private var hasMoved = false

    var body: some View {
        LightCanvas(function: function, light: light)
            .onTapGesture { point in
                hasMoved = true
                withAnimation(animation) { light = point }
            }
            .overlay(alignment: .top) {
                Hint(text: "Tap to move the light", isHidden: hasMoved)
            }
    }
}

// MARK: - Tab bar

/// A pill per scene, with a highlight on the selected one. A tap only
/// reports the choice; moving the highlight is the owner's to animate.
@View
struct SceneTabBar {
    let selection: String
    let onSelect: @MainActor (String) -> Void

    private let itemWidth = 140.0
    private let itemHeight = 34.0

    var body: some View {
        let index = ShaderScene.all.firstIndex { $0.id == selection } ?? 0
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: itemWidth, height: itemHeight)
                .offset(x: Double(index) * itemWidth)
            HStack(spacing: 0) {
                ForEach(ShaderScene.all) { scene in
                    Text(scene.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(scene.id == selection ? .white : Color.white.opacity(0.55))
                        .frame(width: itemWidth, height: itemHeight)
                        .onTapGesture { onSelect(scene.id) }
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

// MARK: - App

@View
struct AnimatableShaderView {
    @Environment(\.colorScheme) private var system

    /// The tab the highlight is on, or sliding to.
    @State private var selection = ShaderScene.all[0].id
    /// The scene on screen: the tab's, once the highlight has arrived.
    @State private var shown = ShaderScene.all[0].id
    /// Where the next scene comes in from: the side the highlight went.
    @State private var entry = Edge.trailing

    var body: some View {
        ZStack(alignment: .bottom) {
            // Just the shown scene, so a new one is a new stage with its
            // playhead at 0 — and a transition in and out. A shader ignores
            // opacity, so it is the move half of `push` that shows on it.
            // In a stack of its own, so the one leaving is drawn under the
            // tab bar rather than over it.
            ZStack {
                ForEach(ShaderScene.all.filter { $0.id == shown }) { scene in
                    SceneStage(scene: scene)
                        .transition(.push(from: entry))
                }
            }
            SceneTabBar(selection: selection) { select($0) }
                .padding(.bottom, 16)
        }
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }

    /// Slide the highlight over, then push the scene in behind it.
    ///
    /// `entry` is set first, with the highlight: the scene leaving takes
    /// its way out from the last time it was built, so it has to be
    /// rebuilt knowing the direction before it is removed.
    private func select(_ id: String) {
        guard id != selection else { return }
        let index = { (id: String) in ShaderScene.all.firstIndex { $0.id == id } ?? 0 }
        entry = index(id) > index(shown) ? .trailing : .leading
        withAnimation(.snappy) {
            selection = id
        } completion: {
            // A slide overtaken by a later tap arrives nowhere.
            guard id == selection else { return }
            withAnimation(.smooth(duration: 0.6)) { shown = id }
        }
    }
}

@main
struct AnimatableShaderApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Animatable Shader", width: 720, height: 520) {
            AnimatableShaderView()
        }
        .commands { AppearanceCommands() }
    }
}
