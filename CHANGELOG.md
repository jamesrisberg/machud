# Changelog

MacHUD is the umbrella app of the MacHUD family: a menu bar window/layout manager that
also finds, supervises and hosts the sibling HUD apps. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- A **Multi-desktop loadouts** switch under Experimental in MacHUD's settings, off by default
  (`machud settings set experimental.multiDesktopLoadouts=true` from a script). It takes effect at once.
- **Save Diagnostics** in the MacHUD menu's Advanced submenu, and `machud diagnose` for scripts and agents (the MCP tool
  `machud_diagnose`): when something on the HUD vanishes (the voice orb, the tool dock, a widget), it saves
  a file with where every MacHUD window really is, according to macOS and to the app, next to the displays,
  desktops, any full-screen window and the dock's, widgets' and voice host's state (never what you dictated or
  what the agent answered), and says what looks wrong. The menu item shows a toast and selects the file in
  Finder; the command prints the file's path and the list. Take it before you relaunch anything, since a
  relaunch clears what it records. Files go to `~/Library/Logs/MacHUD`; the newest 20 are kept.
- Every voice take now says what started it: the wake word (with how sure it was, and for how
  many 80 ms frames in a row), the orb, a script's `action`, or the fn key. `machud voice takes`
  lists your recent takes, what started
  each, how long it recorded and what became of it (sent to the agent, typed at the cursor,
  dropped, thrown away, refused, cancelled or failed), counting characters and never keeping your words.
  A wake word heard while it could not start a take is listed too, with its score.
- The agent no longer starts listening when something in the room only sounds like the wake word.
  Once the wake word fires, the speech model checks on your Mac that “Hey Jarvis” was really said
  (about a tenth of a second) before the orb listens or a reply being spoken stops. When it was
  not, nothing appears, nothing is sent or said, and only a line in `machud voice takes` and the
  system log records it, never the words. If the phrase cannot be checked (no speech model, it is still loading
  just after launch, or the last take is still being transcribed), the Voice settings say why
  under the wake word. **Confirm the wake phrase
  before listening** in the Voice settings (`voice.wakeConfirm`) turns this off.
- When the wake word started a request and the agent is still working, or the brain is off or
  cannot take it, your words are no longer typed into whatever app is in front: the orb says
  “Heard you, but the agent is still working” (or why the brain cannot take it) and nothing is
  typed. Requests started with the fn key, the orb or a script are still typed at the cursor.
- Spoken messages in the conversation carry the time you said them and what started the take.
- The voice host's account of each take and of the wake word's listening is in the system log
  (`log show --predicate 'subsystem == "com.jrisberg.machud.voice"'`), readable rather than
  redacted.
- `machud voice state` says whether the voice orb is meant to be showing and, while a full-screen
  app hides it, which app and window did; it also gives the orb window's place, transparency and
  whether it is on the current desktop. Save Diagnostics records this too.
- The voice orb notes in the system log each time it shows or hides and why (for a full-screen
  app, which app and window), each repair, and each change of the screen it sits on
  (`log show --predicate 'subsystem == "com.jrisberg.machud.voice" AND category == "orb"'`).

### Changed
- A loadout is the screen you are looking at. **Capture This Screen as Loadout…** (the Loadouts
  menu, the wheel and the Loadouts settings tab alike) captures the display under the pointer,
  on the desktop showing, even when other displays have windows; the capture sheet no longer
  offers to walk desktops, and Capture on the wheel has one capture action, This screen.
- Loadouts that span several desktops or displays are experimental, behind **Multi-desktop
  loadouts** under Experimental in MacHUD's settings (off by default). While it is off they are
  hidden from the Loadouts menu, the wheel, their hotkeys, the Loadouts settings tab and the
  layout editor, and the menu and the tab say how many are hidden; nothing is converted or
  deleted. A capture or HUD save cannot reuse a hidden loadout's name, and applying, previewing
  or editing one says why it cannot. Turning the setting on brings them back at once, with the
  every-display capture, the desktop walk and the desktop pictures in the settings tab.
- `machud clear` minimises only the windows showing on the screen under the pointer (add
  `screen=<display>` to name another), the same set **Clear This Screen + Apply** clears, instead
  of every window on every desktop. With **Multi-desktop loadouts** on it still clears every
  desktop. `machud restore` brings back what the last clear minimised in both cases.
- The capture sheet's "Include the tool dock and the apps' panels (the HUD)" box starts unticked.
- The Loadouts settings tab draws a one-screen loadout on one screen, without naming a display,
  since it goes on whichever screen you apply it to.
- Panels, the tool dock and widgets have a frosted backdrop: the window server's own blur of
  what is behind them, under a tint, with the same border and sheen as before.
- The layout editor's and the loadout preview's floating panels use the classic frosted material,
  so the desktop behind their dimmed screen stays sharp.
- The setup guide's cards use the classic frosted material, since the guide already blurs the
  desktop behind them.
- The loadout wheel opens small and shows only the path you take. Holding ⌃⌥Space opens four
  petals around the pointer: Apply Loadout (up), Capture (right), Park (down) and, while an app
  serves widgets, Widgets (left). Moving onto Apply Loadout unfolds your loadouts beyond it;
  moving onto a loadout unfolds Preview, Apply (straight on) and Clear + Apply; Capture unfolds
  This screen and Draw layout (All screens between them while multi-desktop loadouts are on),
  Park unfolds Park and Restore, Widgets unfolds Reveal (Lower while the widgets are up) and Edit
  (Done while you are editing them). Letting go on an action does it; letting go on a petal that
  has more beyond it, in the centre, or pressing Esc cancels. Hovering a loadout does not preview
  it. Your loadouts fan out above Apply Loadout, between Widgets and Capture: the first straight
  up, then alternately right and left, up to five in a row. A sixth and more go on a row further
  out, in the same top part of the wheel, with room between the rows for the actions of the
  loadouts inside. So the loadouts never sit in Capture's, Park's or Widgets' way: with your
  loadouts out, moving toward Capture, Park or Widgets opens it, and going back to the centre
  starts over at once. Each loadout has a place of its own, the same size whatever its name, so
  the same move reaches the same loadout every time: adding a loadout moves none of the others,
  not in direction, not to another row and not nearer or further out. Up to five loadouts the
  wheel is no bigger however many you have; each row further out adds to its size. Only the path
  you are on is drawn.
- A quick tap of ⌃⌥Space no longer flashes the wheel: let go within 200 ms and the wheel does not
  show. Held longer, it fades in. The time is a setting (**Radial menu tap**, or
  `machud settings set hotkeys.tapMilliseconds=250`), and your hotkey is kept as it was.
- Digits pick among the petals showing (the top petals, then the loadouts, then a loadout's
  actions), and **P** still previews the highlighted loadout. ⇧ no longer jumps to Clear + Apply:
  it sits beside Apply, or press 3 once a loadout is open.
- The wheel's words are upright on one soft, dark blur that fades out at its edge rather than
  ending in a line, and the blur grows with the petals that unfold. The wheel is dark in light
  mode too, so its white words stay readable. A long loadout name wraps to a second line and then
  shrinks to fit its place (a very long one ends in an ellipsis after a whole word), with its apps'
  icons however many loadouts you have. On a screen too small for it the whole wheel is drawn
  smaller.
- Over the wheel, the petal under the pointer grows and glows, the others beside it fade back,
  and letting go does what that action said, even if the widgets changed while the wheel was
  open. The line under the wheel says what letting go does ("Apply Code", "Park Safari · Docs",
  "Focus a window to park", "Finish editing widgets"), or where to go on from a petal with more
  beyond it ("Move out to a loadout"); a very long window title ends in an ellipsis. The Park
  hint names the window letting go would park, even after a click under the wheel changed the focus.
- Where the wheel cannot open around the pointer (near a screen's edge) the pointer moves to the
  wheel's centre, and nothing lights until you move it, so pressing and letting go without
  moving cancels. With Reduce transparency on, the wheel's blur gives way to a plain dark disc.
- The setup guide's radial menu step teaches the new path: hold, onto Apply Loadout, on to your
  loadout, on to Apply, let go.
- For scripts, `machud menu` and `machud radial` describe the wheel as a tree: `tree[]` of
  nodes with `id`, `path` (such as `loadouts/Messaging/apply`), `name`, `kind`, `hint`, `angle`,
  `radius`, a loadout's `row`, `digit`, `icons`, `hotkey` and either `children` or, for an
  action, `action`; the selection is `{kind, path, name, hint}`. The flat `wedges[]` (each with its `index`, `title`,
  `subtitle`, `rings` and `angleStart`/`angleCenter`/`angleEnd`) and the `rings` radii are gone,
  and so are the selection's `index` and `ring`. `machud radial action=select` now takes `path=` (for example
  `path=loadouts/Messaging/apply`); `index=` and `ring=` are gone, and selecting while the wheel
  is hidden or on a path it does not have is refused.
- From scripts too: while **Multi-desktop loadouts** is off, `machud loadouts` leaves out the
  loadouts that span several desktops or displays (and says how many), and `machud apply` refuses
  one by name, saying how to turn the setting on, before anything moves, as does `machud loadouts
  startup`. The startup loadout and the re-apply when displays change skip one too, with a toast.
- `machud capture name=…` saves the display under the pointer as it looks on the desktop showing.
  Capturing every screen (`screens=all`), walking desktops (`desktops=`), filling a layout per
  display (`screens=<layout>@<display>`) and `machud spaces action=switch` are experimental: while
  **Multi-desktop loadouts** is off they answer with an error saying how to turn it on.
- While **Multi-desktop loadouts** is off, an app in the loadout whose only window is on another
  desktop gets a new window on this one when it can open one. An app with a single window
  (Messages, Signal, Slack…) has its window fetched: MacHUD shows that desktop, brings the window
  over and switches back, the one time an apply switches desktops with the setting off. When it
  cannot (one display, the switch fails), the window is left where it is and the toast names the
  app. Every display is switched back to the desktop it showed whatever goes wrong; if one cannot
  be, the toast says which desktop it was left on and the rest of that screen is not arranged. Windows on another display are still moved over, and minimised ones restored.
  `spaces.policy` in layouts.json applies only with the setting on.
- An app can open another window when its menus have a **New Window** item (or "New Finder
  Window", Mail's "New Viewer Window" and the like), which MacHUD presses, not when it merely has
  ⌘N: applying a loadout no longer makes a new note in Notes or a new message in Mail when it
  wants another of their windows. Menu titles are read in English; with macOS in another
  language such apps count as single-window.
- Arc opens a new window on its own desktop, not the one you are on, so an Arc window (or a page
  in Arc) on another desktop is fetched like a single-window app's instead of leaving a blank
  Arc window behind. When a window MacHUD asked for opens on another desktop anyway, it is left
  there and the toast says so.
- A hidden app (⌘H) in a loadout is shown again where it is and placed; it is never taken for
  an app on another desktop.
- A web page whose window is on another desktop gets a new window on this one, as the plan says,
  instead of being reported placed while nothing appeared.
- The MCP tools tell an agent that a loadout is one screen: `apply_loadout` arranges the display
  the pointer is on, switching desktops only to fetch a single-window app, `capture_loadout`
  saves the screen the user is looking at, and `list_loadouts` (and `machud_status`) count the
  loadouts held back as experimental instead of listing them.
- A sound that reaches the wake word's threshold for a moment no longer wakes it: the phrase has
  to hold for two 80 ms frames in a row (`voice.wakeFrames`, 1 to 4). Saying it still wakes the
  agent, about 80 ms later.

### Fixed
- With the pointer at the very top of a screen (just after using the menu bar), capturing a
  loadout, applying one, its preview, the layout editor, notices and snapping a dragged window
  use that screen, rather than the one above it or the screen of the frontmost window.
- Park on the loadout wheel says when the front app did not answer ("Safari did not answer")
  instead of saying it has no window to park.
- After a wake word that starts nothing (the agent busy or the brain off), the rest of the sound
  that woke it can no longer wake it again: the wake word ignores the next second and listens on
  without reopening the microphone or reloading its model. A wake word heard by a listener that
  was being replaced (its settings had just changed) no longer starts a take.
- A notice about an earlier request (“— pasted instead”) no longer appears on the orb while you
  are speaking a newer one.
- One loadout is applied at a time. Asking for another while one is being applied (a hotkey, the
  menu, a script, the voice agent, the startup loadout or a display change) says "<name> is
  still being applied" instead of running both, which could leave a desktop switched. A HUD
  part whose app never answers no longer keeps the apply going: it is given 30 seconds.
- MacHUD no longer freezes while macOS asks whether it may control System Events (which it uses
  to switch desktops when the plain keystroke is ignored), and never asks that in the middle of
  applying a loadout: without that permission the switch fails at once and says how to allow it
  (`machud permissions request=1`). The keystroke is sent in the background.
- While MacHUD waits for a new window, a popup or tooltip the app shows no longer ends the wait
  with "opened its new window on another desktop".
- `machud apply loadout=… screen=<display>` with a display that is not attached says so instead
  of arranging the screen under the pointer.
- A copy of MacHUD started with only `MACHUD_SOCKET` (for tests) keeps its config, state and dock
  registry beside the socket, in `<socket path without extension>-config/`, instead of reading and
  saving `~/.config/machud`. `MACHUD_CONFIG` still names the file when it is set.
- After the first capture, onboarding points to the menu item that edits it (Loadouts › its name ›
  Edit Layout…) instead of an "Edit Layouts…" item that does not exist.
- The wake word no longer stays off after the microphone stops for it (an audio device change, a
  microphone that would not start): it tries again after 2 seconds, 10 seconds, then every minute,
  and the Voice settings say why it is not listening meanwhile.
- The voice orb puts itself back within about half a second of the next desktop switch, wake or
  display change if its window was left away or transparent while it should show, or still up
  while a full-screen app should hide it; it also finds its place again once a wake or display
  change has settled.
- The voice orb's working arc keeps turning however long MacHUD has been running; after about 40
  minutes of animation it was no longer drawn.
- A glitched microphone level reading can no longer freeze the voice orb's listening pulse.
- A glitched microphone level reading no longer makes `machud voice state` answer with an empty
  state, or throws off when a hands-free take ends: the reading is ignored.
- The tool dock no longer shows white splotches while you switch desktops.
- Panels, widgets and the tool dock are already blurred when a desktop switch lands, instead of
  showing opaque for a moment first.

## [0.3.1] - 2026-10-02

### Fixed
- Spoken replies start promptly on a busy Mac: the voice prepares a reply's pieces strictly in
  order, so the first words never wait behind later ones.

## [0.3.0] - 2026-10-02

### The orb's reply card becomes a conversation
- Hover the reply card under the notch orb and it stays open and shows the whole conversation
  with the agent, scrollable, newest at the bottom.
- Click it and it opens larger, over a dimmed screen, with a field for typing to the agent: the
  same session you talk to. Return sends, Shift-Return starts a new line, ↑ brings back your last
  message, ⌘K clears the field, copy and paste work, and Esc or a click outside closes it.
  Approvals can be answered with ⌘Y and ⌘N. Talking to the orb keeps working while it is open.
- Replies to typed messages are not spoken unless you turn on **Speak replies to typed
  messages** in the Voice settings.
- While a reply is spoken, the card under the orb shows it in step with the voice, and the voice
  gets ready while the agent is still thinking, so it starts sooner.
- The conversation comes back after the voice host restarts, and starts again when the agent
  starts a new session. The orb's right-click menu has **Show Conversation**.
- Scripts and agents get `machud voice conversation`, `machud voice send text=…` (a typed message)
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
  tool dock, installed HUD apps and parked windows; apply or capture a loadout; show, hide or
  toggle an app's panel; run an app's own actions (validated against what the app declares); move
  the tool dock; park and unpark windows; open an agent session; add text to Stash; and speak
  through the voice host. The tool list follows the apps MacHUD discovers. See `docs/MCP.md`.
- `machud apps` now lists each app's manifest (its panels' verbs and capabilities), and `machud
  apps perform app=<app> verb=<verb> [key=value ...]` runs one of an app's own actions, launching
  it if needed.

### Brain: MacHUD tools, and switching the agent works
  running agent switches, without a restart, as soon as it is between turns. While a switch is
  waiting, the Brain tab says so, and
  `machud voice brain status` shows the agent actually running (`activeRuntime`) next to the one
  chosen.
- When MacHUD starts, the agent starts once, knowing every HUD app that announces itself in the
  first seconds, instead of starting and then restarting (which took about a minute with
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
- Pressing fn no longer starts the orb toward the waveform before it knows what you meant: while
  a second press could still turn the take into an agent request, the orb swells slightly,
  brightens and shows a soft ring that follows your voice, then turns into the waveform
  (dictation) or the agent's pulse once the gesture is decided. Under Reduce Motion it only
  brightens.
- The Voice tab has Test Voice, which says a sample with the reply voice you picked, and a
  Download button for the Kokoro voice with its progress; replies use Kokoro as soon as it is
  installed. `machud voice action say text=…` speaks any text, and `machud voice models` shows or
  starts (`download id=kokoro`) the download.
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
