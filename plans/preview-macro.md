# gain the ability to use something like #Preview in UIKit

on macOS / iOS the render is hosted in NSView / UIView

is there a way we can use the #Preview concept when using xcode? 

## Findings

Yes — through the AppKit / UIKit form of `#Preview`, which takes a view:

```swift
#Preview("Track row") {
    HostingView(root: TrackRow(track: .demo))   // an NSView on macOS, a UIView on iOS
}
```

What that needs, and what is in the way today:

* `#Preview` is `DeveloperToolsSupport`'s macro; SwiftUI, AppKit and UIKit
  each declare an overload of it (`SwiftUI.View`, `NSView`/`NSViewController`,
  `UIView`/`UIViewController`). `Preview` itself has **no public
  initializer** — each framework's `init(_:traits:body:)` is its own — so a
  third party cannot add a `#Preview { someNucleantView }` overload through
  it. The expansion is small, though (a `PreviewRegistry` struct with
  `fileID`/`line`/`column` and `makePreview()` calling
  `DeveloperToolsSupport.Preview { NSView }`), so our own macro could emit
  the same shape with the body wrapped in a `HostingView`. Whether Xcode's
  canvas accepts a registry it did not generate is only answerable in
  Xcode — a follow-up, not the first step.
* `#Preview` compiles under plain `swift build` (checked: the macro plugin
  ships with the toolchain), so previews can sit in the package sources
  without a second build path.
* The render is **not** hosted in a view today. `HostingWindow` is the
  unit: it owns the engine, the ThorVG canvas, the `ViewHost`, and gets
  its display link and input from `PlatformWindow` (`NucleantApplication`),
  which is an `NSWindow`/`UIWindow` that routes events to a delegate. The
  `VulkanView` inside it is a bare `CAMetalLayer` view. A preview shows a
  *view* in its own window, so the engine + canvas + host + display link
  + input have to move down one level.
* All Apple-side dependencies are xcframework binary targets (MoltenVK,
  ThorVG, libomp, wgpu, shaderc, spirv-cross), which Xcode embeds for a
  preview host the way it does for an app; the `@View` macro plugin is
  already trusted for the Xcode projects. Loading those in
  `XCPreviewAgent` is the one thing to verify in the canvas rather than
  reason about.

## Outcome (2026-09-17) — parked

Step 1 was done, the rest was tried in Xcode's canvas and got most of
the way; all of it is **reverted and parked** — the app layer stays as
it was until the blockers below are worth the time. Nothing from this
is left in the tree but this file.

### Reverted: `HostingView`

Step 1 was built and verified, then reverted with the rest — the tree
is exactly as before this work; only this file remains. What it was, so
it can be redone: an `NSView` / `UIView` (`App/HostingView.swift`)
owning the engine over its own `CAMetalLayer`, the ThorVG canvas, the
`ViewHost`, a display link (`NSView.displayLink(target:selector:)` /
`CADisplayLink`, started in `viewDidMoveToWindow` / `didMoveToWindow`,
weak-proxy target), resize in `setFrameSize` / `layoutSubviews`, the
mouse / scroll / right-click / touch overrides (view flipped, so no
y conversion), and light/dark from `viewDidChangeEffectiveAppearance` /
`UITraitUserInterfaceStyle`; the platform-free part as a `HostCore`
shared by both. `HostingWindow` then became a plain `NSWindow` /
`UIWindow` holding one, forwarding its `NucleantWindow` witnesses. It
passed: the demo driven as usual (clicks, fader, hover, context menu
and submenu, resize, system light/dark flip, Shaders screen),
`xcodebuild` for macOS and the iOS simulator, and a scratch AppKit app
embedding it next to an `NSTextField` with no `NucleantApp` at all.

### Tried in the canvas, and where it stopped

A `#Preview("…") { HostingView(root: RootView()) }` in a package the app
project links, Xcode 26.3, macOS destination. In order:

1. **"Active scheme does not build this file"** for a preview file under
   the *package's* `Sources/` when opened through an `XcodeExamples`
   project: Xcode treats a file under a package root as the package's,
   and the app scheme does not build the package's executable target.
   Also hit "couldn't load NucleantSwiftUI because it is already opened
   from another project" — the same local packages cannot be open in two
   Xcode windows at once. Previews have to be tried from *one* project
   that links the package, with the preview file in a target that
   project builds.
2. **`'Counter' cannot be constructed because it has no accessible
   initializers`** inside the `#Preview` braces, for any `@View` struct
   without a hand-written `init`. The braces are the macro's *argument*,
   and the compiler type-checks a macro's arguments without looking into
   other macros' expansions — the initializer `@View` generates is one.
   `RootView` in BabyLights has `public init() {}` and is fine; the
   demo's views are not. Only workarounds exist (a helper function
   outside the braces, or a wrapper view with its own `init`), which is
   not the SwiftUI experience and the reason this is parked.
3. **"Compiling failed: no such module 'SwiftUI'"** — the canvas compiles
   the file's preview thunk against SwiftUI whether or not the file
   uses it, and in this package build it could not find it. Adding
   `import SwiftUI` to the preview file gets past it (names both
   modules have, `View` first of all, then need qualifying). Untested
   guess: explicit modules (`SWIFT_ENABLE_EXPLICIT_MODULES`) leave
   SwiftUI out of the package target's module set.
4. **"Runtime linking failure"** — the preview agent JIT-links the
   package's object files (`NucleantVulkan.o`, `CThorVG.o`, …) and
   resolves symbols against what is loaded in its process. The binary
   targets' dynamic libraries — `MoltenVK.framework`, `ThorVG.framework`,
   `libwgpu_native.dylib` — sit in the products directory (it is on the
   agent's `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH`) but nothing
   loads them, so every `vk*` and `tvg_*` symbol is missing. Autolink
   hints in the C modules' maps do get them loaded:
   `link framework "MoltenVK"` in `NucleantVulkan/Sources/CVulkan/
   module.modulemap`, `link framework "ThorVG"` in `NucleantThorVG/
   Sources/CThorVG/include/module.modulemap`, `link "wgpu_native"` in
   the `wgpu_native.xcframework` module maps (and `build_wgpu.py`). With
   the first two the `vk`/`tvg` errors went away and the agent crashed
   inside Xcode's JIT error path instead (`XOJIT
   XPCMemoryManager::release`, from `AsynchronousSymbolQuery::
   handleFailed`) — i.e. a *further* symbol group still fails. With the
   wgpu hint added as well it reported "Runtime linking failure" again;
   which symbols was not read before stopping. `spirv-cross` is a
   static `.a` binary target and may be the next one. Those hints
   are reverted; `CThorVG` is shared with Linux/Android where
   `link framework` would be wrong, so they would need an Apple-only
   module map (own `publicHeadersPath`) anyway.

### Rule for when this is picked up

**Do not change how the app runs.** `HostingWindow`, `PlatformWindow`,
`AppRuntime` and the `NucleantApp` launch path stay exactly as they
are. A preview host is an *alternative*, additive way to run a tree —
a separate view class that nothing on the app path depends on — and
that is the only shape it may take.

### What "working" means

A `#Preview` **in the same file as the view**, under the view, with no
extra imports, no helper functions, no wrapper types — the SwiftUI
experience, where editing the source and watching the canvas is one
window. A preview that needs its own file is not a solution: every
edit means switching away from the preview and back. So the two
blockers that pushed the preview into a separate file are the actual
work, and "put `import SwiftUI` in a separate file" is not an answer.

### To do, when picked up

* A separate `HostingView` (as sketched above) added *beside* the app
  path, `HostingWindow` untouched.
* **`import SwiftUI` must not be the user's problem.** The thunk fails
  with "no such module 'SwiftUI'" because SwiftUI is not in the target's
  (explicit) module set, and a plain `import SwiftUI` in the view's file
  clashes with `View`, `Text`, … First thing to try: let the *framework*
  bring the module in — one file in NucleantSwiftUI with a scoped
  import that adds no names (`#if canImport(SwiftUI)
  import protocol SwiftUI.PreviewProvider #endif`), so SwiftUI is a
  transitive dependency of every client target and the thunk's own
  `import SwiftUI` resolves. If a client-side import turns out to be
  needed after all, the same scoped form in the view's file imports the
  module without the name clash. Untested either way.
* **`#Preview { HostingView(root: Counter()) }` must work for a plain
  `@View` struct.** The macro's braces cannot see `@View`'s generated
  init. Candidates: a package macro that takes the *type*
  (`#Preview(Counter.self)` — the expansion, not the argument,
  constructs it; untested whether Xcode's canvas accepts a registry it
  did not generate), or a `@View` change that makes the init visible
  from macro arguments (none known; the exclusion is the compiler's).
* Then the JIT linking (4 above), with the autolink hints Apple-only.
* If the canvas renders: verify light/dark trait, `fixedLayout`,
  interaction, and the iOS simulator canvas.
* If it does not: `HostingView` would still be worth having as the
  embedding API, on its own merits — but as its own decision.
