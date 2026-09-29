# Window placement: how it works

The rules MacHUD follows when it snaps a window, captures an arrangement and applies a
loadout: what opens the editor, how a region becomes a window frame, how each slot's
window is chosen, and what happens to windows on other displays and desktops.

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

A loadout owns its layout. The status menu leads with **Loadouts**; each loadout has
*Apply*, *Clear Others + Apply*, *Preview…*, *Edit Layout…* (the editor opens on that
loadout's layout with the loadout selected), *Apply at Startup* and *Delete* (which also
removes the hidden layouts captured for that loadout alone); then
*Preview Loadout…*, *Capture Current…* and *Save Current HUD as Loadout…*. The
snap-layout picker and the raw layout editor / `layouts.json` items live under
**Advanced**. The wheel's rings read *Apply* / *Clear + Apply* and loadout wedges show
their window count.

The settings window's **Loadouts** tab lists every loadout with a thumbnail and draws the
selected one large: each display where it is attached, one desktop at a time, every region
in its app's colour with its icon and name, parked slots dashed, the HUD's sibling panels
outlined at their saved frames and the tool dock at its position. The drawing uses apply's
own grouping, display fallback and region geometry (`LoadoutSketch`), without reading any
window. Its buttons are the menu's (Apply, Preview, Edit Layout, Apply at Startup, Delete
after a confirmation) plus Rename, Duplicate and New (capture or draw); rename, duplicate,
delete and the startup loadout go through the same code as `machud loadouts …`.

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
- **Capture** derives one region per window at the window's exact frame (to a millionth
  of the screen): overlapping windows stay overlapping, and `ZOrder.captured` records
  their stacking. Regions are named after their apps. An existing region with IoU
  ≥ 0.6 against a captured rect keeps its id, name and hit zone. The editor's *new
  loadout* / *capture into loadout* instead fills an **existing** layout: each region
  takes the window whose IoU with it is ≥ 0.6, and the regions are not changed.
- **Editor**: moving and resizing snap to the grid (96 × 54 by default), so a region is
  snapped once you edit it; nothing de-overlaps. A drag that starts inside a region
  moves or resizes it; ⌘-drag always draws a new region, including on top of another,
  and ⌘↑ / ⌘↓ set its stacking.

To build an overlapping layout: arrange the windows overlapping and *Capture Current…*
(the regions come out overlapping and in stacking order), or ⌘-drag the regions in the
editor.

An app that refuses a size (a minimum size) keeps a larger frame; apply reports it
rather than failing the slot.

## The plan

Every apply first builds a **plan** (`PlacementPlan`, pure and unit tested) from where
every candidate window is: the window server's list on every desktop
(`AllSpacesWindows`), each window's desktop (`CGSCopySpacesForWindows`, read only) and
accessibility elements for windows on hidden desktops. `apply loadout=X plan=1` returns
the plan without moving anything; the preview draws it; apply follows it and reports it
per slot.

Choosing the window: one on the target display's showing desktop, then one on the
desktop the slot asks for, then one on another display, then a minimised one, then one
on a hidden desktop (front to back within each). A window already chosen by an earlier
slot is not reused. For an `app` occupant, candidates are matched by `WindowMatch`
(standard windows first, `titleMatch`, main, not minimised).

| window | slot desktop | policy | action | apply does |
| --- | --- | --- | --- | --- |
| in its region already | showing | – | `stay` | nothing (still raised in `z`) |
| same display, showing desktop | showing | – | `resize` | AX move/resize |
| minimised | – | – | `resize` | un-minimise, place |
| other display, its showing desktop | showing | – | `move` | AX move (lands on the target's showing desktop), size-first retry |
| any reachable one | another desktop | – | `switchSpace` | switch the target display, then place / move |
| hidden desktop, other display | – | `bring` | `switchSpace` | show that desktop on its display, move the window into the region, switch back |
| hidden desktop, same display, another display exists | – | `bring` | `switchSpace` | show its desktop, park it on the other display, switch back, move it home |
| hidden desktop, only one display | – | `bring` | `launch` or `cannot` | falls back to `launchNew` |
| hidden desktop | – | `launchNew` | `launch` / `cannot` | new window without activating (browser: Apple event `make new window`/`document`; menu apps: ⌘N item); single-window apps cannot |
| hidden desktop | – | `leave` | `leave` | reported, not touched |
| none, app running | – | – | `launch` | ⌘N, else activate |
| none, not running | – | – | `launch` | launch without activating |
| none, not installed | – | – | `cannot` | reported |
| display missing | – | – | (redirect) | `ScreenFallback`: `redirected`, `needsDesktops` or `screenMissing` |

A slot that gets no window within 15 s fails with `timed out`.

## Desktops: `spaces.policy`

`spaces.policy` in `layouts.json` (`bring` by default) decides what happens to a window
on a desktop that is not showing. A `bring` that fails (the desktop cannot be switched,
the window stays behind) falls back to a new window when the app can open one, else the
slot fails with the reason. Desktop switching drives the Mission Control shortcuts; with
both disabled the slot fails with `spacesShortcutDisabled`.

App classes for `launchNew` (`NewWindowClass`):

- **browser**: Chrome and other Chromiums, Arc, Safari by Apple event; Firefox by ⌘N.
- **menu**: any app whose menu bar has an enabled plain ⌘N item (TextEdit, Finder,
  terminals, editors).
- **single**: Messages, Signal, Beeper, Slack, Discord, WhatsApp, Telegram, Spotify,
  Music, FaceTime, Zoom, Teams, and any app without ⌘N. A single-window app on a hidden
  desktop can only be brought, which needs a second display on macOS 26.

## Preview and the reply

Preview (a loadout's *Preview…*, *Preview Loadout…*, **P** on the wheel, or `machud
preview loadout=X`) draws the plan over every display before anything moves: green
placed/moved, blue launched, orange a desktop switch, red cannot (with the reason).

The apply reply has `slots[] {slot, region, occupant, action, from {screen, space,
frame}, to {screen, space, frame}, reason, window, result, error?, actual?}` besides
`placed` / `failed`; the toast lists every move, desktop switch and launch with its
reason, every failure, and any window that kept its own size.

Tests: `OverlappingPlacementTests` (overlapping regions land on their exact frames and
are raised in `z` order), `ArrangementTests` (windows overlapping by 10 pt stay
overlapping after capture) and `PlacementPlanTests` cover these rules.
