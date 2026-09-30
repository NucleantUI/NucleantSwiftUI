# Managing state

Keep a view's own UI state in `@State`, pass it down with bindings, and put
the data your app works on in an `@Observable` model.

## A view's own state

``State`` is storage that outlives the `body` that reads it. It is kept by the
view's position in the tree, so it survives rebuilds, and a write to it
rebuilds the views that read it:

```swift
@View
struct DisclosureButton {
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading) {
            Button(isExpanded ? "Hide details" : "Show details") {
                isExpanded.toggle()
            }
            if isExpanded {
                Text("Here are the details.")
            }
        }
    }
}
```

Use `@State` for state that belongs to the interface — whether a panel is
open, how far something is dragged — not for the data the app is about.

## Bindings

A ``Binding`` reads and writes a value owned somewhere else. `$name` on a
`@State` property gives one, and a binding projects into the value it
refers to by key path:

```swift
@View
struct VolumeControl {
    @Binding var level: Double

    var body: some View {
        HStack {
            Text("Volume")
            Slider(value: $level)
        }
    }
}

@View
struct Player {
    @State private var level = 0.5

    var body: some View {
        VStack {
            VolumeControl(level: $level)
            Text("\(Int(level * 100))%")
        }
    }
}
```

`Binding.constant(_:)` stands in where nothing needs to change.

## Models are `@Observable` classes

Data that changes over time — a document, a session, a list being edited — is
a `@MainActor @Observable final class`, changed through its own methods. The
view that owns it holds it in `@State`; views below take it as a plain `let`,
or as `@Bindable` when they need a binding into one of its properties:

```swift
import NucleantUI
import Observation

@MainActor @Observable
final class Playlist {
    struct Track: Identifiable {
        let id: Int
        var title: String
        var rating: Double
    }

    private(set) var tracks: [Track] = [
        Track(id: 0, title: "Intro", rating: 0.6),
        Track(id: 1, title: "Theme", rating: 0.9),
    ]

    func rate(_ id: Int, _ rating: Double) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].rating = rating
    }
}

@View
struct PlaylistScreen {
    @State private var playlist = Playlist()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(playlist.tracks) { track in
                TrackRating(playlist: playlist, track: track)
            }
        }
    }
}

@View
struct TrackRating {
    let playlist: Playlist
    let track: Playlist.Track

    var body: some View {
        HStack {
            Text(track.title).frame(width: 80, alignment: .leading)
            Slider(value: Binding(
                get: { track.rating },
                set: { playlist.rate(track.id, $0) }
            ))
        }
    }
}
```

Every property a `body` reads is tracked, down to the key path. A write —
from a binding, a button, a timer, or a task coming back to the main actor —
rebuilds only the views that read what changed: moving one track's slider
rebuilds that row, not the list.

## The environment

``Environment`` reads values that flow down the tree: `\.font`,
`\.foregroundColor`, `\.tint`, `\.isEnabled`, `\.colorScheme`,
`\.displayScale` and others. Set them for a subtree with the matching
modifier — `.font(_:)`, `.tint(_:)`, `.disabled(_:)`, `.colorScheme(_:)` —
or with `.environment(_:_:)`.

## Light and dark

The window follows the system appearance. Semantic colors adapt on their own
— `Color.primary`, `.secondary`, `.background`, `.secondaryBackground`,
`.separator`, `.fill` — and `Color.dynamic(light:dark:)` makes your own.
`.colorScheme(.dark)` fixes a subtree, shaders included.
