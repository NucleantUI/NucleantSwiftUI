# Handling input

Respond to clicks, taps, drags, pinches and keys, and let people edit
values with the built-in controls.

## Buttons and taps

A ``Button`` runs its action when a press is released inside it. Any view
can take a tap with `.onTapGesture`, optionally with the point in its own
coordinates:

```swift
Button("Reset") { level = 0 }

Text("Tap me").onTapGesture { location in
    print("tapped at", location.x, location.y)
}
```

## Drags

A ``DragGesture`` reports where a drag started, where it is, how far it has
moved, and the view's own bounds — so a position becomes a fraction without
a geometry reader:

```swift
@View
struct Fader {
    @Binding var level: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.fill)
            Capsule().fill(Color.blue).relativeSize(width: level)
        }
        .frame(height: 8)
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .gesture(
            DragGesture().onChanged { value in
                level = min(1, max(0, value.location.x / value.bounds.width))
            }
        )
    }
}
```

## Taps, holds, pinches and twists

``TapGesture``, ``LongPressGesture``, ``MagnifyGesture`` and
``RotateGesture`` attach with `.gesture(_:)` like a drag. A pinch or a twist
is two fingers on a touch screen, or the trackpad on a Mac:

```swift
@View
struct Photo {
    let image: RasterImage
    @State private var scale = 1.0
    @State private var pinch = 1.0
    @State private var angle = Angle.zero
    @State private var twist = Angle.zero

    var body: some View {
        Image(image)
            .scaleEffect(scale * pinch)
            .rotationEffect(angle + twist)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in pinch = value.magnification }
                    .onEnded { value in scale *= value.magnification; pinch = 1 }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { value in twist = value.rotation }
                    .onEnded { value in angle += value.rotation; twist = .zero }
            )
            .onTapGesture(count: 2) { scale = 1; angle = .zero }
    }
}
```

`.onTapGesture(count:)` and `.onLongPressGesture` are the shorthands.

When a press reaches several gestures — a button inside a draggable panel, a
double tap and a single tap on one view — they compete as in SwiftUI: a
`.gesture` goes after the gestures of the views inside it, a
`.highPriorityGesture` goes before them, and a `.simultaneousGesture` runs
alongside everything. Put a double tap before a single tap on the same view;
the single tap then waits until a second tap can no longer come.

## What can be hit

`.allowsHitTesting(false)` lets presses, hovers and drops through a view to
whatever is behind it — a label over a canvas, a decoration over a control.
`.contentShape(_:)` makes a shape the area a press must land in: a round
button that ignores its corners.

## Focus and keys

A text field takes the keys when pressed; `.focusable()` lets any view take
them, and Tab moves between them. `@FocusState` with `.focused(_:equals:)`
says which view has the keys and moves them when set. `.onKeyPress` handles
keys while its view, or one inside it, has them:

```swift
@View
struct Board {
    let game: Game
    @FocusState private var isFocused: Bool

    var body: some View {
        BoardCells(game: game)
            .focusable()
            .focused($isFocused)
            .onKeyPress(.leftArrow) { game.move(.left); return .handled }
            .onKeyPress(.rightArrow) { game.move(.right); return .handled }
            .onAppear { isFocused = true }
    }
}
```

`.onSubmit` runs when a text field inside the view is submitted;
`.submitScope()` keeps a submission from reaching the `.onSubmit` actions
further out.

## Controls

``Toggle``, ``Slider``, ``Stepper``, ``Picker``, ``TextField``,
``SecureField`` and ``TextEditor`` edit a value through a binding:

```swift
@View
struct Settings {
    @State private var name = ""
    @State private var volume = 0.7
    @State private var tempo = 120
    @State private var isMuted = false
    @State private var meter = "4/4"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $name)
            Slider(value: $volume, in: 0...1)
            Stepper("Tempo \(tempo)", value: $tempo, in: 40...240)
            Toggle("Mute", isOn: $isMuted)
                .toggleStyle(.switch)
            Picker("Meter", selection: $meter) {
                ForEach(["3/4", "4/4", "6/8"], id: \.self) { meter in
                    Text(meter).tag(meter)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
    }
}
```

## Menus, popovers and drag and drop

`.contextMenu { … }` opens a menu of ``Button``s, ``Divider``s and nested
``Menu``s on a right click, or a press held still on a touch screen.
`.popover(isPresented:content:)` shows arbitrary views in a panel pointing at
the view. `.draggable(_:)` and `.dropDestination(for:action:)` move
``Transferable`` values between views.
