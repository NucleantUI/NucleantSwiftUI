# Navigating between screens

Push screens onto a navigation stack and come back to them as you left them.

## Overview

A ``NavigationStack`` draws a title bar with a Back button over its current
screen. A ``NavigationLink`` pushes a destination when it is tapped; the
pushed screen takes its title from the link:

```swift
@View
struct LibraryScreen {
    var body: some View {
        NavigationStack("Library") {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink("Shaders") {
                    ShaderGallery()
                }
                NavigationLink(title: "About") {
                    Text("NucleantUI").padding(20)
                } label: {
                    HStack {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                        Text("About")
                    }
                }
            }
            .padding(20)
        }
    }
}

@View
struct ShaderGallery {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(ShaderLibrary.all, id: \.name) { entry in
                Shader(entry.function).frame(height: 80)
            }
        }
        .padding(20)
    }
}
```

Screens under the top one stay alive: their state and scroll positions are
there when you come back.

## Navigating by value

A stack bound to a ``NavigationPath`` navigates by data: `NavigationLink(value:)`
appends a value, and `.navigationDestination(for:destination:)` says which
screen shows it.
