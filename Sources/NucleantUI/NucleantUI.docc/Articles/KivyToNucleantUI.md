# Kivy to NucleantUI

Paste a Kivy kv file and read it back as NucleantUI Swift, live in the browser.

@Metadata {
    @CallToAction(url: "/NucleantUI/kivy-to-nucleantui/", purpose: link, label: "Open the playground")
    @PageImage(purpose: card, source: "kivy-cards", alt: "Two white cards with an Open button each, and a Wi-Fi switch below, converted from a kv file.")
}

## Overview

If you have written Kivy, you have already described interfaces as a tree of
widgets with properties. The playground shows what the same tree looks like
in NucleantUI: type kv on the left and the Swift on the right follows as you
type. The converter is Swift compiled to WebAssembly and runs entirely in
your browser.

This is a guide from Kivy's widgets to NucleantUI's views, not a way to run kv
files. The generated code compiles and runs as a NucleantUI app, and anything
kv has that NucleantUI doesn't is left in place as a `// kv:` comment.

@Image(source: "kivy-cards", alt: "A window with two white rounded cards titled Inbox and Archive, each with a blue Open button at its bottom-right corner, and a switch and the text Wi-Fi on below them.")

A kv class with a property its handlers change:

```
<Counter@BoxLayout>:
    orientation: 'vertical'
    padding: dp(24)
    spacing: 12
    count: 0

    Label:
        text: 'Taps: {}'.format(root.count)
        font_size: '28sp'
        bold: True

    BoxLayout:
        size_hint_y: None
        height: 48
        spacing: 8

        Button:
            text: '-'
            on_press: root.count -= 1
        Button:
            text: '+'
            on_release: root.count += 1
```

becomes a `@View` struct whose property is `@State`, because a handler in the
rule assigns it:

```swift
@View
struct Counter {
    @State private var count: Int = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Taps: \(count)")
                .font(.system(size: 28, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Button("-") { count -= 1 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("+") { count += 1 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                .frame(height: 48)
                .frame(maxWidth: .infinity)
        }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

## How kv maps

| Kivy kv | NucleantUI |
| --- | --- |
| `<Name@Base>:` or `<Name>:` | a `@View struct Name` |
| the root widget | `struct ContentView`, opened by a `NucleantApp` |
| a property a class invents (`count: 0`) | `@State` if a handler assigns it, otherwise a parameter |
| `text:` set where a class is used | a parameter of that struct |
| `<Label>:` (a rule for a built-in) | applied to every `Label` in the file |
| `BoxLayout` | ``VStack`` / ``HStack``, spacing 0 unless set |
| `GridLayout` | rows of ``HStack``s in a ``VStack``, sharing the space |
| `FloatLayout`, `RelativeLayout`, `Screen` | ``ZStack``, children placed by `pos_hint` |
| `AnchorLayout` | ``ZStack`` with an alignment |
| `ScrollView` | ``ScrollView`` |
| `Label` | ``Text`` |
| `Button` + `on_press` / `on_release` | ``Button`` with the handler as its action |
| `TextInput` | ``TextField``, ``SecureField`` or ``TextEditor`` over a `@State` string |
| `Slider`, `Switch`, `CheckBox`, `ToggleButton`, `Spinner` | ``Slider``, ``Toggle`` (`.switch`, `.checkbox`, `.button`), ``Picker`` over `@State` |
| `ProgressBar` | two ``Capsule``s, one sized with `relativeSize` |
| `size_hint` | fills its share; a fraction is `relativeSize`; `None` lets `width`/`height` fix it |
| `canvas.before` / `canvas` | `.background` of shapes |
| `canvas.after` | `.overlay` of shapes |
| `id: volume` on a `Slider` | `@State private var volume: Double`, read wherever kv says `volume.value` |
| `str()`, f-strings, `'%d' %`, `.format()` | one Swift string literal with interpolation |

## What it doesn't do

Python beyond expressions and simple assignments, `app.` references, change
callbacks other than a button's press (`on_text`, `on_value`), screen
managers and transitions, and canvas instructions other than colours, rectangles,
ellipses and lines come through as comments.
