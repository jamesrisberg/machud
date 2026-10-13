# Window placement: how it works

The rules MacHUD follows when it snaps a window, captures an arrangement and applies a
loadout: what opens the editor, how a region becomes a window frame, how each slot's
window is chosen, and what happens to windows on other displays and desktops.

A loadout is one screen. Capture saves the display under the pointer, on the desktop showing;
apply arranges the display under the pointer, on the desktop showing. Loadouts that span
several desktops or displays are experimental and off by default; the rules for them are in
[Multi-desktop loadouts (experimental)](#multi-desktop-loadouts-experimental).

## Shift-drag and the editor

`DragMonitor` watches global mouse events. A drag becomes a snap once the window moves
and the trigger (Shift by default) is held; releasing puts the window in the region
under the cursor.

- A drag never opens the editor. With no layout (or an empty one) the monitor shows the
  toast **"No layout, open the editor?"** once per drag, with an *Open Editor* button,
  and lets the drag finish as a plain drag.
- The editor opens only from its menu items, a loadout's *Edit Layout…*, the `edit`
  socket verb, `--edit`, or that toast's button.
- An isolated instance (`MACHUD_NO_HOTKEYS`) does not watch global drags unless
  `MACHUD_DRAG=1`; two instances watching the same drag both react to it.

## Menus

A loadout owns its layout. The status menu's **Loadouts** submenu lists the loadouts on offer;
each has *Preview…*, *Apply*, *Clear This Screen + Apply*, *Edit Layout…* (the editor opens on
that loadout's layout with the loadout selected), a line with its layout and region count,
*Apply at Startup* and *Delete…* (which asks first and also removes the hidden layouts
captured for that loadout alone, naming them). Below the list: *Capture This Screen as
Loadout…*, *Save Dock and Panels as HUD Loadout…*, *Draw a New Layout…*, *Snap Layout* (a
submenu of the layouts ⇧-drag snaps into, with *Edit Snap Layout…*) and *Restore Cleared
Windows*. The raw layout file items (*Edit layouts.json…*, *Reveal layouts.json in Finder*,
*Reload Config*) live under **Advanced**. On the wheel a loadout's actions read *Preview* /
*Apply* / *Clear + Apply* and Capture's *This screen* / *Draw layout*; the line under
the wheel says what letting go does (*Clear this screen and apply Work*, *Capture this screen as
a loadout*).

The settings window's **Loadouts** tab lists the loadouts on offer with a thumbnail and draws
the selected one large on one screen: every region in its app's colour with its icon and
name, parked slots dashed, the HUD's sibling panels outlined at their saved frames and the
tool dock at its position. The drawing uses apply's own grouping, display fallback and region
geometry (`LoadoutSketch`), without reading any window. Its buttons are the menu's (Apply,
Preview, Edit Layout, Apply at Startup, Delete after a confirmation) plus Rename, Duplicate
and New (capture this screen or draw a layout); rename, duplicate, delete and the startup
loadout go through the same code as `machud loadouts …`.

## How a region becomes a window frame

- **Region rect** (apply, snap and status share it): the region's fractions of the
  display's *visible* frame, inset by `gap/2` twice, then `.integral`. With `gap: 0`
  this is the exact fraction rect, rounded outwards to points.
- **Apply** places each slot's window with `AXWindow.setCocoaFrame` (position, size,
  position), then once more 100 ms later. It reads back every placed window, retries
  once size-first when it is off (a move across displays is clamped against the
  window's current display), and reports what the app kept (`actual` in the reply,
  "kept W×H" in the toast). Stacked slots are raised in ascending `z` afterwards.
  Nothing compares, clips or moves regions against each other: overlapping regions
  give overlapping windows. `clear` only minimises other windows.
- **Display changes** re-apply the active loadout without `clear`, so windows moved by
  hand go back to their regions after sleep/wake or replugging a display.
- **Capture** reads the windows on the display under the pointer (the desktop showing; MacHUD's
  own overlays do not count) and derives one region per window at the window's exact frame (to
  a millionth of the screen): overlapping windows stay overlapping, and `ZOrder.captured`
  records their stacking. Regions are named after their apps. An existing region with IoU
  ≥ 0.6 against a captured rect keeps its id, name and hit zone. Windows MacHUD has parked
  are captured at their rest frame as parked slots. The tool dock and the apps' panels are
  saved only when asked. The editor's *New Loadout…* and its camera button (*Capture windows
  on screen into this loadout*) instead fill an **existing** layout: each region takes the
  window whose IoU with it is ≥ 0.6, and the regions are not changed.
- **Editor**: moving and resizing snap to the grid (96 × 54 by default), so a region is
  snapped once you edit it; nothing de-overlaps. A drag that starts inside a region
  moves or resizes it; ⌘-drag always draws a new region, including on top of another,
  and ⌘↑ / ⌘↓ set its stacking.

To build an overlapping layout: arrange the windows overlapping and *Capture This Screen as
Loadout…* (the regions come out overlapping and in stacking order), or ⌘-drag the regions in
the editor.

An app that refuses a size (a minimum size) keeps a larger frame; apply reports it
rather than failing the slot.

## The plan

Every apply first builds a **plan** (`PlacementPlan`, pure and unit tested) from where
every candidate window is: the window server's list on every desktop
(`AllSpacesWindows`), each window's desktop (`CGSCopySpacesForWindows`, read only) and
accessibility elements for windows on hidden desktops. `apply loadout=X plan=1` returns
the plan without moving anything; the preview draws it; apply follows it and reports it
per slot. The reply's `policy` is `oneScreen` unless multi-desktop loadouts are on.

Choosing the window: one on the target display's showing desktop, then one on another display
that is showing, then a minimised one, then one on a desktop that is not showing (front to
back within each). A window already chosen by an earlier slot is not reused. For an `app`
occupant, candidates are matched by `WindowMatch` (standard windows first, `titleMatch`,
main, not minimised).

| window | action | apply does |
| --- | --- | --- |
| in its region already | `stay` | nothing (still raised in `z`) |
| same display, showing desktop | `resize` | AX move/resize |
| in a hidden app (⌘H) | `resize` | unhide the app (it does not come forward), place the window |
| minimised | `resize` | restore it from the Dock, place |
| other display, its showing desktop | `move` | AX move (lands on the target's showing desktop), size-first retry |
| only on a desktop that is not showing, app can open another window | `launch` | open a new window here without activating the app; the other stays where it is |
| same, app cannot (no New Window item, or Arc), window on another display | `switchSpace` | show its desktop on its display, move the window into the region, switch back |
| same, window on the target display, another display exists | `switchSpace` | show its desktop, park the window on the other display, switch back, move it home |
| same, one display; or its desktop unknown; or the Mission Control shortcuts cannot reach it | `cannot` | the slot is left and says why, naming the app and the desktop |
| none, app running | `launch` | ask the app for a window through its New Window item (never ⌘N); launching a document app asks it to reopen; an app that answers neither is brought forward once so its menus can |
| none, not running | `launch` | launch without activating |
| none, not installed | `cannot` | reported |

Whether an app can open another window (`NewWindowClass`) is read from its menus, by title
(`NewWindowMenu`): an enabled item titled "New Window" or "New <something> Window" ("New
Finder Window", Mail's "New Viewer Window"), whatever its shortcut, in a menu or one submenu
down (Xcode's File › New › Window counts as "New Window"). A private or incognito window item
counts only when nothing else matches. ⌘N is never pressed: in Notes, Mail, Calendar,
Reminders or Xcode it makes a note, a message, an event or a file. Titles are matched in
English; under another system language no item matches and the app counts as single-window.

- **browser**: Chrome and other Chromiums, Safari by Apple event; Firefox by its New Window
  item. Arc opens a new window on its own desktop rather than the one showing, so it counts as
  single-window (an Arc window, or a page in Arc, is fetched).
- **menu**: any other app whose menus hold such an item (TextEdit, Finder, terminals,
  editors).
- **single**: an app with no such item (Messages and Signal, for instance) and Arc.

A fetch (`DesktopFetch`) records which desktop every display shows before the first
keystroke, and every display is switched back to it whatever happens, a failed step or a
switch that stops part-way included. A display that cannot be put back is reported ("left on
desktop 2 of DELL"), the slot fails and the slots still to be placed on that screen are not
placed. The fetches of one screen get 30 s together. A new window MacHUD asked for that opens
on another desktop all the same is left there (MacHUD leaves it open) and the slot says
so. One loadout is applied at a time: a second apply is refused with "<name> is still being
applied".

An app whose windows are all on desktops that are not showing and that would not open a window
without coming forward is not brought forward (that would show its desktop): its New Window
item is asked again each poll, and at the deadline the slot fails saying so. A slot that gets no
window within 15 s fails with `timed out`, or with the reason it was still waiting.

## Preview and the reply

Preview (a loadout's *Preview…*, **P** on the wheel, or `machud preview loadout=X`) draws the
plan on screen before anything moves: green placed/moved, blue launched, orange a desktop
switch (a window fetched from another desktop), red cannot (with the reason).

The apply reply has `slots[] {slot, region, occupant, action, from {screen, space,
frame}, to {screen, space, frame}, reason, window, result, error?, actual?}` besides
`placed` / `failed`; the toast lists every move, desktop switch and launch with its
reason, every failure, and any window that kept its own size.

## Multi-desktop loadouts (experimental)

A loadout is one screen. Loadouts that span several displays or desktops, and what exists only
for them, are experimental: they work only while `experimental.multiDesktopLoadouts` is on
(**Multi-desktop loadouts** under Experimental in MacHUD's settings, or `machud settings set
experimental.multiDesktopLoadouts=true`; off by default, in effect at once). It turns on:

- loadouts with per-display assignments (`screens[]`) and slots bound to a desktop (`space`);
- capturing every screen and walking desktops while capturing;
- `spaces.policy`, which decides what happens to a window on a desktop that is not showing;
- `spaces action=switch`, and the preview's "Other desktops" map.

With it off such a loadout is held back: not listed, and refused by name for apply, preview,
edit and startup (the startup apply and the re-apply after a display change skip it and say so
in a toast); and `spaces.policy` is not read: apply decides by the app, as above.

With it on, the plan's `policy` is `spaces.policy` and a slot's `space` is read. The window used
is chosen as above with one more step: after one on the target display's showing desktop, one
on the desktop the slot asks for. An app whose windows are all on desktops that are not showing
is brought forward to answer its menus.

| window | slot desktop | policy | action | apply does |
| --- | --- | --- | --- | --- |
| any reachable one | another desktop | – | `switchSpace` | switch the target display to the slot's desktop, then place / move |
| hidden desktop, other display | – | `bring` | `switchSpace` | show that desktop on its display, move the window into the region, switch back |
| hidden desktop, same display, another display exists | – | `bring` | `switchSpace` | show its desktop, park it on the other display, switch back, move it home |
| hidden desktop, only one display | – | `bring` | `launch` or `cannot` | falls back to `launchNew` |
| hidden desktop | – | `launchNew` | `launch` / `cannot` | new window without activating (browser: Apple event `make new window`/`document`; other apps: their New Window item); an app that cannot open one reports `cannot` |
| hidden desktop | – | `leave` | `leave` | reported, not touched |
| per-display assignment, display not attached | – | – | (redirect) | `ScreenFallback`: `redirected`, `needsDesktops` or `screenMissing` |

`spaces.policy` in `layouts.json` (`bring` by default) decides what happens to a window on a
desktop that is not showing. A `bring` that fails (the desktop cannot be switched, the window
stays behind) falls back to a new window when the app can open one, else the slot fails with
the reason. Desktop switching drives the Mission Control shortcuts; with both disabled the slot
fails with `spacesShortcutDisabled`. The preview colours a `leave` grey.

A capture that walks desktops switches each display to each desktop asked for and back; a
window seen on several desktops (an "all desktops" app) is captured once, on the first
desktop it was seen on. A display that is not attached when a per-display assignment is applied
is handled by `whenScreenMissing` (see [API.md](API.md#missing-displays)).

Tests: `OverlappingPlacementTests` (overlapping regions land on their exact frames and
are raised in `z` order), `ArrangementTests` (windows overlapping by 10 pt stay
overlapping after capture) and `PlacementPlanTests` cover these rules.
