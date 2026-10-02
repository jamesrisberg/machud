---
name: machud
description: Control the user's MacHUD desktop from the shell — inspect window layouts, apply, preview or capture loadouts (which apps/pages go in which screen region, plus the HUD setup), move windows into regions, drive the MacHUD tool dock (position, summon/dismiss sibling apps, drop files on them), place and arrange desktop widgets, park windows behind orbs, manage the menu bar, and open panels and the shared settings window. Use whenever the user asks to arrange windows, set up or switch a workspace, or move/configure the tool dock, desktop widgets or sibling HUD apps.
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
machud loadouts                     # saved loadouts (including HUD-only ones)
machud status                       # what is in each region right now
machud windows                      # every on-screen window with CGWindow numbers
machud screens                      # displays (persistentID), desktop count and current desktop
machud apps                         # sibling apps: health, reachable, panels
machud hello                        # contract handshake: app id com.jrisberg.machud, hudkit version, verbs
```

Regions are identified by `id` (stable UUIDs). Windows by `window` number.
Coordinates are Cocoa points (origin bottom-left).

## Arrange windows

- Put one window somewhere: `machud place window=<n> region=<id>`.
- **Plan before applying**: `machud apply loadout="Work" plan=1` is a dry run returning
  `plan[]` of `{slot, region, occupant, action, from?, to, reason, window?}` (`stay`,
  `resize`, `move`, `switchSpace`, `launch`, `leave`, `cannot`); nothing moves. Read it
  before applying. `machud preview loadout="Work"` draws the same plan over every display
  for the user (`action=apply|cancel` answers it).
- Apply a saved workspace: `machud apply loadout="Work"`; add `clear=1` to minimise
  everything else first. The reply's `slots[]` carries each step's `result`.
- Save the current arrangement: `machud capture name="Work"` derives a layout from the
  windows themselves (one region per window) plus the loadout that fills it. Add
  `layout=<name>` to only record what sits in an existing layout's regions.
- Clear the desk: `machud clear` (every desktop; sibling MacHUD apps and hidden apps are
  left alone); undo with `machud restore`.
- Switch which layout Shift-drag snapping uses: `machud select-layout name=<name>`.
- Several displays: `machud status screen=builtin`. `machud capture name="Studio"
  screens=all` derives one layout per display (`Studio · <display>`) into one loadout.
  Add `desktops=1,2` (or `desktops=main:1,2;builtin:1`) to walk desktops too. **Walking
  desktops is visible to the user: keep it short and only when asked.**
  `screens=Thirds@main,Full@builtin` is the fill-only form. Slots may carry `"space": N`.
  `machud spaces` shows desktop shortcuts; `machud spaces action=switch n=2` switches.
- A loadout captured on a now-unplugged display still applies: it is redirected to its
  `fallback`, else the main display. `apply`/`status` report `redirected[]`;
  `reason: needsDesktops` means the user must add desktops in Mission Control.
- Open the visual editor for the user: `machud edit` (`loadout=<name>` on that loadout,
  `new=1` on a blank layout). Manage saved loadouts: `machud loadouts rename name=A to=B`,
  `duplicate name=A [to=]`, `delete name=A` (also removes the hidden layouts captured for it),
  `startup name=A` (no name clears). The settings window's Loadouts tab
  (`machud settings-window show tab=loadouts`) shows them all with previews.

To build a loadout by hand, edit `~/.config/machud/layouts.json` (`loadouts[]` with
`slots[] {regionID, occupant}`, optional `screens[]`, `whenScreenMissing: desktop|skip`,
optional `hud`; occupant kinds: `app` `{bundleID, titleMatch?}`, `web` `{url, host:
arc|safari|chromeApp|builtin}`, `panel` `{id}` where `id` may be a sibling's
`<bundle id>/<panel>`), then `machud reload`. Displays change ⇒ the active loadout is
re-applied on its own.

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
machud tooldock                               # position, segments, buttons {title, group, kind, acceptsDrop, frame, edge}, neighbors
machud tooldock show|hide|toggle
machud tooldock position position=topLeft     # bottom|top|left|right (row/column) or topLeft|topRight|bottomLeft|bottomRight (an L)
machud tooldock autohide value=on             # also: magnify
machud tooldock click id=Scratch              # what clicking the button does
machud tooldock drop id=magickHUD paths=/path/a.png,/path/b.png   # hand files to an app that takes drops
```

Buttons list hover apps (Stash, Scratch, ffmpegHUD, …) first, then windowed apps
(Sift, MechaHUD, …).

## Desktop widgets

Siblings serve widget types (`kind: widget` panels; widgetHUD's clock, weather, calendar).
MacHUD places instances on a per-display grid (cells from the top-left; small 1×1, medium 2×1,
large 2×2, extraLarge 4×2) and keeps the serving app running.

```sh
machud widgets types                          # every type: app, sizes, multiple, settingsSchema
machud widgets                                # placed: instance, type, size, col/row, display, frame, layer, problems
machud widgets add type=clock [size=medium] [col=0 row=0] [screen=builtin] [layer=float] [settings='{"zone":"UTC"}']
machud widgets move instance=8F0C1E2A col=2 row=0   # nearest free cells; `note` says when it moved elsewhere
machud widgets resize instance=8F0C1E2A size=medium
machud widgets layer instance=8F0C1E2A float        # or desktop
machud widgets settings instance=8F0C1E2A zone=Asia/Tokyo   # merged, checked by the type's schema
machud widgets remove instance=8F0C1E2A
machud widgets edit on|off|toggle             # unlock + gallery + grid overlay (visible to the user)
machud widgets reveal on|off|toggle           # raise desktop widgets above windows (⌃⌥W)
```

An app that serves only widgets has no tool dock button. `missingType`: its app no longer
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
- Wheel (⌃⌥Space, setting `hotkeys.loadoutMenu`): `machud radial action=show|select|commit|cancel|hide
  index=<n> ring=inner|middle|outer`; `machud menu` describes the wedges (a loadout:
  Preview / Apply / Clear this screen + Apply; capture: this screen / all screens / draw a
  new layout; park: park front window / restore parked).
- Menu bar hiding (off until enabled): `machud menubar state|collapse|expand|toggle|peek|enable|disable`.
- MacHUD's settings: `machud settings get`, `machud settings set menuBar.enabled=1`,
  `machud settings schema`.
- Shared settings window (a tab per app): `machud settings-window show tab=Sift`
  (`hide|toggle|state`, `activate=0` to not take focus).
- Setup guide (a checklist overlay: permissions, voice, brain, apps, tooldock, loadout, radial): `machud onboarding status|show [step=brain]|hide|next|back|skip|reset`;
  `machud onboarding snapshot dir=<folder>` renders every step to PNGs offscreen.

## Isolated instances (development and tests)

The user's live MacHUD runs from `/Applications/MacHUD.app` on `/tmp/machud-<uid>.sock`.
**Never quit, kill (`pkill MacHUD`), relaunch or install over it** unless the user asks.
To test, run a separate copy with its own socket, config and no hotkeys:

```sh
MACHUD_SOCKET=/tmp/machud-test.sock MACHUD_CONFIG=/tmp/machud-test/layouts.json \
  MACHUD_NO_HOTKEYS=1 build/MacHUD.app/Contents/MacOS/MacHUD &
MACHUD_SOCKET=/tmp/machud-test.sock machud ping
MACHUD_SOCKET=/tmp/machud-test.sock machud quit
```

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
