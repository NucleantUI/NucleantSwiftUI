
# ViewID macro

lets make #ViewID which should just figured out 

what file macro node was used in 
what line / col it was used on and just pass the hash as macro result

not sure if a freestanding macro accepts #file #line etc still ?

i dont see a reason having calculate the hashValues at runtime, when they are in the end 
based on what compiler detects...

# update plan first with what is possible etc...
right now just figure out what is even possible of this..
and other options

anything of this id stuff that can be moved from runtime to compile time should be...


# @View public not emitted to auto generated function
@View
public struct MyView

should by default just make a public init also
and then we can specify our self init functions that aint public if needed..

---

# Findings (2026-09-22, probed with a throwaway macro package in the scratchpad)

## What the macro can see

- `MacroExpansionContext.location(of: node, filePathMode: .fileID)` hands the
  macro `file`, `line`, `column` as **literal syntax** (`"Module/File.swift"`,
  `12`, `5`). A freestanding expression macro does not need `#file`/`#line`
  in its output at all — it can read the location, hash it, and emit one
  integer literal.
- Used as a **default argument** (`_viewID: ViewID = #viewID`, SE-0422) the
  location is the **call site**, not the declaration. Verified: three calls
  on two lines gave `main.swift:4:21`, `5:21`, `5:47`.
- Same for the **implicit `buildExpression` call** of a result builder: two
  `Box(…)` expressions in a builder closure gave `main.swift:7:5` / `8:5`. So
  `ViewBuilder.buildExpression(_:_viewID: ViewID = #viewID)` works, and
  replaces the three `#fileID/#line/#column` defaults + runtime
  `ViewID(fileID:line:column:)` construction it does today.
- A `#viewID` sitting **inside macro-generated code** (`@View` emits
  `var _viewID: ViewID = #viewID`) sees the expansion buffer, not the source:
  `@__swiftmacro_13LocTestClient7Stamped5StampfMm_.swift:1:30`. Unique and
  stable per type, but useless as a location — `@View` should instead take
  `context.location(of: structDecl)` and emit the hash literal itself.
- A generated `init(…, _viewID: ViewID = #viewID)` inside an attached macro
  expansion still resolves to the **caller** (`main.swift:17:17`). Good — the
  `@View` memberwise init keeps working unchanged.
- Hash: FNV-1a 64 over `"\(fileID):\(line):\(column)"` computed in the plugin,
  emitted as `ViewID(hash: -5382734061055262720)`. Deterministic across
  builds and runs (unlike `Hasher`, which is per-process seeded) — node and
  state keys become reproducible run to run. 64-bit over a few thousand call
  sites: collision odds are negligible.

## What runtime work this removes

Today every view expression in every body evaluation builds a `ViewID`
holding a `String` (`#fileID`), and that string is hashed again on every
`StateKey` / `RenderNodeKey` / `ViewIdentity` lookup and equality. Nothing in
`Sources/` reads `fileID`/`line`/`column` back — the only consumer is the
constructor in `ViewBuilder.buildExpression`. After the change `ViewID` is
one `Int`: hashing is one `combine`, equality one compare, no ARC on copy.

## What cannot move to compile time (and why)

- `ForEach` child path (`identify(element).hashValue`): data-driven.
- `ThorCanvas(id:)` / `ThorCanvasRender(id:)`: `id.hashValue` is the
  author's value; one hash per view construction, not per lookup — not worth
  a macro. The **no-`id:`** inits become `nodeID = _viewID.hash` (no `Hasher`
  at all, same value every run).
- `ObjectIdentifier(V.self)` in `ViewIdentity` / `StateKey`: a metatype
  pointer, runtime by nature, already cheap.
- `path: [Int]`: structural, per instance. Hashing it per lookup is the
  remaining runtime cost in the keys; a rolling path hash carried by
  `BuildContext` (parent hash ⊕ child index, O(1) per level) would cut that.
  Separate change, not part of this plan.

# Plan

## 1. `ViewID` = one compile-time `Int`

`Core/ViewID.swift`:

```swift
public struct ViewID: Hashable, Sendable {
    public let hash: Int
    public init(hash: Int) { self.hash = hash }
    public static let unknown = ViewID(hash: 0)
}
```

Drop `fileID/line/column`. Option kept open: a `#if DEBUG` variant that also
carries `StaticString` file + line for printing — nothing needs it today, so
not in the first cut.

## 2. `ViewIDMacro` computes the hash

`NucleantSwiftUIMacros/ViewMacro.swift`, `ViewIDMacro.expansion`:
`context.location(of: node, at: .afterLeadingTrivia, filePathMode: .fileID)`
→ parse the three literals → FNV-1a 64 → `"ViewID(hash: \(literal))"`.
Emit `Int(bitPattern:)`-style signed literal so it always fits `Int`.
Fallback when `location` is nil: `ViewID.unknown`.

## 3. `ViewBuilder.buildExpression` uses the macro

`Core/ViewBuilder.swift:18-27`: replace the `fileID/line/column` defaults with
`_viewID: ViewID = #viewID` and assign it. Same call-site semantics, zero
runtime construction.

## 4. `@View` emits the declaration hash directly

`ViewMacro` member expansion: instead of `var _viewID: ViewID = #viewID`
(which would hash the expansion-buffer name), compute the hash of
`context.location(of: structDecl)` in the plugin and emit
`var _viewID: ViewID = ViewID(hash: <literal>)`. The generated memberwise init
keeps `_viewID: ViewID = #viewID` (caller-side, verified above).

## 5. Canvas views

`ThorCanvas.swift:51`, `ThorCanvasRender.swift:23`: `_viewID.hashValue` →
`_viewID.hash`. The `id:` inits stay `id.hashValue`.

## 6. `@View public struct` → `public init`

`ViewMacro.memberwiseInitializer`: today the init drops to internal as soon as
**any stored property lacks `public`** (`if !property.isPublic { initAccess =
"" }`). That is the wrong test — an internal `let nodeID: Int` is perfectly
settable from a `public init`; only the parameter **types** have to be
public, and the macro cannot see type visibility (syntax only). Change: the
init's access is the struct's access, full stop. A public view over an
internal property type then gets the compiler's own error on the generated
init, and the author writes the init by hand (as `ThorCanvas` does) — the
same rule as today for "declares an init ⇒ nothing generated".

Options considered:
- keep generating the memberwise init even when the author declares inits of
  their own — rejected: two inits with overlapping defaulted signatures are
  ambiguous at call sites, and today's rule (author init ⇒ none generated)
  is what "specify our own init functions if needed" means.
- `@View(publicInit: false)` opt-out — not needed; an author who wants a
  non-public init writes one.

## Order / verification

2 → 1 → 3 → 4 → 5 → 6, one build after 3 (the builder is the hot path) and
one after 6. Check: debug build clean; Sampler runs; `RenderNodeKey`
lookups in `canvasNode(for:rect:)` still hit for a rebuilt view (same call
site ⇒ same literal ⇒ same key); `StateKey` slots survive a rebuild
(`@State` keeps its value). Perf check with `measure2.sh knob` afterwards —
the win is per view expression per body run, so it shows on the knob drag
numbers.

## Done (2026-09-22)

All six steps in. Verified: debug build clean; macro dump shows
`ViewID(hash: <literal>)` per call site and `public init(` on a public struct
with an internal `let`; literals identical across two runs; BabyLights L1
macOS 5/5 captures pixel-identical to the reference, build/reuse counts
identical line for line. TouchBay release: knob 22.2–22.4% (was 22.5–22.8),
slider 21.2% (was 21.6), idle 5.1% (same) — the string hash was a small
slice; the win is mostly the simpler key.
