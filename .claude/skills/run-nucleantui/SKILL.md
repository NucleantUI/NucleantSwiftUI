---
name: run-nucleantui
description: Build, launch, click through and screenshot NucleantUI apps on macOS — any Examples/<Name> app (Reader, MindMap, Tasks, …) or NucleantUIDemo — and run the NucleantUI tests. Use when asked to run, start, open, drive, click, type into, scroll or screenshot an example or the demo, check a UI change in the real app, or run NucleantUI's test suite.
---

NucleantUI apps are native macOS windows drawn through Vulkan (MoltenVK).
Drive them with `.claude/skills/run-nucleantui/driver.sh`: it builds and
launches an app in the background, then screenshots its window and posts
real mouse/scroll/key events at points in it (CoreGraphics, via the
`gui.swift` helper it compiles on first use).

All paths below are relative to `NucleantUI/`. Verified on macOS 26
(Darwin 25.6), Apple Swift 6.3.3 — macOS only; iOS/Linux/Android builds
are not covered here.

## Prerequisites

- Xcode / Swift 6.2+ toolchain (`swift --version`).
- The umbrella checkout: `NucleantUI` next to its sibling submodules
  (`../NucleantVulkan`, `../NucleantSkia`, …). `Package.swift` uses them as
  path dependencies when `../NucleantVulkan` exists. MoltenVK and ThorVG
  come in as frameworks — no Vulkan SDK install needed.
- The app hosting the shell (Terminal / VS Code) needs Accessibility
  (to post events), Screen Recording (to capture another app's window)
  and Automation → System Events (to raise the app). They were already
  granted where this was written.

## Run (agent path)

```bash
D=.claude/skills/run-nucleantui/driver.sh
$D list                      # every Examples/<Name> + NucleantUIDemo
$D launch Reader             # build (debug), start, wait for the window + first frame
$D ss 01-library             # -> .build/run/shots/01-library.png   560x792 pt   scale 1
$D click 280 330             # window point = screenshot pixel / scale (title bar included)
$D click 280 548             # "Start Reading"
$D scroll 280 400 -400       # dy < 0 moves down the page
$D ss 02-reading
$D quit
```

Keyboard and drags (MindMap — select a topic, Tab adds a child and focuses
its title field):

```bash
$D launch MindMap
$D click 960 340             # select "Product"
$D key 48                    # Tab
$D type "Typed by driver"
$D key 0 cmd                 # ⌘A
$D drag 520 556 520 720      # drag the "Risks" bubble down
$D ss mm-02
```

The package's own demo launches the same way; `click x y 2` is a double
click:

```bash
$D launch NucleantUIDemo
$D click 528 214 2
```

| command | what it does |
|---|---|
| `launch <App>` | `swift build --product <App>` in its package, kill any running copy, start it, print `window <id> <pid> x y w h` |
| `ss [name]` | `screencapture` of the window (no shadow) → `.build/run/shots/<name>.png`, prints size in points and the scale |
| `click <x> <y> [count]` | raise the app, click (count 2 = double click) |
| `drag <x0> <y0> <x1> <y1>` | press, move in 20 steps, release |
| `scroll <x> <y> <dy>` | pixel wheel events at the point |
| `key <code> [cmd,shift,alt,ctrl]` | one key, modifiers pressed and released as real keys |
| `type <text>` | unicode key events, one per character |
| `window` / `quit` / `release` | window geometry / kill the app launched last (others keep running) / let go of every modifier system-wide |

Every input command waits `$SETTLE` s (default 0.5) so the next frame is
drawn before a screenshot. Logs: `.build/run/<App>.log`. Key codes the
tests use are in `Tests/NucleantUITests/Support.swift` (`KeyCode`).

## Run (human path)

```bash
cd Examples/Reader && swift build && .build/debug/Reader   # window opens; ⌘Q or Ctrl-C to stop
```

## Test

Most framework changes are checked without a window: `Harness` in
`Tests/NucleantUITests/Support.swift` hosts a view tree in a window-less
`ViewHost` and takes taps, drags and keys the way a window would.

```bash
swift test                                          # 100 tests, ~10 s once built
swift test --filter NavigationBarVisibilityTests    # one suite
```

A new suite must be nested in `extension HostedViews` (a `.serialized`
suite): every host shares `Invalidator.shared`, so two running at once
take each other's state changes.

## Gotchas

- **The window is found by process name, not title.** `NucleantUIDemo`'s
  window is titled "Nucleant SwiftUI Demo"; examples happen to match.
- **Coordinates include the title bar** (32 pt here): a point in a
  `ss` screenshot ÷ its scale is the point to click. Windows on a second
  display have negative global coordinates (`-1240 95` here) — irrelevant,
  since the driver works in window points.
- **The window exists before anything is drawn in it** — the Vulkan
  swapchain comes up after. `launch` waits 1.5 s past the window
  appearing; a screenshot sooner can be blank.
- **Events go to whatever window is under the point.** A CLI process
  can't activate another app itself (cooperative activation), so the
  driver raises the app through System Events before every input —
  verified with Finder in front.
- **A modifier flag on a synthetic key event latches system-wide.** The
  first version posted ⌘A as one event carrying `.maskCommand`; macOS then
  treated ⌘ as held for *every* app — the next `type "X"` arrived as ⌘X
  and cut the field. `key` now presses and releases the modifier keys
  themselves and every typed character carries empty flags.
- **Each example is its own package with its own `.build`**, so the
  first build of an example compiles NucleantUI and its dependencies
  again; later builds are incremental (MindMap: 16 s after a framework
  change).
- **`[mvk-warn] VK_ERROR_FEATURE_NOT_PRESENT: Metal does not support
  disabling primitive restart.`** fills the log on every launch — noise.

## Troubleshooting

- **Typed text does nothing, or turns into shortcuts** (a field emptied
  by ⌘X): a modifier is stuck down system-wide. `$D release` — it prints
  `modifiers held now: 0x0` when clear.
- **`nothing launched — driver.sh launch <App>`**: no app recorded in
  `.build/run/current` (never launched, or `quit` ran). Launch one.
