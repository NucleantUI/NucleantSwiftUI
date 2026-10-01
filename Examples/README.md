# Examples

Sixteen small apps, each a standalone SwiftPM package that depends on
NucleantUI from the enclosing checkout (`.package(path: "../..")`).
Build and run any of them from its own directory:

```sh
cd Examples/Calculator
swift build && .build/debug/Calculator
```

To start your own app from one, copy the directory and change the
dependency to
`.package(url: "https://github.com/NucleantUI/NucleantUI.git", branch: "master")`.

| Example | Kind of app | What it shows |
| --- | --- | --- |
| [Calculator](Calculator) | utility | a keypad of custom controls (`DragGesture` with a pressed state, release-inside to fire), a value-type engine, flexible rows |
| [Tasks](Tasks) | list + detail | `ForEach` over indices bound into an array (`$tasks[index]`), a detail screen pushed by `NavigationLink` editing through the same `Binding`, deleting via a flag and `navigationRouter.pop()`, filters as tap targets |
| [Sketch](Sketch) | canvas | a `DragGesture` collecting points into a `PathShape` stroke, finished strokes as reusable child views, colour and brush pickers, undo |
| [Dashboard](Dashboard) | data display | line, bar and ring charts drawn with `PathShape`, gradients and `.relativeSize`; stat tiles; a segmented period switch; a scrolling feed |
| [TwentyFortyEight](TwentyFortyEight) | game | a swipe (`DragGesture.onEnded` + `translation`) driving a value-type board, the whole game in one `@State`, arrow buttons for a mouse |
| [Pomodoro](Pomodoro) | timer | a Foundation `Timer` on the main run loop writing `@State` once a second; an analog clock and a progress ring as `PathShape`s |
| [Sampler](Sampler) | audio | `@Observable` models as the source of truth (`Sample`, `SampleBank`, an envelope filled in by a background reduction), `@Bindable` faders, a waveform drawn by a `Shader` fed `ShaderArgument` float arrays, vDSP synthesis and `concurrentPerform` min/max reduction, real playback through `AVAudioEngine`, a 60 Hz playhead written to the model from a timer |
| [Flashcards](Flashcards) | study / animation | every part of the animation API doing a job: a card that follows a `DragGesture` and is sprung back (`withAnimation(.bouncy)`) or flung off with `withAnimation(_:_:completion:)`, whose completion deals the next card; the next card arriving through a one-element `ForEach` so `.transition` applies; a flip as an `Animatable` view that swaps faces halfway; a head-shake `AnimatableModifier` under `.animation(_:value:)`; an animatable `Shape` progress ring; numbers that count through their `animatableData`; a `TimelineView` clock; a results screen sliding in over the deck, its score rolled up by a `CustomAnimation` and its rows staggered with `.delay` |
| [AnimatableShader](AnimatableShader) | shader / animation | four shaders kept as bundled PyShader `.py` files, three with their clock replaced by a `playhead` `ShaderArgument` and one — a glow — taking its position as a `light` argument; an `Animatable` view with the playhead as its `animatableData`, so `withAnimation` drives the shader — a tap plays it forward and the completion rewinds it, each scene with its own timing (2 s and 2 s; 8 s forward and a 2 s rewind); a `CustomAnimation` rewind that overshoots and bounces into place; the glow following each tap as an `Animatable` point under a `Wiggle` `CustomAnimation` — most of the way at once, then shrinking swings onto the spot; a custom tab bar whose highlight slides over first, the scene following in that animation's completion with a `.push(from:)` transition in the direction the highlight went |
| [Finder](Finder) | file browser | a Finder list view over an `@Observable` file tree: nested `DisclosureGroup`s built recursively (a folder's content is its children's rows), each bound to `$node.isExpanded` through `@Bindable`; a custom `DisclosureGroupStyle` that stacks label over content so the columns stay aligned while only the name indents; New Folder / Move to Trash editing the tree, and a download growing from a timer, landing in the rows that show them; a `.contextMenu` per row (expand, new folder, duplicate, trash) ending in a row of tag colours that closes the menu through `@Environment(\.contextMenu)`; a sidebar of places with back/forward history |
| [Metronome](Metronome) | audio / settings | an `@Observable` metronome whose settings are the framework's controls through `@Bindable`: a `Stepper` for the tempo (hold to repeat), `Slider`s for tempo and volume with value labels, `Picker` in four styles — the meter as `.segmented` (a `ForEach` tagging each segment with its id), the sound as the default pop-up menu (explicit `.tag`s and a `Divider`), the subdivision as `.radioGroup`, and presets as `.inline` over an optional selection — and `Toggle` as `.switch`, the default checkbox, and a `.button` for Start/Stop; clicks synthesised sample by sample by an `AudioProcessor` that NucleantAudio's `AudioPlayer` runs on the audio thread, with the beat lights read back at 60 Hz |
| [Issues](Issues) | issue tracker | the collections doing a tracker's job: a `.sidebar` `List` whose `Section`s hold the issue views (tagged rows with `.badge` counts) and the projects as an `OutlineGroup` that opens with its chevron or →; the issues in a `Table` sorted by a `KeyPathComparator` order a header click changes, columns bounded by `.width(min:ideal:max:)` and resized from their header edges, a set for the selection (⌘/⇧-click, ⇧-arrows, ⌘A), `.contextMenu(forSelectionType:)` with Status/Priority/Assignee submenus for the selection and a double click that opens the issue full-window, Delete through `.onDeleteCommand`; an inspector `Form` in `.grouped` style over the selected issue (bulk pickers showing "Mixed" for several), and Settings as a `.columns` `Form` — labels in their own column, section headers beside their first rows |
| [Photos](Photos) | photo library | twenty thousand photos in lazy containers: the library and favourites as a `LazyVGrid` with `.adaptive` columns sized by a zoom `Slider`, a `Section` per month whose header is pinned (`pinnedViews: [.sectionHeaders]`) while the month scrolls under it; Days as a sideways `LazyHGrid` of three flexible rows, each day's header a pinned column; Albums as a `LazyHStack` strip of covers over a `LazyVStack` of rows in pinned groups; an info pane laid out by a `Grid` — labels right-aligned with `gridColumnAlignment`, values across columns with `gridCellColumns`, rules and an empty cell kept out of the sizing with `gridCellUnsizedAxes`; only the tiles near the visible part are ever built |
| [Bookmarks](Bookmarks) | reading list | custom `Layout`s doing a reading list's job: the shelf a `ShelfLayout` — a masonry whose featured cards span two columns through a `ColumnSpan` layout value, and a list — with the column width and how far it is towards the list as its `animatableData`, so zooming grows the cards and switching to the list morphs every card into its row, each card's own `BookmarkTileLayout` moving its badge, title, tags and marks to their places in the row as it goes; the sidebar's tags a `FlowLayout` cloud or a `VStackLayout` list, one `AnyLayout`, each chip travelling between the two; tags as removable chips wrapping in a `FlowLayout` in the inspector, and its actions in an `EqualWidthHStack`; preferences going *up* — the shelf naming itself to the window bar (`ScreenTitle`), and every card adding its bookmark to the count, unread and reading time the status bar shows (`ShelfTotals`) |
| [Moodboard](Moodboard) | collage / input | boards of photos, notes and stickers arranged by hand, every input feature doing a job: cards dragged, pinched (`MagnifyGesture`) and twisted (`RotateGesture` as a `.simultaneousGesture`) on a trackpad or with two fingers, the card's pinch going before the board's own pinch-to-zoom; double-click to reset (`TapGesture(count: 2)`), hold to pin (`.onLongPressGesture`, whose pressing state selects and lifts the card); Lock Photos turning the photos' input off with `.allowsHitTesting(false)` so presses reach the notes under them; round stickers and overlapping swatches that take clicks only inside their circles (`.contentShape`); a Present mode where a click anywhere, cards included, is "next" — a `.highPriorityGesture` on the board; one `@FocusState` for the window moving the keys between the board, the toolbar fields and the inspector (`.focused(_:equals:)`, `.onSubmit`), and the board as a `.focusable()` view handling arrows, delete, `[ ]`, `+ −` and `n` with `.onKeyPress` |
| [MindMap](MindMap) | mind mapping | every topic placed by `.position` — each bubble keeps its own size and its center lands on the topic's point, so the branch drawn to that point meets it in the middle, whatever its title; an `@Observable` map of topic structs changed through its methods; topics dragged with their whole branch and the canvas dragged to pan (the pan added to every point); Tidy Up rewriting every point inside `withAnimation`, the bubbles gliding because their position changed and the branches with them as a `Shape` whose two ends are its `animatableData`; folding a branch on double-click behind a +N badge, with an `.opacity` transition; Tab/Return to add a child or sibling straight into the title field through one `@FocusState`, Delete, Space and arrow keys walking the map with `.onKeyPress`; a sidebar `List` of maps with `.badge` counts and a `.contextMenu` |

Things worth knowing that the examples had to work around, since there is no
text input or timer API in the framework yet: "Add" in Tasks pulls from a
backlog instead of a text field; Pomodoro schedules its own `Timer` and
writes state from it, which the next frame picks up like any other write.

Every example has a System / Light / Dark switch in its View menu — the
same `Appearance.swift` in each package: an enum, an `@Observable`
`AppearanceModel` the menu writes to, `AppearanceCommands` (a `Commands`
with one `CommandMenu`, attached to the `WindowGroup` with
`.commands { AppearanceCommands() }`), and the root view applying
`.colorScheme(AppearanceModel.shared.appearance.scheme ?? system)` under
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
