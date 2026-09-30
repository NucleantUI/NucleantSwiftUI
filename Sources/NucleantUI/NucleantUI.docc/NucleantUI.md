# ``NucleantUI``

SwiftUI-shaped declarative views, drawn by ThorVG on Vulkan.

@Metadata {
    @DisplayName("NucleantUI")
}

## Overview

NucleantUI is a declarative UI framework in pure Swift. If you know SwiftUI you
already know most of it: views are structs with a `body`, state lives in
``State`` and ``Binding``, models are `@Observable` classes, and layout is
stacks, frames and padding.

Underneath it is a different machine. There is no AppKit or UIKit view
hierarchy: every view is drawn by [ThorVG](https://github.com/NucleantUI/NucleantThorVG)
into Vulkan images, composited by [NucleantVulkan](https://github.com/NucleantUI/NucleantVulkan)
and presented in a window from [NucleantApplication](https://github.com/NucleantUI/NucleantApplication).
That is what lets a view be a GPU texture: any view can be handed to a
shader as its input, and a ``Shader`` can sit in a layout like any other view.

```swift
import NucleantUI

@View
struct Counter {
    @State private var count = 0

    var body: some View {
        HStack(spacing: 16) {
            Button("−") { count -= 1 }
            Text("\(count)").font(.title)
            Button("+") { count += 1 }
        }
    }
}

@main
struct CounterApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Counter", width: 400, height: 200) {
            Counter()
        }
    }
}
```

The same code runs on macOS and iOS today; Linux and Android are in progress.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:DeclaringViews>
- <doc:ManagingState>

### Building interfaces

- <doc:LayingOutViews>
- <doc:HandlingInput>
- <doc:NavigatingBetweenScreens>

### Shaders

- <doc:DrawingWithShaders>
- <doc:ViewsAsShaderInput>

### Showcases: a view as a shader's texture

- <doc:RetroMixer>
- <doc:Magnifier>
- <doc:GlassPanel>
- <doc:TouchSparks>

### Tutorials

- <doc:tutorials/NucleantUI>

### Tools

- <doc:KivyToNucleantUI>

### Views and shaders

- ``View``
- ``Shader``
- ``ShaderFunction``
- ``ShaderArgument``
- ``ShaderLibrary``
