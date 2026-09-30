# Declaring views

Write a struct with a `body` and put `@View` on it.

## Overview

A view is a value that describes a piece of interface. Its `body` is built
from other views with the same result-builder syntax SwiftUI uses:

```swift
@View
struct TrackRow {
    let name: String
    let color: Color
    @Binding var level: Double

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).frame(width: 70, alignment: .leading)
            Slider(value: $level)
            Text("\(Int(level * 100))%").foregroundColor(.secondary)
        }
        .padding(horizontal: 16, vertical: 10)
        .background(Color.tertiaryBackground)
        .cornerRadius(10)
    }
}
```

## What `@View` generates

The macro adds the ``View`` conformance and what the framework needs to avoid
rebuilding the view when nothing about it changed:

- an identity for the place the view is written, so its state stays attached
  to it across rebuilds;
- the list of its `@State`, `@Binding` and `@Environment` properties, read
  without reflection;
- a comparison over its inputs, so a parent rebuilding does not rebuild a
  child whose inputs are the same.

When you write no `init`, one is generated from the stored properties —
`TrackRow(name:color:level:)` above. A `var` with a default value and a type
annotation becomes a parameter with that default.

Put `@View` on every view struct, including small local helpers. A struct
that stores a closure is rebuilt whenever its parent is, since two closures
can never be compared; the macro warns about it. Prefer a ``Binding`` or a
value.

## Control flow in a body

`if`, `if let`, `switch` and ``ForEach`` work inside a body:

```swift
struct Message: Identifiable {
    let id: Int
    let subject: String
}

@View
struct Inbox {
    let messages: [Message]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                Text("Loading…").foregroundColor(.secondary)
            } else if messages.isEmpty {
                Text("No messages")
            } else {
                ForEach(messages) { message in
                    Text(message.subject)
                }
            }
        }
    }
}
```

## Modifiers

Modifiers wrap a view in another and are applied in order, as in SwiftUI:
`.padding().background(…)` paints the background behind the padding,
`.background(…).padding()` inside it. A reusable set of modifiers is a
``ViewModifier`` applied with `.modifier(_:)`.
