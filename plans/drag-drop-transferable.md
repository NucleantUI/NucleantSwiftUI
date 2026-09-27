
# Implement Transferable Protocol
should have CodableRepresentation as real SwiftUI 


# implement draggable view function
where we use Transferable protocol / Codable to make drag item into json or whatever

# implement dropDestination
which accepts Transferable types etc

## Outcome

Done — PROCESS.md §24.

* `Transferable` / `TransferRepresentation` / `TransferRepresentationBuilder`
  with `CodableRepresentation` (JSON by default; any `TransferEncoder` /
  `TransferDecoder` pair), `DataRepresentation`, `ProxyRepresentation`;
  `String`, `Data`, `URL` conform. `UTType` is the framework's own struct
  with Apple's public identifiers and conformance (`.json` is `.text`).
* `.draggable(_:)` and `.draggable(_:preview:)` — the view's own display
  list is the default preview, following the pointer at 80% opacity.
* `.dropDestination(for:action:isTargeted:)` — a destination for `T`
  matches a drag whose exports include something `T` imports; the payload
  is encoded once per content type asked for and decoded on the drop.
* Demo: the "Drag & drop" screen — tracks as JSON onto buses, and as text
  (through the proxy) onto a notes box.

