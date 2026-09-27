
# implement ContextMenu concept from SwiftUi

https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:)

## Outcome

Done as `.contextMenu(menuItems:)` — PROCESS.md §25.

* Right click on macOS (`on_right_mouse_down` → `ViewHost.secondaryClick`),
  a press held still for 0.5s on touch hosts.
* The host now builds `_HostRoot` — the app's root in slot `[0]`, a
  presentation in slot `[1]` — and the open menu is a `ContextMenuOverlay`
  in that slot: a scrim that closes it on any press, and the items on a
  panel anchored at the pointer, clamped to the window.
* `Button` reads `\.contextMenu` from the environment and, inside one,
  draws as a row that runs its action and dismisses; `Divider` is a rule.
* Demo: right-click any mixer row for level presets.

Then, hover and submenus (PROCESS.md §26):

* `.onHover(perform:)`, tracked by `ViewHost` while no button is down,
  by path like a drop target; rows light under the pointer.
* `Menu` — inside a context menu a row that opens its items beside it on
  hover (a tap on touch), nested, flipping left at the window's edge,
  closed by hovering another row of its panel; on its own a dropdown
  button that opens its items under itself through `\.menuPresenter`.
* The open submenus live on the `@Observable` `ContextMenuController`,
  so opening one is a scoped rebuild of the overlay.

