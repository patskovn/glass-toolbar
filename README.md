# GlassToolbar

Toolbar buttons for AppKit on Liquid Glass pills that animate the way iOS bar buttons do.

`NSToolbar` snaps when its items change: glass jumps to its new size in one frame, buttons appear and
disappear. `GlassToolbarItem` draws its own pills and springs them: a pill keeps its identity while any
of its buttons stays, buttons blur in and out, one screen's actions morph into the next screen's, and a
changing pill briefly swells and bridges with its neighbour.

Extracted from [Sickle](https://sickle.app), a Mac mail app. Requires macOS 27.

## Use

A `GlassToolbarItem` is used like an `NSToolbarItemGroup`. Where a group takes `subitems`, this takes
`groups`: one array of views per pill.

```swift
import GlassToolbar

let actions = GlassToolbarItem(itemIdentifier: .init("actions"), anchor: .trailing)
actions.label = "Actions"

let reply = GlassToolbarButton(symbol: "arrowshape.turn.up.left", label: "Reply", target: self, action: #selector(reply))
let trash = GlassToolbarButton(symbol: "trash", label: "Delete", target: self, action: #selector(delete))
let save = GlassToolbarButton(symbol: "checkmark", label: "Save", target: self, action: #selector(save))

actions.setGroups([[reply, trash]])        // one pill
actions.setGroups([[trash], [save]])       // two: Delete stays where it is, Reply leaves, Save grows in
actions.setGroups([])                      // the item hides
```

Return the item from `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` as any other. Keep
the buttons: a button that is in both the old groups and the new is what lets its pill stay and slide.
Calling `setGroups` again with the same groups is cheap, so it can be called from whatever observes
your state.

- `anchor` is the edge the pills hold on to while their widths change. Use `.leading` for an item with
  something fixed before it and room after (a Back button), `.trailing` for the usual cluster at the end.
- Any view can go in a pill, not only `GlassToolbarButton`; others are hosted at their fitting size.
- `contentAppearance` draws the pills for a light or dark document under the toolbar.
- `buttonSpacing` is 8, as between a group's subitems; 0 matches a pill of plain adjacent items.

## What it copies from the system

The toolbar treats an item with a view of its own differently from its own glass items, so three of the
system's behaviours are reproduced here. The numbers are in `GlassToolbarMetrics`.

**Edge margins.** The system leaves 4pt beside a glass item on each side, except where the nearest item
that is not hidden is a fixed or flexible space. Separators, text items, other glass items and the ends
of the toolbar all get the margin. `edgeMargins` is `.automatic` by default, which follows that rule from
the item's neighbours and keeps following it as they are added, removed, shown and hidden; `.fixed`
sets the margins yourself.

**The overflow menu.** A view item has nothing in the toolbar's overflow menu unless it provides it. The
item keeps `menuFormRepresentation` in step with its pills: one menu item for a lone button, otherwise
its `label` with the buttons in a submenu. Choosing a menu item sends the button's action from the
button. Set `menuItemProvider` for views that are not buttons, or turn
`automaticallyUpdatesMenuFormRepresentation` off to supply your own.

**The minimum slot.** No view item gets a slot narrower than 36pt, so an item cannot shrink to nothing
with its last pill; it has to be hidden, and hiding moves the items around it. The item hides as the
last pill starts to leave, and the pill finishes leaving over the toolbar where it was. The items
around it move once, with the change, rather than a second later.

## The demo

```sh
swift run GlassToolbarDemo
```

A three-column window with the glass items or the system's own in the same places, and a mail app's
screens to switch between. The toolbar is built from a row of tokens, so any arrangement can be tried;
the window lists them.

The demo also reads commands from standard input (`help` lists them): `dump` prints where the toolbar
put every slot and piece of glass, `trace` prints them per frame, `items` shows what is in the overflow
menu. That is how the numbers above were measured, by laying out the same row with `glass` and with
the system's `group` and comparing.

## Limits

- Icon-only buttons; no labelled display mode.
- Leading and trailing are left and right: right-to-left layout is not handled.
- `GlassToolbarButton` shapes its hover highlight with a private AppKit call
  (`-[NSView _setGlassContextOptions:]`), checked with `responds(to:)`. Without it the highlight is the
  inset one rather than filling a lone button's pill.
- A leaving pill finishes in a view added to the window's frame view, above the toolbar.
- The metrics are today's. If the system's toolbar changes, they need measuring again.

## Licence

MIT. See `LICENSE`.
