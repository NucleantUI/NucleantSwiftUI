# A mixer under a CRT

Run an interactive panel through any effect in the library and keep using it.

@Metadata {
    @PageImage(purpose: card, source: "showcase-retro-mixer", alt: "A mixer panel with sliders and mute buttons, curved and scanlined like an old CRT screen.")
}

## Overview

@Image(source: "showcase-retro-mixer", alt: "A mixer panel with four channel sliders and mute buttons, bent at the corners and striped with scanlines by the CRT effect.")

The panel is ordinary NucleantUI — a model, rows of sliders and buttons — and
`.shader` turns what it draws into the texture of one of the eight
``ShaderLibrary/effects``. The sliders keep working under the effect: it
changes what is drawn, not what is there, so hit testing still happens
against the real layout.

- The data is an `@Observable` model, owned by the screen in `@State` and
  passed down as a plain `let`. Moving one slider rebuilds that one row.
- `.cornerRadius(14)` comes *before* `.shader`, so the rounding is in the
  texture and the CRT bends it with everything else.
- `isEnabled:` switches the effect off without rebuilding the panel; its
  state, and the sliders' positions, stay as they are.
- The CRT effect reads neither the clock nor the pointer, so it is dispatched
  once and again only when the panel repaints. Wave and Ripple read the clock
  and run every frame.

## The code

```swift
import NucleantUI
import Observation

@MainActor @Observable
final class Mixer {
    struct Channel: Identifiable {
        let id: Int
        let name: String
        var level: Double
        var isMuted = false
    }

    private(set) var channels: [Channel] = [
        Channel(id: 0, name: "Kick", level: 0.8),
        Channel(id: 1, name: "Snare", level: 0.55),
        Channel(id: 2, name: "Hats", level: 0.35),
        Channel(id: 3, name: "Bass", level: 0.7),
    ]

    func setLevel(_ level: Double, of id: Int) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].level = level
    }

    func toggleMute(_ id: Int) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].isMuted.toggle()
    }
}

@View
struct ChannelStrip {
    let mixer: Mixer
    let channel: Mixer.Channel

    var body: some View {
        HStack(spacing: 12) {
            Text(channel.name)
                .frame(width: 60, alignment: .leading)
            Slider(value: Binding(
                get: { channel.level },
                set: { mixer.setLevel($0, of: channel.id) }
            ))
            Button(channel.isMuted ? "Muted" : "Mute") { mixer.toggleMute(channel.id) }
                .tint(channel.isMuted ? .red : .secondary)
                .frame(width: 70)
        }
        .opacity(channel.isMuted ? 0.5 : 1)
    }
}

@View
struct MixerPanel {
    let mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mixer").font(.headline)
            ForEach(mixer.channels) { channel in
                ChannelStrip(mixer: mixer, channel: channel)
            }
        }
        .padding(16)
        .background(Color.secondaryBackground)
    }
}

@View
struct RetroMixer {
    @State private var mixer = Mixer()
    @State private var effect = "CRT"
    @State private var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Effect", selection: $effect) {
                    ForEach(ShaderLibrary.effects, id: \.name) { entry in
                        Text(entry.name).tag(entry.name)
                    }
                }
                Toggle("On", isOn: $isEnabled)
            }

            MixerPanel(mixer: mixer)
                .cornerRadius(14)                       // clip inside the effect
                .shader(function(named: effect), isEnabled: isEnabled)
                .frame(width: 420)
        }
        .padding(24)
    }

    private func function(named name: String) -> ShaderFunction {
        ShaderLibrary.effects.first { $0.name == name }?.function ?? ShaderLibrary.identity
    }
}
```
