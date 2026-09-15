# Xcode examples

Xcode projects over the same code the SwiftPM targets build, for the
platforms `swift run` cannot reach: iOS on a device or the simulator, and
macOS as a proper `.app` bundle. Each project depends on the enclosing
checkout as a local package (`path: ../..`), so it builds whatever is in the
working tree — the Nucleant packages underneath are resolved the same way
`swift build` resolves them (sibling checkouts when present, GitHub
otherwise; see `localDev` in [Package.swift](../Package.swift)).

| Project | Source | Runs on |
| --- | --- | --- |
| [NucleantSwiftUIDemo](NucleantSwiftUIDemo) | [Sources/NucleantSwiftUIDemo](../Sources/NucleantSwiftUIDemo) — the package's demo executable, unchanged | iOS 17+ (iPhone, iPad, simulator), macOS 14+ |
| [Sampler](Sampler) | [Examples/Sampler/Sources/Sampler](../Examples/Sampler/Sources/Sampler) — the drum sampler example (`@Observable` models, `Shader` waveform, AVAudioEngine) | iOS 17+, macOS 14+ |

Each project's app target is named `<Name>App` (`NucleantSwiftUIDemoApp`,
`SamplerApp`) to keep it apart from the SwiftPM executable of the same
name that Xcode also lists; pick the `…App` scheme.

## Building

Open a project (`NucleantSwiftUIDemo/NucleantSwiftUIDemo.xcodeproj`,
`Sampler/Sampler.xcodeproj`), pick its **…App** scheme and a destination,
run. The first build
stops on the `NucleantSwiftUIMacros` compiler plugin (`@View`, `#viewID`)
until you choose *Trust & Enable*; that is a one-time answer per machine.

The other schemes Xcode lists come from the library package itself.
`NucleantSwiftUIDemo` there is the SwiftPM *executable* — the same source as
a macOS command-line tool, not the app; running it on iOS fails at launch
with a message saying so.

From the command line:

```sh
cd XcodeExamples/NucleantSwiftUIDemo
xcodebuild -scheme NucleantSwiftUIDemoApp -destination 'platform=iOS Simulator,name=iPhone 17' -skipMacroValidation build
xcodebuild -scheme NucleantSwiftUIDemoApp -destination 'platform=macOS' -skipMacroValidation build
```

`-skipMacroValidation` is the command-line form of the trust prompt.

### Signing

The simulator and macOS need nothing: the target signs to run locally. A
real iOS device needs a team — set it once under *Signing & Capabilities*
(it is `DEVELOPMENT_TEAM` in `project.yml` if you want it to survive a
regeneration).

## Changing a project

To add another example, copy `Sampler/project.yml`, change the name, the
`sources` path and the bundle identifier, and run `xcodegen` in the new
directory.

`project.yml` is the source; the `.xcodeproj` is generated from it with
[xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
and checked in so nothing has to be installed to open it:

```sh
cd XcodeExamples/NucleantSwiftUIDemo && xcodegen
```

Edit the YAML, not the project — the next `xcodegen` overwrites the latter.

## How the iOS launch works

The demo's entry point is `@main struct DemoApp: NucleantApp` on both
platforms. On macOS `NucleantApp.main()` installs an `NSApplicationDelegate`
and runs `NSApplication`. On iOS it hands the process to `UIApplicationMain`
with the library's `_AppLaunchDelegate`; that delegate answers UIKit's
scene-configuration request with `_AppSceneDelegate`, which records the
connected `UIWindowScene` in `ActiveScene.current` and only then presents the
app's windows — a window built from the scene is what follows Stage Manager
resizing. The app's Info.plist therefore carries a `UIApplicationSceneManifest`
with **no** delegate class named (see `project.yml`); with no manifest at all
UIKit never connects a scene, and the library presents onto a screen-sized
frame from `didFinishLaunching` instead.
