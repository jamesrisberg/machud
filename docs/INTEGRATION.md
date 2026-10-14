# MacHUD integration smoke test

`scripts/integration-smoke.sh` drives an **isolated** MacHUD (its own socket, config and
no hotkeys) against dev builds of Sift and Wormhole, end to end: discovery, default
placement on launch (MacHUD parks Wormhole at the right edge, from
`apps.JER.wormhole.placement`), showing each panel, a loadout
that places Sift in the left half and parks Wormhole right (cooperatively, over its socket),
revealing a parked panel as the orb does, the shared settings window reading each app's
schema, the tool dock (its button list, an L in the top-left corner, and a HUD loadout
captured with `capture hud=only` that puts the dock and the panels back), and quitting
the apps. It never talks to the live instance
(`/tmp/machud-<uid>.sock`; the script refuses it) and quits only the siblings it
launched itself.

## Prerequisites

```sh
./build.sh debug                                  # build/MacHUD.app in this checkout
(cd ~/dev/sift && ./build.sh)                     # ~/dev/sift/build/Sift.app
xcodebuild -project ~/dev/wormhole/wormhole.xcodeproj -scheme wormhole -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath ~/dev/worktrees/_dd-wormhole build
```

Wormhole is placed over its socket when its manifest lists `frame` and `mode`, else through
Accessibility.

## Running

```sh
scripts/integration-smoke.sh                # everything is quit again at the end
KEEP_RUNNING=1 scripts/integration-smoke.sh # leave the instance and the apps up to poke at
```

Environment: `MACHUD_BIN`, `MACHUD_SOCKET` (default `/tmp/machud-test-int.sock`),
`TEST_DIR` (default `/tmp/machud-test-int`, holds `layouts.json`, parking state and the
log), `SIFT_BUILD`, `WORMHOLE_BUILD`. To talk to the instance by hand:

```sh
MACHUD_SOCKET=/tmp/machud-test-int.sock build/MacHUD.app/Contents/MacOS/MacHUD ctl panels
```

The config it writes: a layout `MacHUD` with regions `left` (left half) and `right`; a loadout
`Ecosystem` with Sift in `left` and Wormhole parked `right`; `apps.searchPaths` at the two
build directories with `standardDirectories: false`; and `apps.JER.wormhole.placement` =
`{"mode": "parked", "edge": "right"}`. `Ecosystem` is a one-screen loadout (a loadout is the
display under the pointer, on the desktop showing); the config leaves `experimental` out, so
multi-desktop loadouts (`experimental.multiDesktopLoadouts`, off by default, see
[API.md](API.md#multi-desktop-loadouts-experimental)) are off in the run.

## Sample run (main display 1728 pt wide)

The output below is illustrative; the script itself is the source of truth. Replies are
trimmed by the script's `jq` filters. Frames are Cocoa coordinates.

```
$ machud apps
{"ok":true,"apps":[{"id":"xyz.machud.sift","health":"notRunning"},{"id":"JER.wormhole","health":"notRunning","placement":{"edge":"right","mode":"parked"}}]}

$ machud apps launch id=JER.wormhole
{"ok":true,"placement":"pending","health":"launching"}

$ machud apps
{"ok":true,"apps":[{"id":"JER.wormhole","health":"running","placement":{"edge":"right","mode":"parked"},"placementResult":"applied"}]}

$ machud park list
{"ok":true,"parked":[{"id":"app:JER.wormhole","label":"Portal","kind":"cooperative","edge":"right"}]}

$ machud panel show id=xyz.machud.sift/browser
{"ok":true,"visible":false,"mode":"full"}

$ machud panel show id=JER.wormhole/portal
{"ok":true,"visible":true,"mode":"parked"}

$ machud panels
{"ok":true,"panels":[{"id":"xyz.machud.sift/browser","health":"running","cooperative":true,"visible":true,"mode":"full"},{"id":"JER.wormhole/portal","health":"running","cooperative":true,"visible":true,"mode":"full"}]}

$ machud apply loadout=Ecosystem
{"ok":true,"placed":["left","right"],"failed":{}}

$ machud panels
{"ok":true,"panels":[{"id":"xyz.machud.sift/browser","mode":"full","frame":{"h":1084,"w":864,"x":0,"y":0}},{"id":"JER.wormhole/portal","mode":"parked","frame":{"h":434,"w":692,"x":1728,"y":271}}]}

$ machud park list
{"ok":true,"parked":[{"id":"right","label":"Portal","kind":"cooperative","edge":"right","rest":{"h":434,"w":692,"x":1036,"y":271}}],"orbs":[{"edge":"right","count":1}]}

$ machud panels
{"ok":true,"panels":[{"id":"xyz.machud.sift/browser","visible":true,"mode":"full","frame":{"h":1084,"w":864,"x":0,"y":0}},{"id":"JER.wormhole/portal","visible":true,"mode":"parked","frame":{"h":434,"w":692,"x":1728,"y":271}}]}

$ machud park reveal edge=right pin=1
{"ok":true,"revealed":1}

$ machud panels
{"ok":true,"panels":[{"id":"JER.wormhole/portal","visible":true,"mode":"full","frame":{"h":434,"w":692,"x":1036,"y":271}}]}

$ machud park conceal edge=right
{"ok":true,"concealed":1}

$ machud panels
{"ok":true,"panels":[{"id":"JER.wormhole/portal","mode":"parked","frame":{"h":434,"w":692,"x":1728,"y":271}}]}

$ machud settings-window show activate=0
{"ok":true,"visible":true,"tabs":[{"id":"machud","status":"ready","schema":"socket","keys":["enabled","trigger","gap","browser","orbsHidden"]},{"id":"xyz.machud.sift","status":"ready","schema":"bundle","keys":["defaultFolder","collisionPolicy","showHidden","rulesAutoApply"]},{"id":"JER.wormhole","status":"ready","schema":"none","keys":["activeSet","hotkey","sets"]}]}

$ machud settings get key=trigger
{"ok":true,"value":"shift"}

$ machud settings-window state
{"ok":true,"sift":[{"key":"defaultFolder","control":"path","value":""},{"key":"collisionPolicy","control":"choice","value":"keepBoth"},{"key":"showHidden","control":"toggle","value":false},{"key":"rulesAutoApply","control":"toggle","value":false}]}

$ machud settings-window hide
{"ok":true,"visible":false}

$ machud apps quit id=xyz.machud.sift
{"ok":true,"id":"xyz.machud.sift","wasRunning":true}

$ machud apps quit id=JER.wormhole
{"ok":true,"id":"JER.wormhole","wasRunning":true}

$ machud apps
{"ok":true,"apps":[{"id":"xyz.machud.sift","health":"notRunning"},{"id":"JER.wormhole","health":"notRunning","placement":{"edge":"right","mode":"parked"},"placementResult":"applied"}]}

$ machud park list
{"ok":true,"parked":[],"orbs":[]}

```

What it shows:

- `apps launch` of an app with a configured placement answers `pending`; once the app is
  listening its placement is applied (`placementResult: applied`) and it is parked
  cooperatively (`app:<bundle id>`).
- `panel show` answers with the state MacHUD had before the app confirmed; `panels` a
  moment later has every panel visible and cooperative.
- After `apply`, Sift fills the left half (864 of 1728 pt) and Wormhole's portal sits past the
  right edge (x 1728, rest x 1036); the loadout's parking replaces the one from launch.
  `park list` records it as `cooperative` with one orb on the right. Cooperative parking is
  shown with Wormhole alone: Sift parks cooperatively too, but here it fills a region.
- `park reveal edge=right` (what hovering the orb does) brings the portal back to its rest
  frame with `panel mode full`; `park conceal` parks it again.
- The settings window has a tab per app plus MacHUD. MacHUD serves its schema over the
  socket (`settings schema`); Sift's comes from its bundle; Wormhole ships none, so its tab lists the keys it reports.
- The tool dock lists the hover apps first, then the windowed ones (Sift, Wormhole);
  at `topLeft` it has two arms, hover buttons against the left edge and windowed ones
  against the top. `capture name=HUD hud=only` records `dock.position` and each app's
  panels (Sift's `dock.edge` setting with them); after moving the dock to the bottom,
  `apply loadout=HUD` puts it back at `topLeft` (`hud.apps` all `applied`). The
  instance's `docks.json` lives in the test directory.
- Quitting an app drops its parkings and orbs (`park list` ends empty).

## Known gaps

- The sample replies above do not include the tool dock steps; the tool dock bullet
  under "What it shows" describes them.
- The run parks at the right edge only; `ParkingTests` covers the other edges.
- Sift, Stash, Scratch, ffmpegHUD, magickHUD, serversHUD, Wormhole and MacHUD's
  own panels honour the `edge=`/`peek=` that MacHUD sends with `panel mode parked`. HUDKit's
  default `setPanelMode(_:mode:options:)` drops the options, so each app opts in by
  implementing it. Archibald implements only `setPanelMode(_:mode:)`: it ignores `edge=` and
  `peek=` and parks its orb at the edge it sits on, or at the nearest edge when the orb is
  free-placed. widgetHUD has no panels to park. Top-edge parking relies on `HUDPanelWindow`
  keeping AppKit from clamping frames below the menu bar.
- A cooperative panel the user brings back through the app itself (its hotkey, `panel show`)
  stays in `park list` until it is re-parked, revealed or unparked.
