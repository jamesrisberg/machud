# Changelog

MacHUD is the umbrella app of the MacHUD family: a menu bar window/layout manager that
also finds, supervises and hosts the sibling HUD apps. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### The orb's reply card becomes a conversation
- Hover the reply card under the notch orb and it stays open and shows the whole conversation
  with the agent, scrollable, newest at the bottom.
- Click it and it opens larger, over a dimmed screen, with a field for typing to the agent: the
  same session you talk to. Return sends, Shift-Return starts a new line, ↑ brings back your last
  message, ⌘K clears the field, and Esc or a click outside closes it. Approvals can be answered
  with ⌘Y and ⌘N. Talking to the orb keeps working while it is open.
- Replies to typed messages are not spoken unless you turn on **Speak replies to typed
  messages** in the Voice settings.
- While a reply is spoken, the card under the orb shows it in step with the voice, and the voice
  gets ready while the agent is still thinking, so it starts sooner.
- The conversation comes back after the voice host restarts, and starts again when the agent
  starts a new session. The orb's right-click menu has **Show Conversation**.
- Scripts and agents get `machud voice conversation`, `machud voice say text=…` (a typed message)
  and `machud voice card peek|pin|expand|close`.

### Desktop widgets
- HUD apps can now put widgets on your desktop: small glass tiles such as a clock or the weather.
  Add them from the status menu's new **Widgets** submenu or from **Edit Widgets…**, which shows a
  gallery of every widget by app with a button per size. Widgets snap to a grid, never overlap,
  and can be placed several times, each with its own settings.
- In edit mode you drag widgets to move them, and their controls remove them, open their settings
  and change their size; the layout grid shows where they can go. Done or Esc locks them again.
- Widgets sit under your windows. **⌃⌥W** raises them all until you press it again or Esc (also
  in the Widgets submenu and on the wheel); Float Above Windows keeps one on top.
- Widgets are on every desktop and come back where they were after a restart, a display change or
  their app relaunching. An app with widgets is kept running unless you quit it from MacHUD. HUD
  loadouts save your widgets and put them back.
- Scripts and agents get `machud widgets` (list, types, add, move, resize, layer, settings,
  remove, edit, reveal) and the MCP tools `list_widgets`, `add_widget`, `change_widget` and
  `widget_mode`.
- An app that serves only widgets is listed under Apps like any other, without a tool dock
  button, and a panel kind MacHUD does not know is skipped instead of being shown as a window.

### Widgets live on the layout grid
- Desktop widgets now sit on the same grid as your layouts, like small windows of a fixed size:
  drag one and it snaps to the grid lines, flush against a region's edge or the edge of the
  screen, anywhere on the screen, never on top of another widget.
- Edit Widgets shows exactly the layout editor's grid, with your layout's regions faintly under
  it, so widgets line up with them.
- The layout editor shows your widgets as blocks you can drag, and its panel has an **Add
  Widget** menu. Widget changes there apply right away.
- Widgets you had placed keep their place: they move onto the new grid the first time MacHUD
  starts. Scripts place them with `x= y=` (fractions of the screen) or `col= row=` (grid lines).

### Quitting an app yourself keeps it quit
- Quitting a HUD app with ⌘Q or its own Quit menu item now counts as you meaning it: MacHUD no
  longer brings the app back, including apps it keeps running for their widgets. Open the app
  again and it is kept up as before. An app that is killed or crashes is still relaunched.
  Needs apps built on HUDKit 0.3 or newer.

### widgetHUD and the other widget apps
- widgetHUD is a new HUD app that puts a clock, the weather and a calendar on your desktop as
  widgets. serversHUD (Running Servers), Stash (Latest Clips) and MechaHUD (Claude Sessions) now
  offer widgets too, and the README lists them.

### The orb lets you finish your sentence
- Talking to the agent through the orb, the wake word or `ask` no longer stops at the first
  pause. It waits 2 seconds of quiet by default (was 1.2), and a further 1.5 seconds when your
  last words sound unfinished ("and", "um", a trailing comma) or have not been transcribed yet.
  Speech is judged against the room's own noise, measured continuously, so soft speech in a quiet
  room counts and a click or a knock does not; a fan that starts mid-take can read as speech for
  up to 3 seconds. A take can run up to two minutes.
- If it hears nothing that could be speech for 10 seconds (no words transcribed, nothing above a
  whisper), the orb stops listening and says "Didn't hear anything" instead of keeping the
  microphone open.
- New **Hands-free** settings in the Voice tab: **End of turn** (Automatically, or When I tap),
  **Pause before sending** (1 to 4 seconds) and **Microphone sensitivity** (low, medium, high).
  Scripts use `machud voice settings set handsFree.pause=3` and friends; a value that is not one
  of a setting's choices (`handsFree.endOfTurn=never`) is now refused with an error.
- Every hands-free take records why it ended (the pause, the two-minute limit, a tap, a cancel)
  with what the microphone measured, in `machud voice state` and `machud voice status`
  (`lastTakeEnd`) and in the log, so a take that ends too soon can be diagnosed.

### MacHUD checks that a panel really appeared
- When you click or summon a HUD app's panel and it opens on another desktop (or nowhere on
  screen), MacHUD no longer takes the app's word that it is showing: it says where the panel
  went and that relaunching the app fixes it, and the app's submenu notes it too. Passing hovers
  over the tool dock stay quiet. `machud panels` reports `onScreen` and `elsewhere` for each
  shown panel.

### Relaunch apps after an update
- MacHUD notices when a HUD app is still running an older build than its own bundle on disk, or was
  built for an older MacHUD. Its submenu says "Update ready, relaunch to apply" or "Built for an
  older MacHUD", every running app's submenu has **Relaunch <App>**, and **Relaunch Outdated
  Apps** appears next to Launch All Apps while any app is behind. Scripts get `outdated` and
  `contract` in `machud apps`, plus `machud apps relaunch id=<app>` and
  `machud apps relaunch-all [outdated=1]`.

### Launch and quit every app at once
- The menu's Apps section starts with **Launch All Apps** and **Quit All Apps**, which start
  every HUD app that is not running or quit every one that is. Each app's own submenu still
  launches or quits just that app. Scripts and agents get the same with `machud apps launch-all`
  and `machud apps quit-all`.

## [0.2.0] - 2026-09-29

### The brain can drive MacHUD
- MacHUD ships an MCP tool server, `Contents/Helpers/machud-mcp`, so an agent (Codex, Claude
  Code, mclaude or any MCP client) can read and drive MacHUD directly: see the displays, loadouts,
  tool dock, installed HUD apps and parked windows; apply or capture a loadout; show, hide or
  toggle an app's panel; run an app's own actions (validated against what the app declares); move
  the tool dock; park and unpark windows; open an agent session; add text to Stash; and speak
  through the voice host. The tool list follows the apps MacHUD discovers. See `docs/MCP.md`.
- `machud apps` now lists each app's manifest (its panels' verbs and capabilities), and `machud
  apps perform app=<app> verb=<verb> [key=value ...]` runs one of an app's own actions, launching
  it if needed.

### Brain: MacHUD tools, and switching the agent works
- Changing the agent (Codex, Claude, mclaude, Hermes) in the Brain tab now takes effect: the
  running agent switches, without a restart, as soon as it is between turns. While a switch is
  waiting, the Brain tab says so, and
  `machud voice brain status` shows the agent actually running (`activeRuntime`) next to the one
  chosen.
- When MacHUD starts, the agent starts once, knowing every HUD app that announces itself in the
  first seconds, instead of starting and then restarting (which took about a minute with
  mclaude).
- The agent can use MacHUD itself: apply and capture loadouts, show and hide panels, run the HUD
  apps' actions, move the tool dock and more, through MacHUD's own tools instead of trying to
  drive the screen. It is told which HUD apps and loadouts you have. On by default; turn it off,
  or have each MacHUD action ask first, in the Brain tab's MacHUD tools section.

### Voice: wake word and capture
- The wake phrase is chosen from the phrases there is a model for (today "Hey Jarvis"), each
  marked installed or not with its terms, in the Voice tab and the setup guide's Voice section
  (where the wake word is off until you turn it on).
- Download the Hey Jarvis model from either place, or with `machud voice models download
  id=hey-jarvis`. It is openWakeWord's model for personal, non-commercial use, downloaded when you
  ask and never bundled with MacHUD. The wake word starts listening as soon as it is installed,
  no restart.
- When the wake word is on but cannot listen, the Voice tab says why (the model is missing or
  downloading, the microphone is not allowed), and turning it on shows the reason under the orb.
  A saved "Hey Computer" becomes "Hey Jarvis" when the wake word is turned on.
- The wake word's microphone starts again by itself after an audio device change instead of
  going quiet.
- The first dictation or agent request after MacHUD starts records from the microphone like
  every later one, instead of failing with "Capture failed".

### Voice: speech model, dictation history, transcripts in Stash
- Dictation needs the Parakeet speech model, and a Mac without SpeakFree has none. The Voice tab
  and the setup guide's Voice section now show whether it is installed and download it with
  progress (`machud voice models download id=parakeet`); dictation works as soon as it finishes,
  no restart. SpeakFree uses the same download, so either app's copy serves both.
- Keep dictation history: Off, Text only or Text and audio, in the Voice tab and the setup guide.
  With SpeakFree installed you can share one history with it, kept in SpeakFree's recordings
  folder in its format; until you choose, MacHUD follows SpeakFree's own "save recordings"
  choice. Otherwise history goes to `~/Library/Application Support/MacHUD/Voice/History`.
  `machud voice history` shows where.
- Each finished dictation's text is sent to apps with a text feed, such as Stash's history
  (turn off with "Send dictations to the text feed"); agent replies can be sent too.

### Loadouts in Settings
- Settings has a Loadouts tab: every loadout with a small picture of it, its screen, desktop
  and window counts, and a star on the one applied at startup. Click one to see it large,
  laid out like your displays, one desktop at a time, with each app's icon and name in its
  region, parked windows, and where the tool dock and HUD apps go.
- From there: Apply, Preview on your displays, Edit Layout (the drawing editor on that
  loadout), Rename, Duplicate, Apply at Startup and Delete (it asks first); New captures your
  current windows or opens the editor on a blank layout.
- Deleting a loadout also removes the layouts a capture made just for it; the menu's Delete…
  now asks first and names them. Renaming or duplicating a loadout takes those layouts along.
- The same from the shell: `machud loadouts rename name= to=`, `duplicate name= [to=]`,
  `delete name=`, `startup [name=]`; `machud edit loadout=<name>` opens the editor on a loadout
  and `machud edit new=1` on a blank layout.
- A test copy of MacHUD (its own `MACHUD_SOCKET` or `MACHUD_CONFIG`) no longer applies the
  startup loadout, re-applies a loadout when displays change or launches your auto-launch
  apps on its own; `MACHUD_APPLY_STARTUP=1` turns that back on.

### Agent sessions
- MacHUD can find and open an agent session in whichever app shows it, without naming the app:
  `machud sessions providers` lists the discovered apps that show agent sessions (MechaHUD's
  dashboard is one), and `machud sessions open id=<session key>` opens and focuses one, launching
  the app if it is not running.

### Text feed
- MacHUD can send finished text (a dictation transcript, an agent reply, ...) to whichever app
  keeps a text feed, without naming the app or writing it to the clipboard: `machud feed add
  text= source= [title=]` forwards it to every discovered app that already shows one (Stash's
  history is one) and is already running; it never launches an app just to feed it.

### Setup guide
- The first launch opens a setup guide over your desktop: a blurred, see-through overlay rather
  than a cover. It opens on a checklist of every section, each marked to do, done or skipped,
  and the checklist stays beside you as you go, ticking items off in place; click any item to
  jump to it.
- The sections: the permissions MacHUD needs (Accessibility and the microphone, with live
  status); voice (on/off, hold or tap on the fn key, and a "try it" area that shows what the
  voice host hears); the brain (pick Codex, Claude Code, Hermes or mclaude with what is
  installed shown, the folder it works in, your home folder unless you choose another, spoken
  replies, the reply voice with a Test voice button, and the Kokoro voice's download); the HUD
  apps with one-click installs; the tool dock (what it is, on or off, and where it sits, changed
  live); your first loadout (arrange a few windows while the guide shrinks out of the way,
  capture them under a name, and see the regions); and the radial menu, where you practise
  holding ⌃⌥Space and flicking to the loadout you just made until it applies.
- Esc leaves it for later and it reopens where you left it, checklist included; Skip setup or
  Finish stops it showing by itself. **Setup Guide…** in the menu and `machud onboarding show`
  bring it back; `machud onboarding reset` starts it over.

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
- When the agent can't take a request, the orb says why (for example "Codex is not installed.")
  instead of recording it first, and the Brain tab shows the same reason, or Ready.
- The agent works in your home folder until you choose another: the Brain tab shows which
  folder it uses and picks another with a folder picker. The runtime list marks runtimes that
  aren't installed and offers mclaude once it is, noting that its session also appears in
  MechaHUD.
- Pressing fn no longer starts the orb toward the waveform before it knows what you meant: while
  a second press could still turn the take into an agent request, the orb swells slightly,
  brightens and shows a soft ring that follows your voice, then turns into the waveform
  (dictation) or the agent's pulse once the gesture is decided. Under Reduce Motion it only
  brightens.
- The Voice tab has Test Voice, which says a sample with the reply voice you picked, and a
  Download button for the Kokoro voice with its progress; replies use Kokoro as soon as it is
  installed. `machud voice action say text=…` speaks any text, and `machud voice models` shows or
  starts (`download id=kokoro`) the download.
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
