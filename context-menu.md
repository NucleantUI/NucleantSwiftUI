
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

