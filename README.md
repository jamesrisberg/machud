# MacHUD

_Changes: [CHANGELOG.md](CHANGELOG.md)._

## What it is

MacHUD is the umbrella app of a small family of macOS HUD apps. It is a menu bar app that
turns the screen into a grid you design, then puts things in it, and manages the sibling
apps that make up the rest of the HUD:

- **Snap**: hold **Shift** while dragging any window and it snaps into the region
  under the cursor. **Tab** mid-drag bounces between layouts, **Esc** cancels.
- **Loadouts**: which window goes where. A loadout owns a layout (its regions,
  drawn in a full-screen visual editor or captured from your windows) and what lives
  in each region (an app, a web page in an Arc, Safari, Chrome app-mode or built-in
  window, or a sibling app's panel). Apply one and every window is found (on any
  display or desktop), launched if needed and placed. **Preview** first to see what
  apply would do. A loadout can also hold the HUD itself: the tool dock and every
  sibling's panels.
- **Radial wheel**: hold **⌃⌥Space**, drag toward a loadout, release. Three rings: preview,
  apply, clear this screen and apply.
- **Tool dock**: a Dock-like strip of the sibling apps (**⌃⌥D**).
- **Widgets**: glass tiles on the desktop (a clock, the weather, your servers) that any sibling
  can serve, placed on a grid, under your windows until **⌃⌥W** raises them.
- **Parking**: tuck windows off an edge behind a hover orb.
- **Menu bar**: hide menu bar items behind a separator, Hidden Bar style.
- **Voice**: MacHUD runs its voice host (dictation and the agent brain) as a helper process,
  restarts it if it stops, and has Voice and Brain tabs in its settings. The agent's reply card
  under the notch orb shows the whole conversation while you hover it, and a click opens it
  larger with a field for typing to the agent ([docs/API.md#voice](docs/API.md#voice)).
- **CLI and API**: everything is scriptable through `machud <command>` (JSON over a
  Unix socket). See [docs/API.md](docs/API.md); a Claude Code skill lives in
  `.claude/skills/machud`.

## Install

**Download** MacHUD from <https://jamesrisberg.github.io/machud/>: the zip is signed and
notarized, so unzip it, drag MacHUD to Applications and open it. It lives in the menu bar.
The first launch opens a setup guide over the desktop, a checklist that ticks off as you go:
permissions, voice, the agent brain, the HUD apps (bundled tools preselected), the tool dock,
a first loadout and practice with the radial menu; **Setup Guide…** in the menu opens it again.
Later, **Get Apps…** in the menu (or `machud apps install <name>`) installs,
updates and removes the others from the same catalog. Downloads are checked against the
catalog's size and SHA-256 and must pass Gatekeeper; see
[docs/API.md](docs/API.md#app-catalog-and-installs).

**From source:**

```sh
git clone <machud repo> ~/dev/machud
git clone <hudkit repo> ~/dev/hudkit     # Package.swift depends on ../hudkit
cd ~/dev/machud && ./install.sh
```

`install.sh` builds the app, copies it to `/Applications/MacHUD.app`, links the `machud`
CLI into the first writable directory on your `PATH`
(`/opt/homebrew/bin`, `/usr/local/bin`, `~/bin` or `~/.local/bin`) and opens it. It quits a
running MacHUD first. `build.sh` and `install.sh` are shims into
HUDKit's shared `hud-build.sh`/`hud-install.sh`; MacHUD's extras live in
[scripts/install-hooks.sh](scripts/install-hooks.sh). To check out every sibling at once, see
[Build from source](#build-from-source).

The setup guide asks macOS for **Accessibility** access (needed to see and move
other apps' windows) and the microphone (for voice). Grant Accessibility in System Settings → Privacy & Security →
Accessibility; the app starts watching drags as soon as it's trusted. `machud
permissions request=1` shows every missing prompt (Accessibility and Automation).

## Use

### Hotkeys

| Keys | Result |
| --- | --- |
| Shift while dragging a window | Snap it into the region under the cursor |
| Tab / Esc mid-drag | Next layout / cancel the snap |
| ⌃⌥Space (hold) | Radial wheel: drag to a loadout, release. Inner ring previews, middle ring applies, outer ring clears this screen first; **P** previews the highlighted loadout too. Capture (this screen / all displays / draw a new layout), Park (park the front window / restore parked) and, when an app serves widgets, Widgets (reveal / edit). The hotkey is a setting |
| ⌃⌥D | Show / hide the tool dock |
| ⌃⌥W | Raise the desktop widgets above your windows; again or Esc lowers them |
| ⌃⌥B | Collapse / expand the menu bar (when menu bar management is on) |

Each loadout can also have its own hotkey. All hotkeys live in `layouts.json`.

### Snapping

- Drag a window by its title bar and hold **Shift**. An overlay shows the active
  layout; the region under the cursor lights up. Release to snap. Let go of
  Shift before releasing (or never hold it) and the window drops normally.
- **Tab** while dragging cycles layouts. **Esc** cancels the snap.
  Dropping outside every hit zone also leaves the window alone.
- Snapping only ever snaps: with no layout yet, Shift-drag shows a toast
  offering the editor instead of opening it.
- Menu bar icon, top to bottom: snapping and the trigger key (Shift / Option / Control /
  Command / Always), Launch at Login, Permissions, Settings…; the Menu Bar manager;
  **Loadouts** (each with Preview…, Apply, Clear This Screen + Apply, Edit Layout…, Apply
  at Startup and Delete; then Capture Windows as Loadout…, Save Dock and Panels as HUD
  Loadout…, Draw a New Layout…, the Snap Layout ⇧-drag uses, and Restore Cleared Windows);
  the Tool Dock, **Widgets** (Reveal, Edit Widgets…, Add Widget, and each widget's Settings…,
  Float Above Windows and Remove), then **Apps** (Launch All Apps and Quit All Apps, plus Relaunch Outdated Apps
  while an app runs an older build than its bundle on disk, then each app with Show, its own menu,
  Hide/Park, Show on Tool Dock, Settings, Relaunch and Launch or Quit) and Get Apps…; **Advanced** for the JSON file.
- Capturing asks for the loadout's name, whether to also keep its layout on its own (for
  ⇧-drag and other loadouts, under its own name) or only for this loadout, and whether to
  save the tool dock and the apps' panels with it. Windows MacHUD has parked are captured
  as parked slots and park again on apply.

### Tool dock

A Dock-look strip of MacHUD apps, on by default at the bottom of the main display:
one button per sibling app (its real icon, a dot while it runs), **hover apps first,
then windowed apps**, with a thin divider between them.

- **Where**: eight positions. At an edge it is a single row or column; in a corner
  it is an L with the hover apps up the side and the windowed apps along the top or
  bottom. Drag it by its background and it snaps to the nearest one, or pick one from
  Position on Screen in its menus or the settings window (`toolDock.position`).
- **Hover apps** (Stash, Scratch, ffmpegHUD, …) slide their panel out of the dock 60 ms
  after the pointer reaches their button. Move down into the panel and it stays; move
  away and it fades within about an eighth of a second. Sliding along the dock to
  another hover app cross-fades between them. Click to pin one open.
- **Windowed apps** (Sift, MechaHUD, …) summon and dismiss on click and come back
  where they were.
- **Files**: apps that take files (their manifest says `acceptsFileDrop`) take drops
  on their button; rest on it with the drag to open the panel first.
- **Siblings' docks**: the dock publishes where it is to `docks.json`, so Sift's dock
  mode can sit alongside it.
- Right-click a button to park or place its panel, quit the app or open its settings.
  Script it with `machud tooldock …`, `machud summon id=…` and `machud dismiss id=…`.

**Save your setup**: status menu › Loadouts › **Save Dock and Panels as HUD Loadout…** records
the dock's position and every running sibling's panels (shown or hidden, mode, frame,
and where Sift's own dock sits). With "Put it back when MacHUD starts" checked, it is
the `startupLoadout` and comes back about two seconds after launch
(`machud capture name=Desk hud=only`, then `machud apply loadout=Desk`, from a
script). See docs/API.md.

### Desktop widgets

Any sibling app can serve widgets: small glass tiles on the desktop, such as a clock or the
dev servers that are up. MacHUD places them and remembers where.

- **Add**: status menu › Widgets › Add Widget, or **Edit Widgets…**, which opens a gallery of
  every widget by app with an Add button per size. Small is one grid cell, medium two side by
  side, large two by two, extra large four by two. A widget can be placed several times, each
  with its own settings.
- **Arrange**: in edit mode the widgets unlock: drag one and it snaps to the nearest free cells
  of the grid shown on each display; its corner controls remove it, open its settings and step
  through its sizes. Done or Esc locks them again.
- **Layers**: widgets sit on the desktop under your windows. **⌃⌥W** raises them all above
  windows until you press it again or Esc; Float Above Windows keeps one on top for good.
- They are on every desktop, come back where they were after a restart, a display change or the
  app relaunching, and never take focus. An app with widgets is kept running. A HUD loadout saves
  the widgets with it and puts them back when applied.
- Script them with `machud widgets …` (`list`, `types`, `add type=clock`, `move`, `resize`,
  `layer`, `settings`, `remove`, `edit on`, `reveal on`); see docs/API.md.

### Loadouts

A loadout names a layout and assigns an occupant per region:

```json
{ "name": "Work", "layout": "Thirds", "slots": [
  { "regionID": "<region id>", "occupant": { "kind": "app", "bundleID": "com.apple.Safari", "titleMatch": "GitHub" } },
  { "regionID": "<region id>", "occupant": { "kind": "web", "url": "https://x.com", "host": "arc" } },
  { "regionID": "<region id>", "occupant": { "kind": "panel", "id": "xyz.machud.sift/browser" } }
]}
```

The easy way: arrange windows, then **Capture…** from the wheel, the menu bar,
or `machud capture name=Work`. Capture derives the layout from the windows
themselves (one region per window at its exact frame, overlapping windows kept
overlapping and in stacking order)
and the loadout that fills it, under one name. Move windows and recapture to
update it, or refine regions and occupants in the editor. Sibling apps' panels
are windows too: ⇧-drag them into regions or capture them like anything else.
Apply from
the wheel, the menu bar, a per-loadout hotkey, or `machud apply loadout=Work`.
`clear=1` first minimises the other windows on each screen the loadout covers (on the
desktops it visits); `machud restore` or Loadouts › Restore Cleared Windows undoes that.

**Preview** (a loadout's Preview…, the wheel's inner ring, or `machud
apply loadout=Work plan=1` for the JSON) shows every region coloured by what
apply will do: green placed/moved, blue launched, orange a desktop switch, red
cannot (with the reason). Regions on the desktops that are showing can be dragged and
resized right there (snapping to the layout grid); Apply saves the changes into the
loadout's layout and applies, Edit Layout… opens the full editor. Slots bound to other
desktops appear small in an "Other desktops" mini-map by the controls. A window already
open on another display is moved; one on a desktop that is not showing is fetched, given
a new window, or left, per `"spaces": {"policy": "bring" | "launchNew" | "leave"}`.
`docs/PLACEMENT.md` spells out the rules.

### Layouts and the visual editor

Menu bar → Loadouts → a loadout → **Edit Layout…** (its regions, with its occupants),
**Draw a New Layout…** for an empty canvas (also the wheel's Capture wedge, outer ring),
or Snap Layout → **Edit Snap Layout…**. With no layout yet, a Shift-drag offers
the editor in a toast. The screen dims and shows a fine snap grid
(96 × 54 by default; pick 24 × 12 up to 192 × 108 from the panel).

Shapes always land exactly on grid lines and spring from line to line as you
drag. Each region card shows glass buttons in its top-right corner when hovered
or selected: **✕** delete, **✎** rename, **⊕** paint a hit zone (click it, then
drag anywhere; click again on a region that has one to clear it).

The floating glass panel holds the layout picker (+ new, ✎ rename, 🗑 delete),
the grid density, help, Cancel and Save. It slides out of the way of regions on
its own. Drag it by its ⋮⋮ grip to move it somewhere else; that spot becomes
its new home and it keeps dodging regions from there.

| Keys | Result |
| --- | --- |
| Drag on empty space / region / edge | Create / move / resize |
| ⌘-drag anywhere | Create a region, even on top of another (stacked windows) |
| ⌘↑ / ⌘↓ | Raise / lower the selected stacked region |
| ⌥-drag, or H | Paint hit zone for the selected region |
| ⌫ / ⌥⌫ | Delete region / clear its hit zone |
| ⏎ | Rename selected region |
| Arrow keys | Nudge one grid cell |
| Tab | Next layout |
| ⌘Z / ⌘S / ⌘. | Undo / Save / Cancel |
| ? | Toggle the shortcut sheet |

Nothing touches `layouts.json` until you hit Save.

Config lives at `~/.config/machud/layouts.json`, created empty on first run,
and hot-reloads when saved. Everything below can be drawn in the visual editor;
the JSON is there if you prefer to type it.

```jsonc
{
  "gap": 8,                       // optional points of space between regions / screen edges
  "trigger": "shift",             // shift | option | control | command | always
  "grid": { "cols": 96, "rows": 54 },   // editor snap grid
  "layouts": [
    {
      "name": "Sidebar + Main",
      "regions": [
        // x, y from the TOP-LEFT of the screen's visible area; all values are 0–1 fractions.
        { "name": "Sidebar",  "x": 0,    "y": 0,    "w": 0.22, "h": 1 },
        { "name": "Main",     "x": 0.22, "y": 0,    "w": 0.78, "h": 1 },
        // "hit" is where the cursor must be to pick this region (defaults to the region itself).
        // The *smallest* hit zone containing the cursor wins, so a small central hit zone
        // can live inside "Main".
        { "name": "Centered", "x": 0.15, "y": 0.08, "w": 0.7, "h": 0.84,
          "hit": { "x": 0.36, "y": 0.32, "w": 0.28, "h": 0.36 } }
      ]
    }
  ]
}
```

Regions may overlap freely; use `hit` to disambiguate. Hit zones that differ
from their region are drawn as dashed outlines in the overlay.

### Menu bar

MacHUD can tidy the menu bar the way Hidden Bar and Dozer do, with public API
only. Turn it on from the status menu (Menu Bar › Hide Menu Bar Items), the
settings window, or `machud settings set menuBar.enabled=1`. Two items appear:
a thin │ separator and a chevron expander to its right. ⌘-drag the items you
want hidden to the left of the separator.

- Click the chevron (or press ⌃⌥B) to collapse or expand; right-click it for
  options. Collapsing stretches the separator so everything left of it is
  pushed off the menu bar.
- Rest on the chevron for 150 ms to peek; leaving the menu bar for 600 ms hides
  them again (the parking orb's timings). A click while peeking keeps them.
- Auto-collapse (default 10 s, `menuBar.autoCollapseSeconds`, 0 = never) waits
  while the mouse is in the menu bar or any menu is open.
- `machud menubar state|collapse|expand|toggle|peek`, and the `menubar` panel
  (`panel mode compact|full id=menubar`) for siblings and loadouts.

Limits: macOS keeps some items where they are (Control Center, the clock, and
anything the system pins right of your items), so those cannot be hidden. On a
Mac with a notch, items that do not fit are already clipped behind the notch;
collapsing still helps by moving the ones you chose out of the way, but it
cannot bring back items the notch hides while expanded. If the separator ends up
right of the chevron, collapsing is refused until you ⌘-drag it back.

### How snapping works

- Global `NSEvent` monitors watch left mouse down/drag/up. On mouse-down the
  window under the cursor is resolved via the Accessibility API; during the
  drag its frame is polled, and a moved-but-not-resized window is treated as a
  window drag.
- A click-through overlay `NSWindow` draws the layout on the screen under the
  cursor. On mouse-up the target region's frame is written back with
  `AXUIElementSetAttributeValue`.
- A `CGEventTap` swallows Tab/Esc only while a drag is in progress.

## Sibling apps

MacHUD finds MacHUD-aware apps by their `machud.json` manifest (in `/Applications`,
`~/Applications` and any `apps.searchPaths`), supervises them, puts their panels in
loadouts and on the tool dock, parks them, and places the desktop widgets they serve. Every sibling also works on its own.
Released ones are listed in the app catalog and install from Settings → Apps.
The repos sit next to this one (`~/dev/<name>`); `workspace.json` lists them.

| Repo | Kind | What it does |
| --- | --- | --- |
| [hudkit](../hudkit) | Swift package | The shared contract (manifest, socket, verbs) and visual language (glass panels, animation, hotkeys) every sibling builds on |
| [sift](../sift) | windowed app | On-screen file manager: browse, preview, triage, batch rename |
| [stash](../stash) | hover app | Clipboard history with search |
| [scratch](../scratch) | hover app | Floating scratchpad: type, transform, copy, clear |
| [mechahud](../mechahud) | windowed app | Hosts the mechaclaude dashboard in a glass panel |
| [ffmpeghud](../ffmpeghud) | hover app | ffmpeg presets (GIF, compress, trim, extract audio) for dropped files |
| [magickhud](../magickhud) | hover app | ImageMagick presets for dropped images |
| [servershud](../servershud) | hover app | Every dev server listening on your Mac, with stop and open |
| [wormhole](../wormhole) | menu bar app (Xcode) | Glowing drop target that sends files with Magic Wormhole |
| [archibald](../archibald) | menu bar app (Xcode) | Wake-phrase voice agent with an orb and transcript panel |

Hover apps slide their panel out of the tool dock on hover; windowed apps are summoned
and dismissed on click.

## Contract

MacHUD implements the same contract as its siblings (defined in HUDKit):

- **Manifest**: `MacHUD.app/Contents/Resources/machud.json` (from
  [Sources/MacHUD/Resources/machud.json](Sources/MacHUD/Resources/machud.json)) names the app id
  `com.jrisberg.machud`, its socket `machud` and its panels (`menubar`), readable
  without launching the app.
- **Contract socket**: `~/Library/Application Support/MacHUD/sockets/machud.sock`
  answers `hello`, `state`, `subscribe`, `settings`, `panel` and the rest of the HUDKit
  verbs.
- **Control socket**: `/tmp/machud-<uid>.sock`, what the `machud` CLI talks to. It
  answers every MacHUD command (layouts, loadouts, apply/plan/preview, capture, dock,
  park, apps, menubar, settings-window, quit) plus the contract verbs.

One JSON object per line in, one out: `{"command": "ping", "args": {}}` →
`{"ok": true, "pid": 123}`. The full reference is [docs/API.md](docs/API.md);
[docs/INTEGRATION.md](docs/INTEGRATION.md) covers the end-to-end smoke test with siblings.

## Settings

- The **settings window** (status menu › Settings…, or `machud settings-window show`)
  has a tab for MacHUD, a Loadouts tab, Voice and Brain tabs for the voice host, and one
  per discovered sibling, rendered from each app's settings schema.
- The **Loadouts** tab lists every loadout; selecting one previews it per display and
  desktop (its apps, parked windows and HUD part), with Apply, Preview, Edit Layout, Rename,
  Duplicate, Apply at Startup, Delete and New. The same edits from the shell: `machud
  loadouts rename name=Work to=Studio`, `duplicate`, `delete`, `startup`.
- Voice settings live with the voice host: the Voice and Brain tabs, or `machud voice
  settings get` and `machud voice settings set voice.speakReplies=true`. See
  [docs/API.md#voice](docs/API.md#voice).
- MacHUD's own settings over the socket: `machud settings get`, `machud settings set
  gap=12 trigger=option`, `machud settings schema`. Keys: `enabled`, `trigger`
  (shift/option/control/command/always), `gap`, `browser`, `orbsHidden`,
  `menuBar.enabled`, `menuBar.autoCollapseSeconds`, `toolDock.*`.
- Files: `~/.config/machud/layouts.json` (layouts, loadouts, hotkeys, `apps`,
  `toolDock`, `menuBar`, `spaces`, `startupLoadout`; hot-reloaded) and
  `~/.config/machud/state/`. See [docs/API.md#files](docs/API.md#files).

## Build from source

```sh
./build.sh           # → build/MacHUD.app (signed with your Apple Development cert if present, else ad-hoc)
./build.sh debug     # debug configuration
swift test           # MacHUDTests
```

Requirements: macOS 14+, Swift 5.9+, and a [HUDKit](../hudkit) checkout at `../hudkit`.
The version is in [VERSION](VERSION) only: `hud-build.sh` writes it (and the commit count as
the build number) into the bundle's copy of `Sources/MacHUD/Resources/Info.plist`, and signs
with hardened runtime and [MacHUD.entitlements](MacHUD.entitlements) (Apple Events).

The whole family can be driven from here with `scripts/hud-workspace.sh`, which reads
[workspace.json](workspace.json) and runs against the sibling directories next to this
repo (missing ones are skipped with a note):

```sh
scripts/hud-workspace.sh clone     # clone missing siblings (fill in the git urls first)
scripts/hud-workspace.sh status    # git status -sb for each
scripts/hud-workspace.sh build     # ./build.sh (SwiftPM) or print the xcodebuild command (Xcode)
scripts/hud-workspace.sh test      # swift test for each SwiftPM repo
scripts/hud-workspace.sh install   # each repo's install.sh
scripts/hud-workspace.sh clean     # delete each repo's .build
```

## Isolation env vars

Run an isolated copy (tests, trying a build) next to the real one without fighting over
its socket, config or hotkeys:

```sh
MACHUD_SOCKET=/tmp/machud-try.sock MACHUD_CONFIG=/tmp/machud-try/layouts.json \
  MACHUD_NO_HOTKEYS=1 build/MacHUD.app/Contents/MacOS/MacHUD &
MACHUD_SOCKET=/tmp/machud-try.sock scripts/machud ping
MACHUD_SOCKET=/tmp/machud-try.sock scripts/machud quit
```

| Variable | Effect |
| --- | --- |
| `MACHUD_SOCKET` | Control socket path |
| `MACHUD_CONFIG` | `layouts.json` path; the dock publishes to `docks.json` beside it |
| `MACHUD_NO_HOTKEYS` | Register no global hotkeys and do not watch window drags |
| `MACHUD_DRAG` | With `MACHUD_NO_HOTKEYS`, watch drags anyway. Do not use while another instance runs: both react to the same drag |
| `MACHUD_DOCKS_FILE` | Where the tool dock publishes its frames |
| `MACHUD_APP` | The binary the `machud` CLI runs |
| `MACHUD_FIRST_RUN` | `1`: an isolated copy shows the onboarding at launch too |
| `MACHUD_APPLY_STARTUP` | `1`: an isolated copy applies `startupLoadout` at launch, re-applies the active loadout when displays change, and launches the `apps.autoLaunch` siblings (with their placement), as the real one does |
| `MACHUD_INSTALL_SKIP_GATEKEEPER` | `1`: installs skip the `spctl` check so a dev-signed zip installs. Test-only |
| `MACHUD_VOICE_SOCKET` | The voice host's socket. An isolated copy without it uses `<MACHUD_SOCKET>-voice.sock` (else `machud-voice.sock` beside `MACHUD_CONFIG`) |
| `MACHUD_VOICE_NO_MIC` | `1`: the voice host simulates capture and never opens the microphone |
| `MACHUD_VOICE_NO_BRAIN` | `1`: the voice host never starts the brain |
| `MACHUD_VOICE_HEADLESS` | `1`: the voice host puts no orb on screen |
| `MACHUD_VOICE_NO_SPEECH` | `1`: the voice host's replies and `say` make no sound |
| `MACHUD_VOICE_MODELS_DIR` | Where the voice host keeps downloaded models (default `~/Library/Application Support/MacHUD/Voice/Models`) |
| `MACHUD_VOICE_HISTORY_DIR` | MacHUD's own dictation history folder (default `~/Library/Application Support/MacHUD/Voice/History`) |
| `SPEAKFREE_CONFIG_DIR` | SpeakFree's config folder the voice host reads (`saveRecordings`) and shares history into (default `~/.config/speakfree`) |
| `MACHUD_VOICE_KEYCHAIN_SERVICE` | The Keychain service the voice host keeps the Grok key under |
| `MACHUD_VOICE_LIVE` | `1`: an isolated copy runs its voice host with the microphone, brain, orb, sound and the real models folder |
| `MACHUD_VOICE_PARENT_PIPE` | Set by MacHUD for the voice host: it exits when MacHUD's end of its stdin closes |

The voice host inherits MacHUD's environment, so `MACHUD_CONFIG`, `MACHUD_NO_HOTKEYS` and the
`MACHUD_VOICE_*` switches reach it. An isolated copy sets `MACHUD_VOICE_NO_MIC`, `NO_BRAIN`,
`HEADLESS` and `NO_SPEECH` to `1` for it and models and history folders beside its voice socket (unless
`MACHUD_VOICE_LIVE=1`), and a Keychain service of its own
(`com.jrisberg.machud.voice.isolated`, unless `MACHUD_VOICE_KEYCHAIN_SERVICE` is set).

Setting `MACHUD_SOCKET` or `MACHUD_CONFIG` marks the instance isolated: it does not serve
the contract socket or show permission prompts, and it acts on windows and apps only when
asked (no startup loadout, no re-apply on display changes, no `autoLaunch`). What it is
asked to do still happens for real: `apply`, `capture`, `clear`, `park` and the rest move
the user's own windows through Accessibility. Never `pkill MacHUD`: that
kills the real one; quit an isolated copy through its own socket.

## Architecture

MacHUD is the umbrella: it places windows, hosts the tool dock and drives each sibling app
over that app's HUDKit control socket. The contract every app implements, the family's
conventions and the shared build tooling are HUDKit's:
[CONTRACT.md](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md) and
[CONVENTIONS.md](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONVENTIONS.md).
[docs/README.md](docs/README.md) indexes every doc in this repo.

## License

MIT, see [LICENSE](LICENSE).
