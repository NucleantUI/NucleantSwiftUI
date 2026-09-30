# Handling input

Respond to clicks, taps and drags, and let people edit values with the
built-in controls.

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
