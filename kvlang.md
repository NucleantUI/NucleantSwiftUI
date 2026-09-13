# `.nkv` — a kv-shaped surface for NucleantSwiftUI

What `NucleantSwiftUIDemo/main.swift` looks like written declaratively, in a language
borrowing Kivy's *kv* syntax — indentation-scoped nodes, `key: expression` properties,
`<Rule>:` class definitions, `#:` directives.

Not Kivy: no widgets, no `canvas:` sub-language, no `BoxLayout`. The vocabulary is
NucleantSwiftUI's own, and every rule is a `struct … : View`.

---

## Sigils

A sigil is a **declaration marker**. It appears on the one line where a name comes into
existence, to say what backs it, and never again. Reads and writes are the bare name.

| Declared | Swift | Used as |
|---|---|---|
| `$count: 0` | `@State private var count = 0` | `count` |
| `&level: Double` | `@Binding var level: Double` | `level` |
| `@color_scheme: ColorScheme` | `@Environment(\.colorScheme) private var colorScheme` | `color_scheme` |
| `name: String` | `let name: String` | `name` |

```kv
<Counter>:
    $count: 0                 # here, once — "this will be state"

    body:
        Button:
            title:  "+"
            on_tap: count += 1    # everywhere else, just the name
```

Call sites are plain too. A parent fills `TrackRow`'s binding with
`level: tracks[i].level`; the generator knows `<TrackRow>` declared `&level` and emits
`$tracks[i].level` itself.

## The leading dot

Enum cases and static members are written with a leading dot, resolved against the type
the property expects — exactly as in Swift:

```kv
color: .secondary                     # Color.secondary
align: .top_leading                   # Alignment.topLeading
axis:  .vertical                      # Axis.vertical
font:  .system(15, .medium)           # Font.system(size: 15, weight: .medium)
width: .fill                          # .frame(maxWidth: .infinity)
fill:  .white.opacity(8%)             # Color(white: 1, opacity: 0.08)
tint:  .white(30%)                    # Color(white: 0.3)
```

`entry.name` has a receiver written down, so no leading dot. `#4C8DFF` is a literal.

Everything is `snake_case` and lowerCamels on the way out: `corner_radius` →
`cornerRadius`, `.top_leading` → `.topLeading`.

## The rest

- **Indentation is structure.** `Name:` then an indented block of properties and children.
- **`key: expr`** sets a property; the right side is a Python-flavoured expression.
- **Expressions rebind.** `text: "{count}"` re-evaluates when `count` changes.
- **Strings interpolate** with `{}`, always, no prefix.
- **Modifiers become properties.** `.padding(16).background(PANEL)` is `padding: 16` and
  `background: PANEL` on the node. See [Modifier order](#modifier-order).

---

## `mixer.nkv`

### Header, palette, data

```kv
#:nucleant 0.1
#:import ShaderLibrary  NucleantSwiftUI.ShaderLibrary
#:import version        NucleantSwiftUI.version

#:set PANEL            #1C1F26
#:set PANEL_HIGHLIGHT  #272B34
#:set ACCENT           #4C8DFF
#:set GOOD             #3DD68C
#:set WARN             #FFB020
#:set VIOLET           #B57BFF
#:set PINK             #FF6F91
#:set CYAN             #36C5D6
#:set BONE             #E0E4EA
#:set BACKDROP         #11141A

model Track:
    id:    Int
    name:  String
    level: Double
    color: Color

data defaultTracks: [Track]
    - { id: 0, name: "Kick",  level: 0.82, color: ACCENT }
    - { id: 1, name: "Snare", level: 0.54, color: GOOD   }
    - { id: 2, name: "Hats",  level: 0.37, color: WARN   }
    - { id: 3, name: "Bass",  level: 0.71, color: VIOLET }
    - { id: 4, name: "Pad",   level: 0.28, color: PINK   }
    - { id: 5, name: "Lead",  level: 0.63, color: CYAN   }
    - { id: 6, name: "FX",    level: 0.19, color: BONE   }
```

### The fader

A track behind, a fill in front sized by `level`, and a drag that writes it. The hit
area is taller than the visible bar.

```kv
<Fader>:
    color:  Color
    &level: Double

    body:
        ZStack:
            align:  .leading
            width:  .fill
            height: 24
            on_drag: level = clamp(drag.x / drag.width, 0, 1)

            Capsule:
                fill:   .white.opacity(8%)
                height: 8

            Capsule:
                fill:   .linear_gradient([color.opacity(60%), color], from: .leading, to: .trailing)
                width:  level * 100%
                height: 8
```

`100%` is a fraction of the proposed width — `level * 100%` is
`.relativeSize(width: level)`. `drag` is the gesture value in scope inside `on_drag:`.

### A mixer row

```kv
<TrackRow>:
    name:   String
    color:  Color
    &level: Double

    body:
        HStack:
            spacing:       12
            padding:       16, 10
            background:    PANEL_HIGHLIGHT
            corner_radius: 10

            Circle:
                fill: color
                size: 10, 10

            Text:
                text:  name
                font:  .system(15, .medium)
                width: 70
                align: .leading

            Fader:
                color: color
                level: level

            Text:
                text:  "{int(level * 100)}%"
                font:  .system(13, design: .monospaced)
                color: .secondary
                width: 44
                align: .trailing
```

`fill: color` and `color: .secondary` sit one above the other and are different kinds of
thing — this rule's prop, and a member of `Color`. The dot is the whole difference.

### Counter

```kv
<Counter>:
    $count: 0

    body:
        HStack:
            spacing: 16

            Button:
                title:  "−"
                on_tap: count -= 1

            Text:
                text:  "{count}"
                font:  .system(28, .semibold, design: .monospaced)
                width: 80
                align: .center

            Button:
                title:  "+"
                on_tap: count += 1
```

### Shaders

The shaders stay in Swift (`ShaderLibrary`) — the language never describes a GPU
function, it only places one. Every row here is a live compute node.

```kv
<ShaderScreen>:
    entry: ShaderEntry

    body:
        VStack:
            spacing: 12
            padding: 16

            Text:
                text:  entry.blurb
                font:  .footnote
                color: .secondary

            Shader:
                function: entry.function
                width:    .fill
                height:   .fill


<ShaderGalleryScreen>:

    body:
        ScrollView:
            axis: .vertical

            VStack:
                align:   .leading
                spacing: 10
                padding: 20
                width:   .fill

                Text:
                    text:  "{len(ShaderLibrary.all)} shaders, each its own GPU node — all running at once."
                    font:  .footnote
                    color: .secondary

                for entry in ShaderLibrary.all key entry.name:
                    NavigationLink:
                        title: entry.name

                        destination:
                            ShaderScreen:
                                entry: entry

                        label:
                            HStack:
                                spacing:       14
                                padding:       14, 10
                                background:    PANEL_HIGHLIGHT
                                corner_radius: 12

                                Shader:
                                    function: entry.function
                                    size:     120, 68

                                VStack:
                                    align:   .leading
                                    spacing: 3

                                    Text:
                                        text: entry.name
                                        font: .system(16, .medium)

                                    Text:
                                        text:  entry.blurb
                                        font:  .footnote
                                        color: .secondary

                                Spacer:

                                Text:
                                    text:  "›"
                                    font:  .system(20)
                                    color: .secondary
```

`destination:` and `label:` are **named child slots** — a block whose contents are child
nodes rather than a value, for SwiftUI's trailing-closure pairs.

### About

```kv
<AboutScreen>:

    body:
        VStack:
            align:   .leading
            spacing: 12
            padding: 20
            width:   .fill
            height:  .fill

            Text:
                text: "NucleantSwiftUI"
                font: .title2

            Text:
                text:  "SwiftUI-shaped views over NucleantApplication, NucleantVulkan and NucleantThorVG."
                color: .secondary

            Spacer:
```

### The screen

```kv
<Header>:

    body:
        HStack:
            align:   .center
            spacing: 14

            RoundedRectangle:
                corner_radius: 8
                fill: .linear_gradient([ACCENT, VIOLET], from: .top_leading, to: .bottom_trailing)
                size: 36, 36

            VStack:
                align:   .leading
                spacing: 2

                Text:
                    text: "Nucleant Mixer"
                    font: .system(22, .bold)

                Text:
                    text:  "SwiftUI-shaped views, ThorVG on Vulkan"
                    font:  .footnote
                    color: .secondary

            Spacer:


<ContentView>:
    $show_details: true
    $tracks:       defaultTracks

    body:
        VStack:
            align:      .leading
            spacing:    20
            padding:    24
            width:      .fill
            height:     .fill
            background: BACKDROP

            Header:

            Counter:
                width: .fill
                align: .center

            HStack:
                spacing: 12

                Button:
                    title:  "Hide mixer" if show_details else "Show mixer"
                    tint:   ACCENT
                    on_tap: show_details = not show_details

                Button:
                    title:  "Reset"
                    tint:   .white(30%)
                    on_tap: tracks = defaultTracks

                NavigationLink:
                    title: "Shaders"
                    destination:
                        ShaderGalleryScreen:

                NavigationLink:
                    title: "About"
                    destination:
                        AboutScreen:

                Spacer:

                Text:
                    text:  "NucleantSwiftUI {version}"
                    font:  .footnote
                    color: .secondary

            Divider:

            if show_details:
                ScrollView:
                    axis: .vertical

                    VStack:
                        spacing: 8

                        for i in tracks.indices key i:
                            TrackRow:
                                name:  tracks[i].name
                                color: tracks[i].color
                                level: tracks[i].level
            else:
                VStack:
                    Spacer:

                    Text:
                        text:  "Mixer hidden"
                        font:  .title2
                        color: .secondary

                    Spacer:
```

The three properties on `TrackRow` look identical and generate differently: `name` and
`color` copy, `level` becomes `$tracks[i].level`. Which is which was written once, in
`<TrackRow>`'s head. So `Fader`'s drag writes back through two rules to the array this
screen owns, with no callback in between.

### Root

An unbracketed node at file scope is the entry point, the way a kv file ends with its
root widget.

```kv
NucleantApp:
    body:
        WindowGroup:
            title:      "Nucleant SwiftUI Demo"
            size:       900, 620
            background: BACKDROP

            NavigationStack:
                title: "Nucleant Mixer"

                ContentView:
```

---

## Modifier order

SwiftUI modifiers are ordered wrappers — `.padding().background()` paints behind the
padding, `.background().padding()` inside it. Flat properties lose that, so the order is
fixed regardless of how they're written:

```
content → padding → background/corner_radius/border → frame → opacity → gestures
```

That covers the whole demo. For anything it doesn't:

```kv
Text:
    text: "boxed"
    modifiers:
        - background: PANEL
        - padding: 8
        - background: ACCENT
```

---

## Grammar sketch

```ebnf
file        = { directive | model | data | rule | node } ;

directive   = "#:" ident rest-of-line ;
model       = "model" ident ":" INDENT { ident ":" type } DEDENT ;
data        = "data" ident ":" type INDENT { "-" record } DEDENT ;

rule        = "<" ident ">" ":" INDENT { decl } "body" ":" INDENT body DEDENT DEDENT ;
decl        = "$" ident ":" expr                    (* type inferred *)
            | "&" ident ":" type
            | "@" ident ":" type
            |     ident ":" type ;

body        = { node | property | slot | control } ;
node        = ident ":" [ INDENT body DEDENT ] ;
property    = [ "@" ] ident ":" expr ;              (* "@" provides to the subtree *)
slot        = ident ":" INDENT { node } DEDENT ;    (* "body" is the default slot *)

control     = "if" expr ":" INDENT body DEDENT [ "else" ":" INDENT body DEDENT ]
            | "for" ident "in" expr [ "key" expr ] ":" INDENT body DEDENT ;

expr        = primary { postfix | binop expr } | "not" expr
            | expr "if" expr "else" expr ;
primary     = "." ident [ args ]                    (* implicit member lookup *)
            | ident | literal | "(" expr ")" ;
postfix     = "." ident [ args ] | "[" expr "]" | args ;
args        = "(" [ [ ident ":" ] expr { "," [ ident ":" ] expr } ] ")" ;
literal     = NUMBER [ "%" ] | STRING | COLOR | "true" | "false" | list | record ;
```

Node names are capitalised, property names `snake_case` — that carries the
node-vs-property distinction. Sigils occur only in `decl`, so expressions never contain
one, and `body:` is the line that ends the declarations and starts the tree — the same
shape as the `destination:`/`label:` slots, just the one every rule has.

---

## Mapping

| `.nkv` | NucleantSwiftUI |
|---|---|
| `<Name>:` | `struct Name: View { … }` |
| `body:` | `var body: some View { … }` |
| `x: T` | `let x: T` |
| `$x: v` | `@State private var x = v` |
| `&x: T` | `@Binding var x: T` |
| `@x: T` | `@Environment(\.x) private var x: T` |
| `x: path` where the callee declared `&x` | `x: $path` |
| `@x: v` on a node | `.environment(\.x, v)` |
| `.name` / `.name(a, b)` | the same, resolved against the property's type |
| `snake_case` | `lowerCamelCase` |
| `Node:` + block | the view + its `@ViewBuilder` children |
| `padding: 16, 10` | `.padding(horizontal: 16, vertical: 10)` |
| `width: .fill` | `.frame(maxWidth: .infinity)` |
| `width: 70` | `.frame(width: 70)` |
| `width: e * 100%` | `.relativeSize(width: e)` |
| `align:` | the `alignment:` of the enclosing `frame`/stack |
| `color: .secondary` | `.foregroundColor(.secondary)` |
| `on_tap:` / `on_drag:` | `Button` action / `.gesture(DragGesture().onChanged { … })` |
| `if` / `else` | `if`/`else` inside the `ViewBuilder` |
| `for x in xs key k` | `ForEach(xs, id: \.k) { x in … }` |
| named slot | a trailing closure argument |

`<Counter>` round-trips to:

```swift
struct Counter: View {
    @State private var count = 0

    var body: some View {
        HStack(spacing: 16) {
            Button("−") { count -= 1 }
            Text("\(count)")
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .frame(width: 80, alignment: .center)
            Button("+") { count += 1 }
        }
    }
}
```
