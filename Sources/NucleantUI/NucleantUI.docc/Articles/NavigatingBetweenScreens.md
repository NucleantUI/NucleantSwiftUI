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

## Hiding the bar

A screen hides the stack's bar with `.toolbarVisibility(.hidden, for:
.navigationBar)` — or `.toolbar(.hidden, for: .navigationBar)`, its older
name — and gets the stack's whole height. The setting belongs to the
screen: pushing another screen shows the bar again, and coming back hides
it again.

The Back button goes with the bar, so a screen that hides it gives itself
a way back through the router:

```swift
@View
struct BookCover {
    let book: Book
    @Environment(\.navigationRouter) private var router

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverArt(book: book)
            Text("‹ Library")
                .padding(12)
                .onTapGesture { router?.pop() }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
    }
}
```

The visibility can change while the screen is up — a reader that hides
the bar while you read and brings it back on a tap:

```swift
@View
struct ReadingPage {
    @State private var isImmersive = false

    var body: some View {
        PageText()
            .onTapGesture { isImmersive.toggle() }
            .toolbarVisibility(isImmersive ? .hidden : .visible, for: .navigationBar)
    }
}
```
