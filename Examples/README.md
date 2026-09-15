# Examples

Seven small apps, each a standalone SwiftPM package that depends on
NucleantSwiftUI from the enclosing checkout (`.package(path: "../..")`).
Build and run any of them from its own directory:

```sh
cd Examples/Calculator
swift build && .build/debug/Calculator
```

To start your own app from one, copy the directory and change the
dependency to
`.package(url: "https://github.com/NucleantUI/NucleantSwiftUI.git", branch: "master")`.

| Example | Kind of app | What it shows |
| --- | --- | --- |
| [Calculator](Calculator) | utility | a keypad of custom controls (`DragGesture` with a pressed state, release-inside to fire), a value-type engine, flexible rows |
| [Tasks](Tasks) | list + detail | `ForEach` over indices bound into an array (`$tasks[index]`), a detail screen pushed by `NavigationLink` editing through the same `Binding`, deleting via a flag and `navigationRouter.pop()`, filters as tap targets |
| [Sketch](Sketch) | canvas | a `DragGesture` collecting points into a `PathShape` stroke, finished strokes as reusable child views, colour and brush pickers, undo |
| [Dashboard](Dashboard) | data display | line, bar and ring charts drawn with `PathShape`, gradients and `.relativeSize`; stat tiles; a segmented period switch; a scrolling feed |
| [TwentyFortyEight](TwentyFortyEight) | game | a swipe (`DragGesture.onEnded` + `translation`) driving a value-type board, the whole game in one `@State`, arrow buttons for a mouse |
| [Pomodoro](Pomodoro) | timer | a Foundation `Timer` on the main run loop writing `@State` once a second; an analog clock and a progress ring as `PathShape`s |
| [Sampler](Sampler) | audio | `@Observable` models as the source of truth (`Sample`, `SampleBank`, an envelope filled in by a background reduction), `@Bindable` faders, a waveform drawn by a `Shader` fed `ShaderArgument` float arrays, vDSP synthesis and `concurrentPerform` min/max reduction, real playback through `AVAudioEngine`, a 60 Hz playhead written to the model from a timer |

Things worth knowing that the examples had to work around, since there is no
text input or timer API in the framework yet: "Add" in Tasks pulls from a
backlog instead of a text field; Pomodoro schedules its own `Timer` and
writes state from it, which the next frame picks up like any other write.

Every example has a System / Light / Dark switch — the same `Appearance.swift`
in each package: an enum, a segmented picker built from tap targets, and
the root view applying `.colorScheme(appearance.scheme ?? system)` under
itself, where `system` is `@Environment(\.colorScheme)` (what the window
was seeded with, following System Settings). The themes use the
framework's semantic colors or `Color.dynamic(light:dark:)`, so a plain
`Color(hex:)` is the one thing that stays the same in both modes.

Layout habits that keep rows tidy: give the growing text in a row
`.frame(maxWidth: .infinity, alignment: .leading)` rather than a `Spacer`
after it (the fixed items are sized first, the text gets what is left);
to size a bar as a fraction of a whole, put it in a `ZStack` (each child is
offered the full rect) rather than under a `Spacer` in a `VStack`; and when
one column should be a fixed width and the other should stretch, say so
with `.frame(width:)` on the fixed one.
