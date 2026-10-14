---
name: machud
description: Control the user's MacHUD desktop from the shell — inspect window layouts, apply, preview or capture loadouts (one screen: which apps/pages go in which region of a display, plus the HUD setup), move windows into regions, drive the MacHUD tool dock (position, summon/dismiss sibling apps, drop files on them), place and arrange desktop widgets, park windows behind orbs, manage the menu bar, and open panels and the shared settings window. Use whenever the user asks to arrange windows, set up or switch a workspace, or move/configure the tool dock, desktop widgets or sibling HUD apps.
---

# MacHUD control skill

MacHUD is the user's macOS window grid + HUD umbrella app. Everything
is driven through the `machud` CLI: `machud <command> [key=value ...]`, JSON out, over the
control socket `/tmp/machud-<uid>.sock`. Full reference: `docs/API.md` in the repo
(`~/dev/machud`), or `machud --help`.

Dev servers, ffmpeg and ImageMagick are **not** MacHUD commands: they are the sibling apps
serversHUD, ffmpegHUD and magickHUD. MacHUD's `servers`, `servers-kill` and `dock` verbs
only answer "moved to …" with the app to use. Reach those apps through their panels
(`machud panel show id=<app id>/<panel>`) or their own sockets.

## Start here

```sh
machud ping || machud --launch      # is it running?
machud permissions                  # accessibility + automation status; add request=1 to prompt
machud help                         # command list from the running app
machud layouts                      # regions with ids and geometry
machud loadouts                     # saved loadouts (HUD-only ones included; held-back multi-desktop ones are counted in heldBack)
machud status                       # what is in each region right now
machud windows                      # every on-screen window with CGWindow numbers
machud diagnose                     # snapshot of where every MacHUD window really is: path + what looks wrong
machud screens                      # displays (persistentID), desktop count and current desktop
machud apps                         # sibling apps: health, reachable, panels
machud hello                        # contract handshake: app id com.jrisberg.machud, hudkit version, verbs
```

Regions are identified by `id` (stable UUIDs). Windows by `window` number.
Coordinates are Cocoa points (origin bottom-left).

## Arrange windows

A loadout is one screen: capture saves the display under the pointer, on the desktop showing;
apply arranges the display under the pointer, on the desktop showing. Set a screen up, capture
it, then apply it on any other desktop or display. Loadouts that span several desktops or
displays are experimental and off by default (see Multi-desktop loadouts below).

- Put one window somewhere: `machud place window=<n> region=<id>`.
- **Plan before applying**: `machud apply loadout="Work" plan=1` is a dry run returning
  `plan[]` of `{slot, region, occupant, action, from?, to, reason, window?}` (`stay`,
  `resize`, `move`, `switchSpace`, `launch`, `leave`, `cannot`); nothing moves. Read it
  before applying. `machud preview loadout="Work"` draws the same plan on screen
  for the user (`action=apply|cancel` answers it).
- Apply a saved workspace: `machud apply loadout="Work"` arranges the screen under the pointer
  (`screen=<display>` picks another); add `clear=1` to minimise the other windows on that screen
  first. The reply's `slots[]` carries each step's `result`. A window on another display is
  moved over, a minimised one restored, a hidden app unhidden. An app whose only window is on
  another desktop gets a new window here when it has a New Window menu item; one without
  (Messages, Signal) and Arc are fetched, which shows their desktop, brings the window over and
  switches back (the one time an apply switches desktops), or left and named when that cannot
  be done. Apply never closes a window and runs one at a time (a second is refused).
- Save the current screen: `machud capture name="Work"` derives a layout from the windows on
  the display under the pointer (`screen=<display>` picks another), one region per window, plus
  the loadout that fills it. Add `layout=<name>` to only record what sits in an existing
  layout's regions. The tool dock and panels are saved only with `hud=1` or `hud=only`.
- Clear the desk: `machud clear` minimises the windows showing on the screen under the pointer
  (`screen=<display>` picks another; windows on other displays and desktops stay; sibling MacHUD
  apps and hidden apps are left alone); with multi-desktop loadouts on and no `screen` it clears
  every desktop. Undo with `machud restore` (either way).
- Switch which layout Shift-drag snapping uses: `machud select-layout name=<name>`.
- Another display: `machud status screen=builtin`; `machud screens` lists them.
- Open the visual editor for the user: `machud edit` (`loadout=<name>` on that loadout,
  `new=1` on a blank layout). Manage saved loadouts: `machud loadouts rename name=A to=B`,
  `duplicate name=A [to=]`, `delete name=A` (also removes the hidden layouts captured for it),
  `startup name=A` (no name clears). The settings window's Loadouts tab
  (`machud settings-window show tab=loadouts`) shows them all with previews.

To build a loadout by hand, edit `~/.config/machud/layouts.json` (`loadouts[]` with
`slots[] {regionID, occupant}`, optional `hud`; occupant kinds: `app` `{bundleID, titleMatch?}`,
`web` `{url, host: arc|safari|chromeApp|builtin}`, `panel` `{id}` where `id` may be a sibling's
`<bundle id>/<panel>`), then `machud reload`. Displays change ⇒ the active loadout is
re-applied on its own.

## Multi-desktop loadouts (experimental)

Loadouts that span several desktops or displays are off by default. The setting is
`experimental.multiDesktopLoadouts` (**Multi-desktop loadouts** under Experimental in MacHUD's
settings window): `machud settings set experimental.multiDesktopLoadouts=true`, in effect at
once. It is the user's setting: ask before changing it. It turns on:

- `machud capture name="Studio" screens=all`: one layout per display (`Studio · <display>`)
  into one loadout. Add `desktops=1,2` (or `desktops=main:1,2;builtin:1`) to walk desktops too.
  **Walking desktops is visible to the user: keep it short and only when asked.**
  `screens=Thirds@main,Full@builtin` is the fill-only form.
- Slots that carry `"space": N`, and `screens[]` with `whenScreenMissing: desktop|skip` in a
  loadout written by hand. A loadout captured on a display that is unplugged still applies: it is
  redirected to its `fallback`, else the main display. `apply`/`status` report `redirected[]`;
  `reason: needsDesktops` means the user must add desktops in Mission Control.
- `machud spaces action=switch n=2`. (`machud spaces` alone reports the desktops and shortcuts
  and is never refused.)
- `spaces.policy` in layouts.json (`bring`, `launchNew`, `leave`): what apply does with a
  window that is only on a desktop that is not showing.

With it off, such loadouts are held back: `machud loadouts` leaves them out and counts them in
`heldBack` (with `heldBackNote`); `apply` (and `plan=1`), `preview`, `edit` and `loadouts
startup` by name answer `ok: false`; `screens=all`, `desktops=`, `screens=<layout>@<ref>` and
`spaces action=switch` are refused. Show the `error`, which names the setting.

## HUD loadouts

A loadout's `hud` part holds the MacHUD side of the desktop: the tool dock's position,
each running sibling's panels (visible, mode, frame, dock setting) and the placed widgets
(`widgets`, only when some are placed; applying a loadout with that key replaces them, one
without leaves them alone). A loadout may be HUD
only (`"layout": ""`, `"slots": []`).

```sh
machud capture name=Desk hud=only     # dock position + every running sibling's panels
machud capture name=Work hud=1        # windows and HUD into one loadout
machud apply loadout=Desk             # launches missing siblings, puts everything back
```

`startupLoadout` in layouts.json names a loadout applied about 2 s after launch.

## Sibling apps

```sh
machud apps                              # {id, name, health, running, reachable, autoLaunch, panels[]}
machud apps rescan                       # after installing/building a sibling
machud apps launch id=Sift               # by bundle id or name; resets relaunch attempts
machud apps place id=Sift                # apply its configured placement now
machud apps quit id=Sift
machud apps launch-all                   # every app that is not running; quit-all quits every running one
machud apps relaunch id=Sift             # quit, wait for exit, launch; relaunch-all [outdated=1] for several
machud panel show id=xyz.machud.sift/browser    # launches the app if needed; short id if unambiguous
machud summon id=Stash                   # show a sibling's panel where it was last dismissed
machud dismiss id=Stash                  # hide it, remembering the frame (never launches)
machud apps perform app=Scratch verb=append text=hi   # one of the app's own actions (its manifest's verbs)
```

`health`: `running`, `socketUnreachable`, `launching`, `notRunning`, `notInstalled`.
`autoLaunch` apps are relaunched after a crash (3 tries, `lastError` says when it gave up).

## Tool dock

```sh
machud tooldock                               # position, segments, buttons {title, group, kind, acceptsDrop, frame, edge}, neighbors, summoned
machud tooldock show|hide|toggle
machud tooldock position position=topLeft     # bottom|top|left|right (row/column) or topLeft|topRight|bottomLeft|bottomRight (an L)
machud tooldock autohide value=on             # also: magnify
machud tooldock click id=Scratch              # what clicking the button does
machud tooldock drop id=magickHUD paths=/path/a.png,/path/b.png   # hand files to an app that takes drops
```

Buttons list hover apps (Stash, Scratch, ffmpegHUD, …) first, then windowed apps
(Sift, Wormhole, …).

## Desktop widgets

Siblings serve widget types (`kind: widget` panels; widgetHUD's clock, weather, calendar).
MacHUD places instances on the layout grid (`grid` in layouts.json, the lines regions snap to)
at a fixed size (small 170×170, medium 356×170, large 356×356, extraLarge 728×356 pt), each
edge snapping flush to the nearer grid line, never overlapping another widget, and keeps the
serving app running. A position is `x= y=` (top-left as fractions 0-1 of the visible frame,
from the top-left, like regions) or `col= row=` (grid-line indices; default grid 96×54).

```sh
machud widgets types                          # every type: app, sizes, multiple, settingsSchema
machud widgets                                # placed: instance, type, size, x/y, col/row, display, frame, layer, problems
machud widgets add type=clock [size=medium] [x=0.5 y=0 | col=48 row=0] [screen=builtin] [layer=float] [settings='{"zone":"UTC"}']
machud widgets move instance=8F0C1E2A col=24 row=0  # snapped, nearest free spot; `note` says when it moved elsewhere
machud widgets resize instance=8F0C1E2A size=medium
machud widgets layer instance=8F0C1E2A float        # or desktop
machud widgets settings instance=8F0C1E2A zone=Asia/Tokyo   # merged, checked by the type's schema
machud widgets remove instance=8F0C1E2A
machud widgets edit on|off|toggle             # unlock + gallery + layout-grid overlay (visible to the user)
machud widgets reveal on|off|toggle           # raise desktop widgets above windows (⌃⌥W)
```

The layout editor (`machud edit`) also shows widgets as blocks to drag, with an Add Widget
menu; those changes apply at once. An app that serves only widgets has no tool dock button. `missingType`: its app no longer
serves the type (kept, not shown); `problem`: the app refused it.

## Parking and orbs

```sh
machud park id=<region|window number> edge=right peek=12   # or app=<bundle id> [title=<regex>]
machud park list                          # parked windows and orbs
machud park reveal edge=right pin=1       # what hovering the orb does; park conceal hides again
machud park restore                       # put every parked window back
machud unpark id=<id>                     # un-park one (or all, without id) for good
machud orb show|hide                      # orbs are hidden while the tool dock is on unless shown
```

## Panels, radial wheel, menu bar, settings

- `machud panels` lists panels (siblings' carry `app` and `health`);
  `machud panel id=tooldock action=toggle`; `panel mode id=… mode=parked edge=left`.
  The socket's `subscribe` command (not the CLI) streams `state` events.
- Wheel (⌃⌥Space held, setting `hotkeys.loadoutMenu`; a tap within `hotkeys.tapMilliseconds`
  opens the search bar instead): `machud radial action=show|select|commit|cancel|hide path=<path>`, e.g.
  `path=loadouts/Work/apply`; `machud menu` describes the wheel as a tree (`tree[]`, each node's
  `path`, `kind`, `hint` and `children` or `action`): Apply Loadout holds the loadouts, each with
  Preview / Apply / Clear + Apply; Capture: This screen / Draw layout, with All screens between
  them while multi-desktop loadouts are on; Park: Park / Restore; Widgets: Reveal or Lower /
  Edit or Done. `commit` on a petal with children cancels.
- HUD summon: holding the wheel's hotkey also shows the tool dock (even when off or auto-hidden, on
  the wheel's display) and reveals the widgets, changing no setting. An action puts them back once it
  has run (Capture, Preview, Draw layout and Park see them put back first); letting go on nothing
  leaves them up until Esc, a click away, the hotkey again or a loadout being applied.
  `machud radial action=show summon=1` opens the wheel that way, `machud radial action=dismiss` ends a
  summon left up; `radial` replies carry `summon {active, phase}`, `tooldock` says `summoned`.
  To show the dock for good use `machud tooldock show`, not a summon.
- Menu bar hiding (off until enabled): `machud menubar state|collapse|expand|toggle|peek|enable|disable`.
- MacHUD's settings: `machud settings get`, `machud settings set menuBar.enabled=1`,
  `machud settings schema`.
- Shared settings window (a tab per app): `machud settings-window show tab=Sift`
  (`hide|toggle|state`, `activate=0` to not take focus).
- Setup guide (a checklist overlay: permissions, voice, brain, apps, tooldock, loadout, radial): `machud onboarding status|show [step=brain]|hide|next|back|skip|reset`;
  `machud onboarding snapshot dir=<folder>` renders every step to PNGs offscreen.
- Search bar (apps, files, loadouts, Stash's snippets): `machud search show [query=saf]|hide|state`;
  `machud search query text=saf [files=0]` lists the ranked results without opening the bar;
  `machud search snapshot path=<png> [query=]` renders it offscreen.

## Isolated instances (development and tests)

The user's live MacHUD is the dev build `build/MacHUD.app` of `~/dev/machud` (check with `ps`), on
`/tmp/machud-<uid>.sock`.
**Never quit, kill (`pkill MacHUD`), relaunch or install over it** unless the user asks.
To test, run a separate copy with its own socket, config and no hotkeys:

```sh
MACHUD_SOCKET=/tmp/machud-test.sock MACHUD_CONFIG=/tmp/machud-test/layouts.json \
  MACHUD_NO_HOTKEYS=1 build/MacHUD.app/Contents/MacOS/MacHUD &
MACHUD_SOCKET=/tmp/machud-test.sock machud ping
MACHUD_SOCKET=/tmp/machud-test.sock machud quit
```

With only `MACHUD_SOCKET` the copy's config lives beside the socket, in
`<socket path without extension>-config/layouts.json`, never in `~/.config/machud`.
`MACHUD_APP` points the CLI at a specific binary; `MACHUD_DOCKS_FILE` overrides where the
dock publishes.

**Never run a second instance with drag watching.** An isolated instance does not watch
window drags; do not set `MACHUD_DRAG=1` (or drop `MACHUD_NO_HOTKEYS`) while the live app
runs: both instances react to the same Shift-drag and fight over the window.

## Rules

- Always read `machud status` before and after changing arrangements and tell the user
  what moved. Prefer `plan=1` or `preview` before an unfamiliar `apply`.
- `apply … clear=1`, `clear`, `park`, and applying a HUD loadout affect the user's live
  desktop and apps: do them when asked, not speculatively. After a clear you did not
  intend, run `machud restore`.
- If a command returns `ok: false`, show the `error` and stop.
