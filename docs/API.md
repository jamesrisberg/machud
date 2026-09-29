# MacHUD control API

MacHUD listens on a Unix socket (`/tmp/machud-<uid>.sock`, override with
`MACHUD_SOCKET`). Without the override it also answers on the MacHUD path
`~/Library/Application Support/MacHUD/sockets/machud.sock` named by its
`Contents/Resources/machud.json`. One JSON object per line in, one out.

```
request:  {"command": "<name>", "args": {"key": "value", ...}}
response: {"ok": true, ...}   or   {"ok": false, "error": "...", "commands": [...]}
```

The `machud` CLI (`scripts/machud`, installed to `/usr/local/bin` by
`install.sh`) wraps it: `machud <command> [key=value ...]`. It prints the JSON
response and exits 0 on `ok: true`, 1 on `ok: false` or when the app is not
running, 2 on usage errors. `machud --launch` starts the app if needed.
Any command that takes no `key=value` can be given a bare flag (`clear` → `clear=1`).

Coordinates in responses are Cocoa screen points (origin bottom-left of the main
display). Region geometry in `layouts` is fractions of the screen's visible area,
`x`/`y` from the top-left.

## Discovery

| Command | Args | Returns |
| --- | --- | --- |
| `help` | | `commands`: every command the running app accepts |
| `ping` | | `pid` |
| `layouts` | | `active` layout name, `layouts[]` with `regions[] {id, name, x, y, w, h}`; each carries `hidden` (true: kept for one loadout, not offered to snap into) |
| `loadouts` | | `loadouts[]` (full `Loadout` objects: `name`, `layout`, `slots[] {regionID, occupant}`, `hotkey`, `screens?`, `hud?` — see HUD loadouts) |
| `windows` | | `windows[] {window, pid, bundleID, app, title, x, y, w, h}` for every on-screen user window; windows MacHUD opened also carry `panel`, `web` or `browser` + `host` |
| `status` | `screen=<ref>` (optional) | `layout`, `activeLoadout`, `regions[] {region, name, x, y, w, h, screen, space, occupant?, window?, iou, fits}` — what sits in each region now, plus `redirected[]` when the last apply had to stand in for a missing display |
| `screens` | | `screens[] {index, name, persistentID, main, builtin, x, y, w, h, spaces, currentSpace}`; `persistentID` (`<vendor>-<model>-<serial>`, hex) is what loadouts pin displays to |
| `spaces` | `screen=<ref>` (optional) | desktop count, current desktop, which Mission Control shortcuts are enabled, `privateAPI` |
| `panels` | | `panels[] {id, title, visible}` — MacHUD's own windows (`web:<url>`), `menubar` and `tooldock`, then sibling apps' panels with `app`, `panel` (the app's own id), `health`, `cooperative`, `mode`, `badge`/`status` when the app reports them, and `frames[] {x, y, w, h}` (its on-screen windows on any layer, largest first, parked ones included). External ids are `<app bundle id>/<panel id>` |
| `apps` | | MacHUD-aware apps found by manifest: `apps[] {id, name, bundle, socket, health, running, reachable, autoLaunch, launchAttempts, panels[], lastError?, duplicates?}`, plus `known[]` (announced bundles), `failures[]` for unreadable manifests and `duplicates {id: [bundle]}` for ids declared by several bundles. `health` is `running` (subscribed), `socketUnreachable`, `launching`, `notRunning` or `notInstalled` |
| `menu` | | radial wheel description: `wedges[] {index, title, digit, angleStart/Center/End, kind, rings[]}` (the ring labels inside out), `rings` (radii), `visible`, current `selection`. A loadout wedge's rings are Preview / Apply / Clear this screen + Apply (P over a loadout wedge previews it too); the capture wedge's are Capture this screen / Capture all screens / Draw a new layout; the park wedge has two: Park front window / Restore parked |

## Layouts and loadouts

| Command | Args | Effect |
| --- | --- | --- |
| `select-layout` | `name` | make a layout the active one (used for Shift-drag snapping and `status`) |
| `edit` | | open the visual layout editor (a drag never opens it; with no layout, Shift-drag offers it in a toast) |
| `reload` | | re-read `~/.config/machud/layouts.json` |
| `apply` | `loadout`, `clear=1`, `screen=<ref>` (optional) | launch/find each occupant and place it in its region; with `clear`, first minimise the other windows showing on each screen the loadout covers (on the desktops it visits); then the loadout's `hud` part, if any (see HUD loadouts). `screen` picks the display for the one-screen form (default: under the mouse). Returns `placed[]`, `failed{}`, `cleared`, `redirected[]` when a display was missing, `hud {dock?, apps {id: "applied" or why not}}`, and `slots[]`: the plan step per slot plus `result` (`placed`/`failed`), `error`, and `actual` {x, y, w, h} when the app kept a different frame. See [Placement plan](#placement-plan) |
| `apply` | `loadout`, `plan=1` (+ optional `screen`) | **dry run**: `plan[]` of `{slot, region, occupant, action, from?, to, reason, window?}` without moving anything, plus `policy`, `failed{}` / `redirected[]` for missing displays and layouts |
| `preview` | `loadout` (default: the active one), `action=show\|apply\|cancel` | draw the plan over every display (regions coloured by action, Apply / Cancel); `apply` / `cancel` answer it. Returns `visible`, `loadout` |
| `capture` | `name`, optional `screen=<ref>` | **derive a layout from the windows on that screen** (one region per window at the window's exact frame, stacked windows included) and a loadout of the same name that fills it; both are saved and the layout becomes active. Regions of an existing layout with that name are reused where they still match, so editor tweaks survive a recapture. Returns `layout`, `regions`, `slots`, `screen`, `loadout` |
| `capture` | `name`, `layout=<name>` (+ optional `screen`) | fill only: snapshot which window sits in each region of an existing layout, without touching its regions |
| `capture` | `name`, `screens=all`, optional `desktops=…` | **derive a layout per display** (and per desktop) from the windows on it: one `ScreenAssignment` per attached display, each with its own layout named `<name> · <display>` (`· Desktop N` when desktops are walked), on that display's current desktop. `desktops=1,3` walks those desktops on every display, `desktops=main:1,2;builtin:1` per display; the desktop that was showing is restored afterwards. A window seen on several desktops (an "all desktops" app) is captured once, on the first desktop it was seen on. Returns `layout`, `regions`, `slots`, `screens[] {screen, layout, regions, slots, space?}`, `loadout` |
| `capture` | `name`, `desktops=…` (+ optional `screen`) | the same walk on one display |
| `capture` | `name`, `screens=<layout>@<ref>,<layout>@<ref>` | fill only, one existing layout per display |
| `capture` | `name`, `hud=only` | **the HUD only**: the tool dock's position and every running sibling's panels into the loadout `name` (created with no layout or slots if it does not exist; an existing one keeps its windows). Returns `loadout` |
| `capture` | any of the above plus `hud=1` | the windows as above, then the HUD added to the same loadout; the reply also carries `hud`. Re-capturing windows without `hud=` keeps a loadout's existing `hud` |
| `spaces` | `action=switch`, `n=<desktop>`, `screen=<ref>` (optional) | switch that display to desktop `n` via the Mission Control shortcuts |
| `clear` | | minimise every user window **on every desktop** except MacHUD's own, running sibling apps' (external panels) and hidden apps' |
| `restore` | | un-minimise everything the last `clear` (or `apply … clear=1`) minimised; returns `restored` |
| `place` | `window` (CGWindow number from `windows`), `region` (region id, name, or index) | move one window into one region |
| `radial` | `action=show\|hide\|cancel\|select\|commit`, `index`, `ring=inner\|middle\|outer` | drive the loadout wheel without the hotkey; a ring a wedge does not have selects its last one |

Screen references (`<ref>` above and `screen` in loadouts): a display name
(`"DELL S2722QC"`), `main`, `builtin`, or an index into the display list. In
loadouts a display can also be pinned: `{"display": "10ac-a0b4-4c4a3134", "name":
"DELL S2722QC"}` matches the physical display by `persistentID` (see `screens`),
then by exact name, but never a different panel of the same model. Captures write
this form for external displays, and existing `{"name": …}` references are pinned
automatically (on load and whenever displays change) for displays that are
attached and unambiguous; `main`, `builtin` and `index` stay roles.

When the set of attached displays changes (debounced 1 s; resolution and
arrangement changes do not count), the active loadout is re-applied without
`clear`.

Multi-screen loadouts carry `screens[]` instead of (or as well as) the single
`layout` + `slots` pair, and any slot may name a desktop:

```json
{"name": "Studio", "layout": "Thirds", "slots": [], "whenScreenMissing": "desktop",
 "screens": [
   {"screen": {"main": true},    "layout": "Thirds", "slots": [{"regionID": "…", "space": 2, "occupant": {…}}]},
   {"screen": {"name": "DELL S2722QC"}, "layout": "Thirds · DELL S2722QC", "space": 3,
    "fallback": {"screen": {"builtin": true}, "space": 1}, "slots": [{"regionID": "…", "occupant": {…}}]},
   {"screen": {"builtin": true}, "layout": "Full",   "slots": [{"regionID": "…", "occupant": {…}}]}
 ]}
```

An assignment's `space` is the desktop the whole assignment belongs to (what a
capture that walked the desktops writes); a slot's own `space` wins over it.

## Missing displays

An assignment whose display is not attached is not lost. `whenScreenMissing`
(on the loadout, default `desktop`) decides:

- `desktop` — it is redirected to its own `fallback` if it has one, otherwise to
  the main display, on the lowest desktop no attached assignment is using
  (allocated in assignment order). Fraction rects scale to the new display on
  their own. If that display has too few desktops the assignment fails with
  `needsDesktops: <n>` ("add N desktops in Mission Control, or set a fallback").
- `skip` — the assignment is left out and reported as `screenMissing`.

`apply` (and `status` after it) reports what happened in `redirected[]`:

```json
{"redirected": [{"screen": "DELL S2722QC", "toScreen": "Built-in Retina Display",
                 "toSpace": 2, "reason": "redirected"}]}
```

`reason` is `redirected`, `screenMissing` or `needsDesktops` (which also carries
`needsDesktops`). The two failing kinds also appear in `failed` under
`screen:<ref>`. The apply toast shows the same lines.

Desktop switching drives the Mission Control shortcuts ("Switch to Desktop N",
else "Move left/right a space"); if both are disabled the slot fails with
`spacesShortcutDisabled`. An existing window on a desktop that is not showing is
handled by `spaces.policy` (next section).

## Placement plan

Every apply first decides each slot (the same decisions `apply … plan=1` returns
and the preview draws). `action` is one of:

| action | meaning |
| --- | --- |
| `stay` | the window is already in its region |
| `resize` | same display and desktop: moved/resized in place (or restored from the Dock) |
| `move` | on another display's showing desktop: moved across |
| `switchSpace` | a desktop is switched first: the slot's own `space`, or (`bring`) the desktop the window is on |
| `launch` | no usable window: launch the app, ask it for a window, or (`launchNew`) open a second one |
| `leave` | left on its desktop (`spaces.policy: "leave"`) |
| `cannot` | not placeable; `reason` says why (not installed, single-window app on another desktop, …) |

`from` / `to` are `{screen, space, frame {x, y, w, h}}`; `space` is the 1-based
desktop on that display. The window used is the one on the target display's
showing desktop, else on the slot's desktop, else on another display, else a
minimised one, else one on a hidden desktop.

`spaces.policy` in layouts.json decides what happens to a window on a desktop that
is not showing:

- `bring` (default): show its desktop, move the window to the target display (it
  joins that display's showing desktop), switch back. When it is on the target
  display itself it is parked on another display while that one switches back.
  With a single display macOS 26 offers no way across, so it falls back to
  `launchNew`.
- `launchNew`: leave it, and open a new window here without activating the app:
  browsers by Apple event, apps with a plain ⌘N menu item through that item.
  Single-window apps (Messages, Signal, Beeper, Slack, Discord, …) report `cannot`.
- `leave`: report `leave`.

The apply toast lists every move, desktop switch and launch with its reason, every
failure, and windows that kept their own size. `docs/PLACEMENT.md` has the full
decision table.

Occupant JSON (inside `slots[].occupant`):

```json
{"kind": "app",   "bundleID": "com.apple.Safari", "titleMatch": "GitHub"}   // titleMatch optional regex
{"kind": "web",   "url": "https://example.com", "host": "chromeApp"}       // or "arc", "safari", "builtin"
{"kind": "panel", "id": "tooldock"}                                         // the tool dock: moves to the position nearest the region
{"kind": "panel", "id": "xyz.viawormhole.wormhole/portal"}                  // a sibling app's panel; "portal" alone works when unambiguous
```

A sibling app's panel is launched if needed, then placed with `panel frame` over
its socket when the app is reachable and its manifest allows `frame`; otherwise
its window is moved by Accessibility (found by the panel's title, else the app's
main window).

## Panels

| Command | Args | Effect |
| --- | --- | --- |
| `panel` | `id`, `action=show\|hide\|toggle\|frame\|mode` (or the bare verb: `panel show id=tooldock`); `frame` takes `x y w h`, `mode` takes `mode=compact\|full\|parked` plus optional `edge=left\|right\|top\|bottom` and `peek=` | show/hide/place a panel, MacHUD's own or a sibling app's (forwarded to its socket, launching the app first if needed). Returns `visible`, `mode`; for a sibling these are the last reported state, and the change arrives as a `state` event. No action toggles. `mode parked` hands MacHUD's own panels to the parking controller (orb and hover reveal, id `panel:<id>`; nearest edge unless `edge=`); `full`/`compact` bring them back (they have no compact form). A sibling's panel is tracked the same way when its window can be found through Accessibility, otherwise the app parks itself |

ffmpeg and ImageMagick presets and the dev servers list are the sibling apps ffmpegHUD,
magickHUD and serversHUD, not MacHUD panels.

## Menu bar

Hidden Bar-style menu bar management, off until `menuBar.enabled`. MacHUD adds a
separator (│) and an expander (chevron) status item; the user ⌘-drags the items to
hide to the left of the separator. Collapsing stretches the separator to 10 000 pt
so everything left of it is pushed off the menu bar; expanding shrinks it back.

| Command | Args | Effect |
| --- | --- | --- |
| `menubar` | `state` (default) \| `collapse` \| `expand` \| `toggle` \| `peek` \| `enable` \| `disable` (bare verb or `action=`); `peek` takes `seconds=` (default 3) | returns `enabled`, `mode` (`expanded`, `collapsed`, `peeking`), `itemsVisible`, `autoCollapseSeconds`, `autoCollapseIn` (while a countdown runs), `menuOpen`, `hotkey`, `installed`, and when enabled `separatorLeftOfExpander` and `items {separator, expander: {length, visible, frame}}`. Commands other than `state`/`enable` fail with `menu bar management is off` while disabled. `collapse` fails when the separator sits right of the expander (it would hide the expander too) |

Behaviour: hovering the expander for 150 ms peeks; while peeking, the items stay
until the mouse has been outside the menu bar for 600 ms (and at least `seconds`
for a socket `peek`). A click on the expander or the hotkey turns a peek into an
expand, and toggles otherwise; right-click opens the options menu. When expanded
with `autoCollapseSeconds > 0` it collapses after that many seconds with the mouse
outside the menu bar. Nothing collapses on its own while a menu is open (any
pop-up-menu-level window hanging from the top of a screen, found with
`CGWindowListCopyWindowInfo`, which needs no Screen Recording permission).

### Menu bar consolidation

While MacHUD runs, the sibling apps hide their own status items and MacHUD's menu hosts
theirs (on by default; `menuBar.consumeSiblings: false` turns it off, independent of
`menuBar.enabled`). MacHUD's status menu ends with an **Apps** section: a submenu per
discovered app (● running, ○ not) with "Show <App>" (the tool dock's summon), the app's own
status menu fetched live over its socket (`menu`, cached 3 s, prefetched when MacHUD's menu
opens and filled in place if the reply lands while it is open; the app's own Quit item is
dropped), Hide/Park/Reveal, "<App> Settings…", and "Quit <App>" or "Launch <App>". Choosing
one of the app's items sends `menu-invoke id= title=` to it.

How the siblings know: MacHUD writes `~/Library/Application Support/MacHUD/host.json`
(`{pid, bundleID, hostsMenus, updatedAt}`, HUDKit's `HUDMenuHost`) at launch and every 60 s,
rewrites it when `menuBar.consumeSiblings` changes (`hostsMenus: false` brings the icons
back), and removes it on quit. Each sibling's `HUDStatusItemPolicy` watches that file and
the pid, so a crashed MacHUD gives the icons back within 5 s. An app can opt out with its
own `menuBar.consumed` setting (see HUDKit's CONVENTIONS "Menu bar consolidation"); its
`hello` reports `statusItem {visible, consumed, host}`.

| Command | Args | Effect |
| --- | --- | --- |
| `menu-host` | | `consumeSiblings`, `file` (the host.json path), `hostsMenus`, `published` |
| `apps menu` | `id=<bundle id or name>` | the app's status menu, fetched now: `items[] {id, title, kind, enabled, state, keyEquivalent?, modifiers?, items?}` |
| `apps menu-invoke` | `id=`, `item=<menu item id>`, `title=` (optional guard) | performs the item in the app; returns `item`, `title` |

As a panel: `menubar` appears in `panels`/`state`; `panel mode compact id=menubar`
collapses, `full` expands (`parked` and `frame` are unsupported); `panel show/hide`
enables/disables management. In a loadout, a `{"kind": "panel", "id": "menubar"}`
slot expands the menu bar, or collapses it when the slot is `"mode": "parked"`.

## MacHUD contract

MacHUD also serves the HUDKit contract every MacHUD-aware app implements (see HUDKit's README):

| Command | Args | Returns |
| --- | --- | --- |
| `hello` | | `hudkit` version, `app`, `name`, `panels[] {id, title, symbol, ...}`, `verbs` |
| `state` | | `panels[] {id, visible, mode, badge?, status?}`, sibling panels included |
| `subscribe` | `events=state` (optional) | keeps the connection open and pushes `{"event": "state", "panels": [...]}` lines whenever a panel changes: through the socket, a hotkey, the menu, its close button, or a sibling app's own push |
| `settings` | `get [key=]` / `set k=v ...` / `schema` | MacHUD's own settings: `enabled` (bool), `trigger` (shift/option/control/command/always), `gap` (int), `browser` (bundle id, empty = default), `orbsHidden` (bool), `menuBar.enabled` (bool), `menuBar.autoCollapseSeconds` (int, 0 = never), `menuBar.consumeSiblings` (bool, default true). `set` validates every value first; `schema` returns the `HUDSettingsSchema` the settings window renders |
| `action` | `name=` | no app-specific actions yet |


| Command | Args | Effect |
| --- | --- | --- |
| `permissions` | `request=1` (optional) | Accessibility and per-app Automation status (`granted`, `denied`, `notAsked`, `notRunning`). With `request=1`, shows the macOS prompts for anything missing: System Events is launched to ask; Arc and Safari are asked only when running |

Automation entries appear in System Settings › Privacy & Security › Automation
only after macOS has prompted for that target, so run `machud permissions
request=1` (or the menu bar's Permissions › Request Missing Permissions…) once.

## Sibling apps

MacHUD finds MacHUD-aware apps by their `Contents/Resources/machud.json` in
`/Applications`, `~/Applications` (and one level of subfolders) and
`apps.searchPaths`, plus every bundle in `apps.known` (announced ones), subscribes to
each running one's `state`, and registers its panels. It skips its own manifest.

**New builds appear by themselves.** A bundle is announced with `apps announce` by
HUDKit's `hud-build.sh` right after a build and by the app itself when it launches (HUDKit's
`HUDSocketServer`, off with `HUD_NO_ANNOUNCE=1`), so its tool dock button appears at once,
before it is ever launched. MacHUD also watches `/Applications`, `~/Applications`, every
`apps.searchPaths` directory (for a glob, the directory above its first wildcard) and the
folders holding known bundles, and rescans 1 s after an `.app` appears, goes or is replaced.

**Duplicate ids** (an installed copy and a dev build declaring the same id): the bundle of
the running instance wins, else the most recently modified one (newest of the bundle,
its `Info.plist` and `machud.json`), else the first found. `apps` reports every bundle in
`duplicates {id: [bundle, ...]}` (the one in use first) and on the app as `duplicates[]`.

| Command | Args | Effect |
| --- | --- | --- |
| `apps` | | list (see Discovery) |
| `apps rescan` | | scan again (new builds, changed `apps` config); returns `apps[]` (and `duplicates`). Known bundles that are gone are dropped from `apps.known` (logged, not an error) |
| `apps announce` | `path=<.app>` | register the bundle now, even outside the search paths, and remember it in `apps.known` (deduplicated). It must have `Contents/Resources/machud.json`, else `ok: false`. Returns `id`, `changed` (false when already known and in use: an app's launch announcement is usually a no-op), `bundle` (the bundle in use for that id), `active` (whether it is this one) and `duplicates` when several bundles declare the id. A change pushes a `state` event and rebuilds the tool dock. Announcing MacHUD itself returns `ignored` |
| `apps forget` | `path=<.app>` | drop the bundle from `apps.known` and rescan (it stays only if a search directory finds it); returns `forgotten` and `apps[]` |
| `apps launch` | `id=<bundle id or name>` | launch without activating; resets the relaunch attempt count. `placement`: `pending` (it was started and gets its `apps.<id>.placement` once listening), `none` (no placement configured) or `running` (already up, left where it is) |
| `apps place` | `id=<bundle id or name>` | apply the app's configured placement now |
| `apps quit` | `id=<bundle id or name>` | `quit` over the app's socket, else a terminate event; returns `wasRunning`. An app quit this way is not relaunched |
| `apps menu` / `apps menu-invoke` | `id=`, `item=` | the app's own status menu and performing one of its items (see Menu bar consolidation) |

Supervision: launches are on demand (`panel show`, a loadout slot) or at startup
for `apps.autoLaunch`. An `autoLaunch` app that exits unexpectedly is relaunched
after 2 s, then 4 s, and given up on after 3 launches (`lastError: "gave up …"`);
60 s of uptime resets the count. A lost subscription while the process lives is
retried with backoff (0.5 s doubling to 8 s). Commands for an app whose socket is
not up yet are queued for 20 s.

Default placement: `apps.<bundle id>.placement` in layouts.json says where MacHUD puts an
app's panel when *it* launches the app (`apps launch`, `autoLaunch`, the menu's Launch):

```json
"apps": {"xyz.machud.sift": {"placement": {"region": "left", "layout": "Halves"}},
         "JER.wormhole": {"placement": {"mode": "parked", "edge": "right", "peek": 12}}}
```

`region` (id or name in `layout`, default the active layout) places it there; without a
region it is parked at `edge` (default left) from the panel's `defaultSize` against that
edge. `"mode": "parked"` with a region parks it from the region. `panel` picks one of the
app's panels (default its first). Loadouts ignore it. `apps` reports `placement` and
`placementResult` (`pending`, `applied` or the error).

Parking: a parked loadout slot (and `park id=<region>`) whose occupant is a sibling panel
that is listening parks over the app's socket: MacHUD sends `panel frame` with the rest
frame, then `panel mode parked edge= peek=`; the orb (and `park reveal`) sends
`panel mode full`. A stopped sibling is launched and placed first, then parked. Parkings of
an app that quits are dropped with their orb.

## Agent sessions

A discovered app may declare HUDKit's `agent-sessions` capability on a panel (mechaclaude's
MechaHUD dashboard does): it shows agent sessions and answers `action open-session id=` and a
`sessions` command on its own socket (`../hudkit/docs/CONTRACT.md` § Agent sessions). MacHUD
brokers the capability so a client can ask "who shows agent sessions" instead of naming an app.

| Command | Args | Effect |
| --- | --- | --- |
| `sessions` / `sessions providers` | | every discovered app with a panel declaring `agent-sessions`: `providers[] {app, socket, running}` |
| `sessions open` | `id=<sessionKey>` | forwards `action open-session id=` to the first provider already running, else one whose process is starting, else the first discovered (launching it, as `apps launch` does); returns `{app}` (the bundle id it reached), or the provider's own `ok: false` reply, or `{"error": "No app shows agent sessions"}` when none is discovered |

`sessionKey` is opaque to MacHUD; the provider defines it (mechaclaude's is `claude:<sessionId>`).

## App catalog and installs

MacHUD reads the app catalog (`catalog.json`, published at
<https://jamesrisberg.github.io/machud/catalog.json>; format in `site/README.md`), caches it at
`~/.config/machud/state/catalog.json` (so it is there offline and at launch) and fetches it
again when it is older than `catalog.refreshHours` (6) — checked hourly and whenever the
settings window opens — or on `catalog refresh`. Each entry is compared with what is
installed: the discovered app with that bundle id (else name), or `<Name>.app` in an install
directory, and its `CFBundleShortVersionString`.

| Command | Args | Effect |
| --- | --- | --- |
| `catalog` / `catalog list` | | `catalog {url, cache, fetchedAt, updatedAt, count, refreshing, error?}`, `apps[]` (each catalog entry plus `state`: `notInstalled`, `installed`, `updateAvailable` or `newerInstalled`, `running`, and `installed {path, version, bundleID}`), and `machud {version, available, updateAvailable, page}` for MacHUD's own entry |
| `catalog refresh` | | fetch now; answers when done, as `list` (`ok: false` with `error` when the fetch failed; the cached catalog stays) |
| `apps install` | `id=<catalog id, name or repo name>` (or a bare word: `machud apps install sift`), `launch=1` | download, verify and install (below); answers when done with `path`, `version` and the app's catalog row. Installed already: `result: "already installed"` (or an update when the catalog is newer) |
| `apps update` | `id=` | install the catalog's newer version over the installed copy; a running copy is quit first and started again after. `result: "up to date"` when there is nothing newer |
| `apps uninstall` | `id=` | quit the installed copy, move it to the Trash, rescan; returns `trashed`. Only bundles in `/Applications`, `~/Applications` or `catalog.installDir` are removed, never a dev build |

Installing: the zip is downloaded to a temp directory; its size and SHA-256 must match the
catalog; `ditto -x -k` unpacks it; the one `.app` inside must carry the catalog's bundle id;
`spctl -a -vv -t install` must accept it (Developer ID, notarized); then it is copied into
`catalog.installDir`, else `/Applications` when writable, else `~/Applications`. An existing
copy there (or the installed copy being updated) is quit over its socket (waiting up to 10 s)
and moved to the Trash before the new one takes its place. Then `apps rescan`, and the app is
launched when asked (or when it was running before an update). Each failure answers
`ok: false` with the reason, e.g. `Gatekeeper rejected Scratch.app (not notarized?): rejected;
origin=Apple Development: …` or `sha256 mismatch: …`, and installs nothing. MacHUD never
installs its own entry: a newer MacHUD shows a note with a Download button (its release page).

The settings window's **Apps** tab (`settings-window show tab=apps`; the menu's **Get Apps…**)
lists the catalog with icon, summary, kind, installed vs available version and
Install / Update / Remove / Open with progress, "Install bundled tools" (every `bundled`
entry not installed yet) and "Install selected". The onboarding's Apps step shows the same
catalog with the bundled tools selected (see Onboarding).

## Tool dock

MacHUD's dock: a Dock-like strip (Liquid Glass on macOS 26, a behind-window blur
before it; 18 pt corners, hairline border) with one button per discovered sibling app,
showing its real icon and a running dot. **One list**: hover apps first, then windowed
apps (`HUDManifest.dockSorted`: by the manifest's `order` within each group, apps
without one after, then by name), with a thin divider between the groups; a Parked
Windows button ends the hover group while orbs are hidden and something is parked. An
app with several panels gets one button (grouped by its first panel in that order)
whose click opens a menu of them.

**Positions** (`toolDock.position`, one of `HUDDockPosition`'s eight): `bottom`, `top`,
`left`, `right` are a single row or column centred on that edge; `topLeft`, `topRight`,
`bottomLeft`, `bottomRight` are an L (`HUDDockLayout.lShape`) with the **hover group on
the vertical arm** (its first button in the corner) and the **windowed group on the
horizontal arm**, the divider next to the corner. With one group empty the L is just
that group's arm. Dragging the dock by its background snaps to
`HUDDockPosition.nearest` the pointer. The dock stays clear of the menu bar and the
system Dock, and shrinks its icons if an arm would not fit.

- **`kind: hover`** buttons: resting on the button **60 ms** sends `panel frame` (placed
  with `HUDDockLayout.panelFrame` against the button's arm, the panel's last size or its
  manifest `defaultSize`) then `panel show from=<edge> anchor=<button> reason=hover`, so
  the app can slide it out of the dock; the app is launched if needed. While it shows,
  the pointer may be anywhere in the dock bar, the panel (the frame the app reports in
  `state`, else the one MacHUD gave it) or the rectangle between them; outside that for
  **120 ms** sends `panel hide to=<edge> reason=hover` (the app fades it quickly).
  Reaching another hover button switches at once: the new app's `panel show` goes out
  first and the old app's `panel hide` as soon as the new one has taken it (at most
  150 ms later), so they cross-fade. A click pins a panel open; clicking again hides it.
- **`kind: windowed`** buttons: a click summons the panel (`reason=click`, `from=`/
  `anchor=` of its button) at the frame it had when last dismissed, or dismisses it
  (remembering that frame in `state/tooldock.json`). A parked panel is unparked instead.
- **File drops**: buttons of apps whose panel declares `acceptsFileDrop` take file
  drags: the button highlights, resting 400 ms opens the panel (spring-loading), and
  the drop sends `action drop paths=<HUDDrop.encode>` (plus `id=<panel>` for a
  several-panel app), launching the app first if needed. Other buttons show the "not
  allowed" cursor.
- Right-click: Show, Hide, Park at Edge ▸, Place in Region ▸ (active layout, on the
  dock's display), Quit/Launch, Settings…, then Position on Screen ▸ (eight positions),
  Auto-hide, Magnification. The status menu has the same options under **Tool Dock**;
  ⌃⌥D (`hotkeys.dock`) shows and hides the dock.
- **Dock registry**: on every move the dock publishes its arms to `HUDDockRegistry`
  (`~/Library/Application Support/MacHUD/docks.json`, key: MacHUD's bundle id) so
  sibling strips such as Sift's dock mode can sit next to it, and removes itself when
  turned off. `MACHUD_DOCKS_FILE` overrides the file; an isolated instance
  (`MACHUD_CONFIG` set) uses `docks.json` beside its config. The dock watches the file
  but does not move for others; `tooldock state` reports them as `neighbors`.

| Command | Args | Effect |
| --- | --- | --- |
| `tooldock` | `state` (default) \| `show` \| `hide` \| `toggle` (bare verb or `action=`) | show/hide set `toolDock.enabled`. Returns `enabled`, `position`, `autoHide`, `iconSize`, `magnify`, `visible`, `tucked` (auto-hidden right now), `frame`, `segments[]` (the arms), `dividers[]`, `screenName`, `buttons[] {id, title, group (hover/windowed), kind (hover/windowed/menu), acceptsDrop, panels[], indicator (none/running/visible), frame, edge, label? (windowed and menu buttons: the name shown beside the dock while the pointer rests on it), revealed?, pinned?, panelFrame?}`, `neighbors {app id: {position, frames[]}}`, `remembered {panel id: frame}`, `dragging` (the dock is being dragged), `labelShown` (the button whose label is on screen) and `pointer` while overridden |
| `tooldock position` | `position=<one of the eight>` (`top-left` and `topleft` work too) or `edge=bottom\|left\|right\|top`, `screen=<display name>` (empty: the main display), `iconSize=24…96` | move/resize the dock and persist it. `offset=` is gone (the dock is centred) and is refused |
| `tooldock autohide` / `magnify` | `value=on\|off` (default: flip) | |
| `tooldock click` | `id=<button id, app name or title>` | what clicking the button does |
| `tooldock drop` | `id=`, `paths=<HUDDrop.encode>` (or comma-separated plain paths) | what dropping those files on the button does; fails for a button that takes no files |
| `tooldock pointer` | `x= y=` (Cocoa screen points) or `clear=1` | the hover logic takes the pointer to be there instead of the mouse, for scripted checks |
| `tooldock mouse` | `phase=move\|down\|drag\|up x= y=` (Cocoa screen points) | as `pointer`, and sends the strip a synthesized event there: `move` enters/leaves tiles, `down`/`drag`/`up` press, drag and release through the dock window (a press that moves more than 4 pt drags the dock and is not a click), for scripted checks |
| `tooldock snapshot` | `path=<png>` | writes the strip as a PNG at the screen's scale (`HUDDockStripView.snapshot`: the glass as a dark stand-in, no Screen Recording needed); returns `path` |
| `summon` | `id=<panel id, short id, app bundle id or name>` | show the panel where it was last dismissed, sending `panel frame` then `panel show from= anchor= reason=summon` (a hover panel instead opens next to its button, pinned, exactly like a hover: `reason=hover`); returns `frame` sent, `remembered` |
| `dismiss` | `id=` as above | hide it, remembering its frame (`panel hide to= anchor= reason=summon`; a hover panel closes as on leaving it, `reason=hover`); an app that is not running is left alone (never launched to be hidden) |

As a panel: `tooldock` appears in `panels`; `panel show/hide id=tooldock` turns it on
and off; `panel frame id=tooldock` and a loadout slot `{"kind": "panel", "id":
"tooldock"}` move it to the position nearest the rect's centre. `panel mode parked` is
refused (use auto-hide).

While the tool dock is on, parking orbs are hidden unless `orb show` (or the
setting) says otherwise.

## HUD loadouts

A loadout can also hold the MacHUD side of the desktop in `hud`; a loadout may hold
only that (`"layout": ""`, `"slots": []`):

```json
{"name": "Desk", "layout": "", "slots": [],
 "hud": {"dock": {"position": "bottomLeft"},
         "apps": {"xyz.machud.sift": {"panels": {"browser": {"visible": true, "mode": "full",
                                                          "frame": {"x": 0, "y": 80, "w": 900, "h": 975},
                                                          "settings": {"dock.edge": "left"}}}},
                  "xyz.machud.servershud": {"panels": {"servers": {"visible": false, "mode": "full"}}}}}}
```

- **Capture** (`capture name= hud=only|1`, or the status menu's **Save Current HUD as
  Loadout…**) records the tool dock's position and, for every running (reachable)
  sibling, each panel's `visible` and `mode` from its state, its `frame` (the one the
  app reports in a fresh `state`, else its window's while showing) and, for apps that
  have a `dock.position` or `dock.edge` setting, that setting (on the app's first panel).
- **Apply** (after the loadout's windows, if any) moves the tool dock, then per app:
  launches it if it is not running, then sends `settings set`, `panel mode`, `panel frame`
  (not for a parked panel) and `panel show`/`hide` (`reason=summon`), in that order;
  commands wait for the app to listen. An app that is not installed is reported, not fatal.
- **At startup**: `startupLoadout` (layouts.json) names a loadout applied about 2 s after
  launch, as soon as every sibling it names that is already running is listening (at most
  8 s more; apps that are not running are launched by the apply). The Save dialog's "Put
  it back when MacHUD starts" and each loadout's **Apply at Startup** menu item set it.

## Settings window

| Command | Args | Effect |
| --- | --- | --- |
| `settings-window` | `show\|hide\|toggle\|state`, `tab=<bundle id, name, voice, brain or apps>`, `activate=0` | the shared settings window: a tab for MacHUD and each discovered app, plus Voice and Brain (see Voice; `state` reports them as `voice {status, settings?}`) and Apps (see App catalog; `state` reports it as `apps {rows[], selected[], selfUpdate?}`), rendering the app's settings schema (`settings schema` over its socket, else the file its manifest names) and reading/writing through `settings get/set` on its socket. Keys without a schema show as text rows. `show` answers once every tab has loaded with `tabs[] {id, title, status, schema, sections[{group?, rows[{key, title, control, value}]}]}`; `activate=0` shows it without taking focus |

The status menu's MacHUD section lists the discovered apps (● running, ○ not) with Show/Hide,
Park/Reveal, Launch/Quit and a Settings… item per app, plus Settings… for the window.

## Onboarding

On launch, until it has been finished or skipped, MacHUD shows its setup guide: an overlay on
the screen with the pointer that blurs the desktop behind it with a light tint (the desktop
stays visible), with the step content on glass cards. The **welcome** page is a checklist of
every section, each **to do**, **done** or **skipped**; clicking one goes there, and the same
checklist stays beside the card in every section, updating in place. The sections, in order:

- **permissions**: Accessibility and Microphone, live status, buttons that ask macOS or open
  System Settings. Done once both are granted.
- **voice**: on/off, fn key hold or tap mode with the gestures explained, the agent gesture,
  and a "try it" area that follows the voice host's `subscribe` stream and has a text box
  dictation pastes into.
- **brain**: the runtimes with what `brain status` detected (mclaude offers to install
  MechaHUD, which shows the same session); the workspace folder, the home folder unless one is
  chosen (Change…, Use Home); spoken replies on/off, the reply voice, **Test voice** (`action
  name=say`) and, for Kokoro, its download (`models action=status|download`); and why the brain
  is not up yet until it is. Done once the brain is ready.
- **apps**: the catalog with one-click installs, bundled tools preselected.
- **tooldock**: what the tool dock is, on/off and its position (a miniature display with the
  eight places), applied live through the dock and saved in layouts.json.
- **loadout**: Arrange windows… shrinks the overlay to a small floating card at the top of the
  screen; Capture saves the windows on that display as a loadout of the typed name (a hidden
  layout of the same name, one region per window, as the menu's capture does) and the card
  comes back showing its regions. Done once captured.
- **radial**: how the wheel works (hotkey `loadoutMenu`, ⌃⌥Space by default, and its rings),
  then practice: Try it on the desktop shrinks the overlay again, and applying the loadout just
  made (else the first loadout there is), by the wheel or any other way, while practising or on
  this step completes it and brings the overlay back.
- **done**: what is still open, with links back.

Moving on from a section marks it: apps and the tool dock count as done, voice as done when it
is on; the others are left skipped, and still turn done by themselves when their condition comes
true. **Skip for now** marks a section skipped. Return (or ⌘→) goes on, ⌘← back, Esc closes it
to finish later: it opens again at that step on the next launch, with the checklist as it was.
**Skip setup** on the welcome page and **Finish** on the last stop it from showing by itself.
The menu's **Setup Guide…** opens it at any time. The overlay is a normal-level window, so
System Settings and macOS's prompts come up over it. While it will show at launch, MacHUD does
not raise the Accessibility prompt at launch; the permissions step asks. Voice and brain
settings go through the voice host's socket (`settings get/set`, `brain action=status`), as the
Voice and Brain tabs do.

| Command | Args | Effect |
| --- | --- | --- |
| `onboarding` / `onboarding status` | | `visible`, `record` (`{status: inProgress\|completed\|skipped, step, updatedAt, sections {<section>: done\|skipped}, loadout}` or null), `steps[]`, `step`, `compact` (`arrange`, `practice` or null), `sections {<section>: todo\|done\|skipped}`, `permissions {accessibility, microphone}`, `voice {status, on, keyMode, phase, connected}`, `brain {ready, enabled, runtime, workspace, workspaceIsDefault, replies {speak, voice, kokoro?}, problem?, runtimes[]?, statusError?}`, `apps[] {id, state}`, `toolDock {enabled, position, screen}`, `loadout {name, screen, regions[]}` or null, `radial {hotkey, target, applied?}` |
| `onboarding show` | `step=welcome\|permissions\|voice\|brain\|apps\|tooldock\|loadout\|radial\|done` | shows it at `step`, else where it was left (the start once finished or skipped) |
| `onboarding hide` | | closes it to finish later |
| `onboarding next` / `back` | | moves while it is showing; `next` marks the section as the button does (on the welcome page it goes to the first section not done, on the last step it finishes) |
| `onboarding skip` | | closes it and stops it showing at launch |
| `onboarding reset` | | closes it and forgets it: it shows again at the next launch |
| `onboarding snapshot` | `dir=<folder>` | writes every step as `onboarding-<n>-<step>.png` in `dir`, plus `onboarding-compact-arrange.png`, `onboarding-compact-practice.png` and `onboarding-tint-only.png` (the welcome page over the unblurred desktop), rendered offscreen (nothing appears on screen; the desktop blur is simulated); returns `files[]` |

## Voice

MacHUD runs its voice host, `Contents/Helpers/MacHUDVoice` (beside the `MacHUD` binary in a
`swift build`), as a child process: it is started at launch unless `enabled` is off in
`voice.json` (beside `layouts.json`, owned by the voice host), restarted after it exits (1, 2,
4, 8 and 16 s after quick exits in a row; a run of 20 s or more starts the count again; on the
6th quick exit it stays down, `failed`, until the menu's Restart Voice Host, the tabs' Retry or
Turn On Voice) and stopped when MacHUD quits. Its stdin is a pipe MacHUD holds
(`MACHUD_VOICE_PARENT_PIPE=1`), so it exits when MacHUD dies; to stop it MacHUD closes the pipe
and sends SIGTERM only if it is still running 2 s later. Its socket is `$MACHUD_VOICE_SOCKET`, else
`~/Library/Application Support/MacHUD/sockets/machud-voice.sock` (an isolated MacHUD uses its own,
see Running several instances).

`voice` forwards to that socket and returns the voice host's reply:

| Command | Args | Effect |
| --- | --- | --- |
| `voice state` | | `state {phase, inputLevel, partialTranscript, card?, hiddenForFullScreen, brainAvailable, brainProblem?, sessionKey?, sessionProvider?, wakeListening, muted, gesturePending}` |
| `voice hello` | | the voice host's `name` (`MacHUDVoice`), `version`, `pid` |
| `voice status` | | MacHUD's view of the process: `status` (`running`, `restarting`, `disabled`, `stopped`, `failed`, `notInstalled`), `pid` while running, `socket`, `connected`, `muted` once connected, `error` (why it gave up) when `failed` |
| `voice action` | `name=` `click`, `ask`, `dictate`, `stop`, `cancel`, `approve`, `deny`, `dismiss`, `mute`, `unmute`, `open-session`, `say`; `id=` for `approve`/`deny`; `text=` for `say` | performs it (`machud voice action mute` works too) |
| `voice brain status` | | the voice host's `brain status` (below): whether the brain can take a turn, why not, the workspace and the runtimes found |
| `voice models` | `status` (default) / `download id=kokoro` | the voice host's `models` (below): whether the Kokoro reply voice is installed or downloading, or start its download |
| `voice settings get` | | `settings`: the voice host's settings object |
| `voice settings set` | `settings=<JSON object>`, or dotted `key=value` pairs | `settings=` replaces the whole object. `key=value` pairs (`enabled=false`, `voice.speakReplies=true`, `brain.runtime=claude`) are applied to the current settings, each converted to the type already stored, and the whole object is sent back; an unknown key is an error. Turning `enabled` off stops the voice host; on starts it |
| `voice secret` | `set name=grok [value=…]` / `clear name=grok` | stores or removes the Grok API key in the Keychain; the key is never returned. Without `value=`, `machud voice secret set name=grok` reads the key from stdin (without echo at a terminal): prefer that, so the key stays out of the shell history and the process list |

When the voice host is not answering, `voice` replies `ok: false` with why (`status` as above).
The settings window's Voice tab (on/off, fn key mode, the agent gesture, wake word, phrase and
sensitivity, reply voice, spoken replies, Test Voice (`action say`), the Kokoro voice's
Download button and progress (`models`), Grok key) and Brain tab (why the brain cannot take a
turn, or Ready; on/off; runtime, listing mclaude once it is installed and marking runtimes not
found; the workspace folder, chosen with a folder picker, the home folder while none is chosen;
assistant name, port, per-runtime paths) edit the same settings through the same socket, and
say why while the voice host is down (Retry restarts a stopped or failed host; Turn On Voice
while voice is off). The status menu's Voice submenu has Mute/Unmute and Voice Settings…, with
Turn On Voice while voice is off and Restart Voice Host while it is stopped or failed.

### The voice host's socket (`machud-voice`)

HUDKit's JSON-lines socket, one request per connection, served by `MacHUDVoice` itself:

| Command | Args | Returns |
| --- | --- | --- |
| `hello` | | `name`, `version` (the enclosing MacHUD's), `pid` |
| `state` | | `state`: the host's state (below) |
| `subscribe` | `events=state,models` (optional) | keeps the connection open and pushes `{"event": "state", "state": {…}}` on every change (many times a second while listening) and `{"event": "models", "kokoro": {…}}` as a model's status changes (its download progress) |
| `settings` | `action=get` | `settings`: the whole settings object |
| `settings` | `action=set settings=<JSON object>` | replaces the whole object (decoded leniently: missing or invalid keys take their defaults), saves `voice.json`, applies it and returns the stored `settings` |
| `action` | `name=<click\|ask\|dictate\|stop\|cancel\|approve\|deny\|dismiss\|mute\|unmute>`, `id=` for `approve`/`deny` | performs it; returns `state` |
| `action` | `name=say text=<text>` | speaks `text` with the configured reply voice, whether or not `voice.speakReplies` is on (previews in settings and onboarding), replacing anything being said; `{ok, state}`, or `{ok: false, error}` without `text`, while a take is recording, or without a voice. Silent under `MACHUD_VOICE_NO_SPEECH=1` |
| `action` | `name=open-session` | asks MacHUD to show the brain's current session (`sessions open id=<sessionKey>` on MacHUD's control socket, `$MACHUD_SOCKET` else `/tmp/machud-<uid>.sock`); replies once MacHUD has, `{ok, app, state}`, or `{ok: false, error}` (also shown briefly under the orb) |
| `brain` | `action=status` (or `brain status`) | `{ok, available, problem?, workspace, workspaceDefault, runtime, runtimes[]}`: `workspace` is the folder the agent works in, the home folder while `brain.workspacePath` is empty (`workspaceDefault` true; the setting itself stays empty until the user chooses one); `runtime` is the one chosen; each of `codex`, `claude`, `hermes`, `mclaude` is `{id, name, installed, path?}`, plus `apiServer` (whether `~/.hermes/.env` turns Hermes' API server on) for hermes. Tools are looked up again on each call; mclaude's readiness (tmux and mechaclaude's other prerequisites) is MechaHUD's `sessions` reply (`canStart`/`problem`/`fix`), not this one |
| `models` | `action=status` (or `models status`) | `{ok, kokoro: {installed, downloading, progress, bytes, error?}}`: `progress` is 0…1 (1 once installed), `bytes` the whole download's size, `error` why the last download failed |
| `models` | `action=download id=kokoro` | starts downloading the Kokoro reply voice into `~/Library/Application Support/MacHUD/Voice/Models` (unless it is installed or already downloading) and returns the status; each file is checked against its pinned size and SHA-256 before it is installed. Progress arrives through `models status` and `models` events; the next reply uses Kokoro once it is installed |
| `secret` | `action=set name=grok value=…` / `action=clear name=grok` | writes the Keychain; never returns a value |
| `quit` | | exits after replying |

`state` is `{phase, inputLevel, partialTranscript, card?, hiddenForFullScreen, brainAvailable,
brainProblem?, sessionKey?, sessionProvider?, wakeListening, muted}`. `brainAvailable` is true
when the brain can take a turn; otherwise `brainProblem` says why, in words for the user: voice
or the brain is off, the brain companion's own reason (`Choose a workspace folder for the
agent.`, a missing Node.js), the chosen runtime's tool is not installed (`Codex is not
installed.`), or it is starting, connecting or restarting. A problem the user has to fix refuses
an agent take with that reason; starting, connecting and restarting do not. `sessionKey` is the
brain's current session when its runtime drives one other apps show too (mechaclaude's
`claude:<sessionId>`), and `sessionProvider` the app MacHUD opens it in, once MacHUD has named
one (`sessions providers`); the reply card then offers "Open in <app>". `phase` is `{"name": …}`, one of `idle`, `listening`, `transcribing`,
`working`, `awaitingApproval`, `speaking`, `failed`, plus `"mode": "dictation"|"agent"` for
`listening` and `transcribing` and `"message"` for `failed`. `card` is `{prompt, reply,
progress[], approval?: {id, summary, detail}}`. `gesturePending` is true from the fn press that
begins a take until the gesture is decided: the press outlasts a tap (dictation), the double-tap
window after a tap lapses (dictation, or a discarded tap in hold mode), a second press moves the
take to the agent, or the take ends. The orb shows its armed look meanwhile and commits to the
waveform or the agent's pulse once it is false. It is never true with the agent gesture off, or
for a take started by the orb, the wake word or the socket.

The host reads its environment: `MACHUD_VOICE_SOCKET` (its socket), `MACHUD_CONFIG` (the folder
of that path holds `voice.json`), `MACHUD_VOICE_PARENT_PIPE=1` (exit when stdin reaches end of
file), `MACHUD_NO_HOTKEYS` (no fn key tap), `MACHUD_VOICE_NO_MIC=1` (simulated capture, the
microphone is never opened), `MACHUD_VOICE_NO_BRAIN=1` (the brain never starts),
`MACHUD_VOICE_HEADLESS=1` (no orb on screen), `MACHUD_VOICE_NO_SPEECH=1` (replies and `say` make
no sound), `MACHUD_VOICE_MODELS_DIR` (where downloaded models are kept),
`MACHUD_VOICE_KEYCHAIN_SERVICE` (the Keychain service for secrets) and `MACHUD_SOCKET` (MacHUD's
control socket, for `open-session`).

## Lifecycle

| Command | Effect |
| --- | --- |
| `quit` | terminate the app |

## Files

- `~/.config/machud/layouts.json` — layouts, loadouts, hotkeys, trigger, grid, browser, apps, menuBar, toolDock, spaces. Hot-reloaded
  on save (atomic or in place).
  `spaces`: `{"policy": "bring"}` (or `launchNew`, `leave`): what apply does with a window on a desktop that is not
  showing (see Placement plan).
  `menuBar`: `{"enabled": false, "autoCollapseSeconds": 10, "hotkey": {"key": "b", "modifiers": ["control", "option"]}, "consumeSiblings": true}`,
  every key optional (these are the defaults). The hotkey can also be given as `hotkeys.menuBar`; `menuBar.hotkey`
  wins, and `{"key": ""}` turns it off. It is only registered while `enabled`.
  `apps`: `{"searchPaths": ["~/dev/*/build"], "autoLaunch": ["<bundle id>"], "standardDirectories": true, "known": ["<.app path>"]}` —
  extra directories to scan for MacHUD apps (`~` and globs expand), apps to keep running, whether to scan
  /Applications and ~/Applications at all, and the bundles announced with `apps announce` (MacHUD maintains it). Run `apps rescan` after changing it. Any other key is a
  bundle id with per-app settings: `{"placement": {...}}` (see Sibling apps).
  `browser` is a bundle id: a Chromium gets a `--app=` window, Arc and Safari get an ordinary
  browser window. Unset means the system default browser decides the host of new web occupants.
  `toolDock`: `{"enabled": true, "position": "bottom", "autoHide": false, "iconSize": 44,
  "magnify": true, "screen": "<display name>"}`, every key optional (these are the defaults; `screen`
  absent means the main display). An `edge` key is read as that edge's position (and `offset`
  ignored); neither is written.
  `startupLoadout`: the name of a loadout applied at launch (see HUD loadouts).
  `catalog`: `{"url": "https://jamesrisberg.github.io/machud/catalog.json", "installDir": null, "refreshHours": 6}`,
  every key optional (these are the defaults). `url` may be `file://` or a path; `installDir` replaces the
  /Applications-else-~/Applications choice and is also searched for apps (see App catalog).
  `hotkeys.dock` (default ⌃⌥D) shows and hides the tool dock.
- `~/.config/machud/voice.json` — the voice host's settings (see Voice). The voice host writes
  it; MacHUD reads only `enabled`, to decide whether to start it.
- `~/.config/machud/state/catalog.json` — the last catalog fetched; `state/onboarding.json` records the onboarding (`status`, `step`).
- `~/.config/machud/state/tooldock.json` — frames of panels dismissed from the tool dock (restored by summon).
- `~/Library/Application Support/MacHUD/docks.json` — where each dock strip sits (`HUDDockRegistry`);
  `MACHUD_DOCKS_FILE` overrides it.
- `~/Library/Application Support/MacHUD/host.json` — this MacHUD hosts the siblings' menus
  (`HUDMenuHost`, see Menu bar consolidation); removed on quit. `MACHUD_HOST_FILE` overrides it.

## Running several instances

Set `MACHUD_SOCKET`, `MACHUD_CONFIG` and `MACHUD_NO_HOTKEYS=1` to run an
isolated copy (used for tests) alongside the real one. An isolated copy does not
watch window drags (the real one already snaps them); `MACHUD_DRAG=1` turns its
drag snapping back on. Its tool dock publishes to
`docks.json` beside `MACHUD_CONFIG` (or `MACHUD_DOCKS_FILE`), not the shared file, and its
`host.json` there too (else `<MACHUD_SOCKET>.host.json`, or `MACHUD_HOST_FILE`), so it never hides
the real siblings' icons.
Its voice host listens on `$MACHUD_VOICE_SOCKET`, else `<MACHUD_SOCKET>-voice.sock` (else
`machud-voice.sock` beside `MACHUD_CONFIG`), never the real one's, and inherits the isolation
variables. MacHUD also starts it with `MACHUD_VOICE_NO_MIC=1`, `MACHUD_VOICE_NO_BRAIN=1`,
`MACHUD_VOICE_HEADLESS=1` and `MACHUD_VOICE_NO_SPEECH=1` (no microphone, no brain, no orb, no
sound) and `MACHUD_VOICE_MODELS_DIR=<voice socket without its extension>-models` (never the real
models folder) unless `MACHUD_VOICE_LIVE=1`, and
with `MACHUD_VOICE_KEYCHAIN_SERVICE=com.jrisberg.machud.voice.isolated` unless that variable is
already set, so a test instance never touches the real Grok key.

An isolated copy does not show the onboarding at launch unless `MACHUD_FIRST_RUN=1`, and its
onboarding never asks macOS for permissions or opens System Settings. To try installs,
give it a `catalog` with a `file://` `url` and a temporary `installDir`.
`MACHUD_INSTALL_SKIP_GATEKEEPER=1` skips the `spctl` check so a dev-signed zip installs:
**test-only**, never set it for normal use.
