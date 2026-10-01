# Laying out views

Arrange views with stacks and grids, size them with frames, and draw with
shapes, text and images.

## Stacks

``VStack``, ``HStack`` and ``ZStack`` place their children in a column, a row
or on top of each other, with an `alignment` and a `spacing`. ``Spacer``
takes the room that is left:

```swift
@View
struct Toolbar {
    var body: some View {
        HStack(spacing: 8) {
            Text("Library").font(.headline)
            Spacer()
            Button("Import") {}
            Button("Export") {}
        }
        .padding(12)
    }
}
```

## Sizing

A view is offered a size by its parent and picks its own. `frame` changes
what it picks:

```swift
Text("Fixed").frame(width: 120, height: 32)
Text("Fills the row").frame(maxWidth: .infinity, alignment: .leading)
Capsule().fill(Color.blue).relativeSize(width: 0.3)   // 30% of what is offered
```

`relativeSize(width:height:)` sizes a view as a fraction of what its parent
offers — a progress bar is a ``Capsule`` in a ``ZStack`` sized this way,
without a geometry reader. `.aspectRatio(_:contentMode:)`, `.scaledToFit()`
and `.scaledToFill()` keep proportions.

`.position(x:y:)` places a view by its center instead: the view keeps its
own size, its center lands on the point, and the point is measured in the
space its parent offers — which the positioned view takes all of. Unlike
`.offset(x:y:)`, it changes layout, not just drawing:

```swift
ZStack {
    ForEach(pins) { pin in
        PinLabel(pin).position(pin.point)   // centered on each pin's point
    }
}
```

A habit that keeps rows tidy: give the growing text in a row
`.frame(maxWidth: .infinity, alignment: .leading)` rather than a
``Spacer`` after it. The fixed items are sized first and the text gets what
is left.

## Scrolling and grids

``ScrollView`` scrolls its content on `.vertical`, `.horizontal` or both
axes, with the wheel, the trackpad or a finger, and keeps its offset across
rebuilds. ``LazyVStack``, ``LazyHStack``, ``LazyVGrid`` and ``LazyHGrid``
build only the children near the visible part:

```swift
@View
struct Swatches {
    let colors: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .indigo, .purple]

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 8) {
                ForEach(colors, id: \.self) { color in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color)
                        .frame(height: 64)
                }
            }
            .padding(16)
        }
    }
}
```

``Grid`` lays out rows and columns that size to their content, and the
``Layout`` protocol lets you write your own container.

## Shapes, text and images

``Rectangle``, ``RoundedRectangle``, ``Circle``, ``Ellipse``, ``Capsule`` and
``PathShape`` are filled or stroked with a ``Color`` or a gradient:

```swift
RoundedRectangle(cornerRadius: 12)
    .fill(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
    .frame(width: 160, height: 100)
```

``Text`` takes `.font`, `.bold()`, `.italic()`, `.foregroundColor`,
`.lineLimit` and `.multilineTextAlignment`. The default faces, Roboto and
Roboto Mono, ship with the library, so text looks the same on every platform.

``Image`` draws a ``RasterImage`` — decoded from a file with
`RasterImage(contentsOf:)` or made from pixels — at its pixel size, or
stretched to what it is offered when it is `.resizable()`.

## Decorating

`.background(_:)`, `.overlay(_:)`, `.border(_:width:)`, `.cornerRadius(_:)`,
`.clipShape(_:)`, `.opacity(_:)`, `.offset(x:y:)`, `.rotationEffect(_:)` and
`.scaleEffect(_:)` work as in SwiftUI.
