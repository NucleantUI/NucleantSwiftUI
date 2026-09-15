# Xcode examples

Goal: the Nucleant packages all build for iOS, so give NucleantSwiftUI a
place to prove that — Xcode projects over the existing sources, iOS first,
macOS from the same project. Notes on what was done and why are in
[README.md](README.md).

## Done

- [x] `NucleantSwiftUIDemo/` — xcodegen project (`project.yml` + generated,
      checked-in `.xcodeproj`) whose app target compiles
      `Sources/NucleantSwiftUIDemo` directly and depends on the package at
      `../..`. One target, destinations iOS + macOS.
- [x] Library launches as a real iOS app: `AppRuntime.run()` on iOS now calls
      `UIApplicationMain` with a non-generic delegate pair
      (`_AppLaunchDelegate` / `_AppSceneDelegate`) instead of calling
      `onStart()` and returning. `HostingWindow` imports
      `NucleantApplication` for `ActiveScene` — the iOS branch had never been
      compiled before.
- [x] Verified: builds for `iOS Simulator` and `macOS` with `xcodebuild`;
      runs on an iPhone 17 simulator (MoltenVK on the simulator GPU, ThorVG
      canvas, the full mixer drawn) and as a macOS `.app` (window, dark
      appearance, frameworks embedded from the package binary targets).
- [x] Plain `swift build` still builds the package and the demo executable.

## Verified on a device (iPad Pro 11" M1, iPadOS 26)

Running it there found three things the simulator and an Intel Mac never
show, all fixed:

- [x] **Black screen.** MoltenVK binds descriptors through Metal 3 argument
      buffers on Apple silicon, and the composite pass's sampled image —
      imported from the wgpu `MTLTexture` ThorVG draws into — came back as
      zeros that way. `VulkanRenderEngine` now sets
      `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS = never` through
      `VK_EXT_layer_settings` at instance creation. (Would have hit any
      M-series Mac too.)
- [x] **No text.** `FontRegistry` looked for macOS-style `Family Bold.ttf`
      files in macOS directories. Roboto / Roboto Mono are now bundled with
      the library as the default and monospaced faces (`Resources/Fonts`,
      via `Bundle.module`), and system lookups go through CoreText, which
      knows the file for a family on both platforms.
- [x] **No touch scrolling.** `ScrollView` only listened to wheel deltas.
      `ViewHost.scrollsOnDrag` (on for iOS) turns a moving finger into
      scroll deltas for the innermost `ScrollView` under it; a drag-taking
      view (fader) keeps the finger, a press-only view (button) is released
      without its tap once the finger has clearly moved.
- [x] Taps, navigation pushes and faders work by touch.

## Not yet verified

- [ ] Rotation / Stage Manager resizing (`windowScene(_:didUpdateEffectiveGeometry:)`
      reports screen bounds, `layoutSubviews` the window's — check which wins).
- [ ] Scroll momentum — a fling stops dead when the finger lifts.

## Seen on iOS, to fix in the framework or the demo

- The demo's layout is the 900×620 desktop one; on a phone the header wraps
  and the button row overlaps. Either a compact layout in the demo or
  something like SwiftUI's size classes in the environment.
- The window ignores the safe area: the navigation bar title sits under the
  Dynamic Island / status area. `HostingWindow.presentIOS` should inset the
  root by the window's `safeAreaInsets`, or expose them in the environment
  for `NavigationStack` to use.
- The appearance is seeded once on iOS (`presentIOS` comment) — a light/dark
  switch while running is not tracked yet, unlike macOS.

## Examples as Xcode projects

- [x] [Sampler](Sampler) — `project.yml` copied from the demo's, sources
      from `Examples/Sampler/Sources/Sampler`, dependency still the library
      at `../..`. Builds for the iPad and macOS; runs on the iPad
      (AVFoundation and Accelerate are the same on both).
- [ ] Calculator, Tasks, Sketch, Dashboard, TwentyFortyEight, Pomodoro —
      same recipe, one directory each. Worth doing after the phone-width
      layout question is settled, since those were laid out for a desktop
      window too.
