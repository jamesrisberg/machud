# Changelog

MacHUD is the umbrella app of the MacHUD family: a menu bar window/layout manager that
also finds, supervises and hosts the sibling HUD apps. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Agent sessions
- MacHUD can find and open an agent session in whichever app shows it, without naming the app:
  `machud sessions providers` lists the discovered apps that show agent sessions (MechaHUD's
  dashboard is one), and `machud sessions open id=<session key>` opens and focuses one, launching
  the app if it is not running.

### Voice
- MacHUD runs its voice host as a helper inside the app and keeps it running: it starts with
  MacHUD, comes back after a crash, and stops when you turn voice off or quit MacHUD.
- A small orb sits under the camera housing (or hangs from the menu bar on a screen without
  one), always visible: it stretches into a waveform while you dictate, pulses while the agent
  is listening, shows a subtle motion while it is working, and grows a reply card underneath
  with the agent's answer and any approval it needs. Right-click it for Mute/Unmute and Dismiss;
  hover the resting orb to peek the last reply.
- Talk to it three ways: hold the fn key to dictate at the cursor, or tap the agent gesture while
  holding to send the words to the agent instead; click the orb, or say the wake phrase once it
  is turned on, to start a hands-free turn with the agent that listens until you stop talking or
  click again; the agent's reply is read aloud when spoken replies are on.
- Voice and Brain tabs in the settings window: voice on/off, fn key mode, the agent gesture,
  the wake word and its sensitivity, the reply voice, spoken replies and a Grok key kept in the
  Keychain; the brain's runtime, workspace, assistant name, port and tool paths.
- A Voice submenu in the menu bar menu: Mute/Unmute and Voice Settings…, and Restart Voice
  Host when it has stopped.
- `machud voice state|status|action|settings|secret` drives the voice host from the command
  line; `machud voice settings set voice.speakReplies=true` changes one setting, and
  `machud voice secret set name=grok` asks for the key without showing it.
- MacHUD asks for the microphone, which the voice host uses under MacHUD's permission.
- When the agent can't take a request, the orb says why (for example "Choose a workspace folder
  for the agent." or "Codex is not installed.") instead of recording it first, and the Brain
  tab shows the same reason, or Ready.
- The Brain tab picks the workspace with a folder picker and says it is required; the agent
  never starts in a folder you didn't choose. The runtime list marks runtimes that aren't
  installed and offers mclaude once it is, noting that its session also appears in MechaHUD.
- When the agent's session is one other apps show too (mclaude), the reply card has an
  "Open in <app>" button that shows it there.
- The resting orb breathes softly and floats a few points below its spot, so it reads as alive
  and ready; it stays still when muted and under Reduce Motion.
- The reply card grows out of the orb and folds back into it, instead of sliding in from the
  side; with Reduce Motion it fades in place.
- `machud voice brain status` shows whether the agent is ready, why not, and which runtimes
  are installed.

## [0.1.0] — 2026-09-27

### Snapping and the layout editor
- Drag-to-snap: hold the trigger (Shift by default; Option, Control, Command or Always)
  while dragging a window and it snaps into the region under the cursor. Tab cycles
  layouts, Esc cancels; hit zones (smallest wins) pick between overlapping regions.
- Snapping only snaps: with no layout, a Shift-drag offers the editor in a toast.
- Full-screen visual layout editor: a fine springy grid (96 × 54 by default, 24 × 12 to
  192 × 108), glass region cards with delete/rename/hit-zone buttons, a floating panel
  that dodges regions, ⌘-drag to draw a region over another and ⌘↑/⌘↓ for stacking,
  undo, and nothing written until Save. `layouts.json` hot-reloads.

### Loadouts
- A loadout owns a layout and assigns an occupant per region: an app (with optional
  `titleMatch`), a web page (Arc, Safari, Chrome app-mode or a built-in window) or a
  sibling app's panel. Apply finds, launches and places every window; `clear=1` first
  minimises the other windows on each screen the loadout covers (on the desktops it
  visits) and `restore` undoes it; per-loadout hotkeys.
- Capture derives the layout from the windows themselves (exact frames, overlaps and
  stacking order kept), per display and optionally per desktop; parked windows become
  parked slots. The capture sheet names the loadout, keeps its layout on its own (for
  ⇧-drag and other loadouts, under its own name) or for that loadout only (`hidden`), and
  saves the tool dock and panels with it when asked.
- Multi-screen and multi-desktop loadouts, displays pinned to persistent ids,
  redirection to another display (`redirected`, `needsDesktops`, `screenMissing`) when
  one is missing, and re-apply when displays change.
- Placement plan: every apply first decides each slot (`stay`, `resize`, `move`,
  `switchSpace`, `launch`, `leave`, `cannot`) from where every window is, on every
  display and desktop. `apply plan=1` returns it as a dry run; Preview draws it over
  every display, with the regions on the desktops that are showing draggable and
  resizable in place (grid-snapped; Apply saves them into the loadout's layout), an
  Edit Layout… button for the editor and an "Other desktops" mini-map for slots bound to
  desktops not showing; the reply and toast report it per slot, with any frame an app kept.
- `spaces.policy` (`bring`, `launchNew`, `leave`) for windows on desktops not showing.
  The rules are in docs/PLACEMENT.md.

### Radial wheel and menus
- Radial loadout wheel (⌃⌥Space, a setting): three rings per loadout, inside out Preview,
  Apply and Clear this screen + Apply, each naming its windows and desktops; a Capture
  wedge (this screen or all screens as a loadout, or draw a new layout in the editor) and a
  Park wedge that names the window it would park (and restores parked).
  **P** previews the highlighted loadout; digits pick wedges; ⇧ reaches the outer ring.
- Status menu, top to bottom: snapping and its trigger key, Launch at Login, Permissions,
  Settings…; the Menu Bar manager; **Loadouts** (each with Preview…, Apply, Clear This
  Screen + Apply, Edit Layout…, Apply at Startup, Delete; then Capture Windows as
  Loadout…, Save Dock and Panels as HUD Loadout…, Draw a New Layout…, the Snap Layout
  ⇧-drag uses, Restore Cleared Windows); the Tool Dock, then **Apps** and Get Apps…;
  Advanced for the JSON file.

### Tool dock and HUD loadouts
- A Dock-like strip of the sibling apps (⌃⌥D): hover apps first, then windowed ones, at
  any of eight positions (an edge, or an L in a corner). Hover panels slide out and
  cross-fade, click pins; windowed apps summon and dismiss on click and come back where
  they were; file drops on apps that accept them; name labels on windowed buttons.
  Dragging the dock never clicks a button and slides hover panels away.
- The strip is HUDKit's `HUDDockStripView` and publishes its frames to `docks.json` so
  sibling docks can sit alongside.
- HUD loadouts save the dock position and every running sibling's panels;
  `startupLoadout` restores them at launch.
- `tooldock` verbs for state, position, synthesized pointer events and PNG snapshots.

### Parking
- Parked slots tuck windows and panels off a screen edge behind a hover orb; siblings
  park cooperatively over their sockets. A Park wedge in the wheel.

### Sibling apps
- Each app's submenu: Show, its own status menu, Hide/Park/Reveal, **Show on Tool Dock**
  (`"dock": false` keeps it off the dock), its settings, Quit or Launch.
- Discovery by the `machud.json` manifest in `/Applications`, `~/Applications`,
  `apps.searchPaths` and announced bundles (`apps announce`, sent by HUDKit builds and
  apps at launch), with a directory watcher that rescans when an `.app` appears, goes or
  is replaced. Duplicate ids resolve to the running bundle, else the newest.
- Supervision: health checks, relaunch with backoff, per-app placement on launch,
  `autoLaunch`; siblings' panels as loadout occupants.

### Menu bar
- Hidden Bar-style management with public API only: separator and expander items,
  collapse/expand/peek, auto-collapse, ⌃⌥B, the `menubar` verb and panel.
- Consolidation: while MacHUD runs, the siblings hide their status items and MacHUD's
  **Apps** menu hosts them, each with Show, the app's own status menu fetched live over
  its socket, Hide/Park/Reveal, settings and Quit/Launch. MacHUD publishes `host.json`;
  `menuBar.consumeSiblings` turns it off.

### Settings window
- One window with a tab for MacHUD and one per discovered sibling, rendered from each
  app's settings schema; number and int fields as a text field plus stepper. MacHUD's own
  tab includes the hotkeys (`hotkeys.loadoutMenu`, `hotkeys.dock`, as `control+option+space`).

### App catalog and installer
- Reads the family's `catalog.json`, caches it and refreshes it every 6 h or on demand.
  `apps install|update|uninstall` downloads the notarized zip, checks size and SHA-256,
  requires Gatekeeper and installs into `/Applications` or `~/Applications`; uninstall
  moves the app to the Trash.
- Settings → **Apps** tab (**Get Apps…**): installed vs available versions, Install,
  Update, Remove, Open, "Install bundled tools", and a note when a newer MacHUD is out.
  On first launch with no sibling apps it opens with the bundled tools selected.

### Website and catalog
- <https://jamesrisberg.github.io/machud/> (`site/`): a one-page site built from the
  catalog at page load, `generate.sh` for a static no-JavaScript `apps.html`, and
  `site/catalog.json`, the family's app catalog, published by GitHub Pages.

### Control socket, CLI and skill
- Control socket `/tmp/machud-<uid>.sock` (one JSON object per line) answering every
  MacHUD command plus the HUDKit contract verbs, and the HUDKit contract socket.
- The `machud` CLI and a `machud` Claude Code skill; reference in docs/API.md.

### Isolation and build
- `MACHUD_SOCKET`, `MACHUD_CONFIG`, `MACHUD_NO_HOTKEYS`, `MACHUD_DRAG`,
  `MACHUD_DOCKS_FILE`, `MACHUD_HOST_FILE`, `MACHUD_FIRST_RUN` and
  `MACHUD_INSTALL_SKIP_GATEKEEPER` for isolated instances that never touch the real
  one's socket, config, dock or menu host.
- Built and installed through HUDKit's `hud-build.sh`/`hud-install.sh`; version from
  `VERSION`. CI runs `swift test` beside HUDKit through HUDKit's `hud-ci.yml`;
  `scripts/integration-smoke.sh` drives an isolated instance against sibling builds.
