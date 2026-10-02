# Project configuration

The execution configuration agents rely on. Every command here has been run on the
development Mac; an item marked n/a does not apply to this project.

## Intent and map

- Product: MacHUD, a macOS menu bar app that places windows by loadouts and hosts the
  MacHUD family of HUD apps (tool dock, parking, menu consolidation, app catalog). The
  user is a single power user who scripts it through the `machud` CLI and agents.
- Non-negotiables: every feature is scriptable over the control socket; capture and
  apply are loud (toasts, errors), never silent; sibling apps stay separate, forkable
  apps on the HUDKit contract.
- Source: `Sources/MacHUDCore` (all logic, testable), `Sources/MacHUD` (thin app entry
  and resources), `Sources/MacHUDMCPCore` + `Sources/MacHUDMCP` (the `machud-mcp` MCP tool
  server helper), `Tests/MacHUDTests`, `Tests/MacHUDMCPTests`, `scripts/` (`machud` CLI, `hud-workspace.sh`,
  `integration-smoke.sh`), `site/` (catalog and GitHub Pages).
- Current-system docs: `docs/API.md` (socket verbs), `docs/MCP.md` (the MCP tool server),
  `docs/INTEGRATION.md` (sibling apps),
  `docs/PLACEMENT.md` (placement plans), `README.md`. The family contract lives in
  `../hudkit/docs/` (`CONVENTIONS.md`, `CONTRACT.md`, `AGENT-GUIDE.md`, `CLI.md`).
- Shared UI primitives: HUDKit (`HUDPanelWindow`, `HUDGlassView`, `HUDPanelHost`,
  `HUDSocketServer`, `HUDDockStripView`).
- Canonical schema, generated output, database, authorization: n/a.
- Release note: `CHANGELOG.md`, written for users of the app.

## Execution configuration

| Item | Verified value |
|---|---|
| Local integration branch | `main` in each repo; the SpeakFree fork uses `integration/machud`, checked out in `../speakfree` (its `main` tracks upstream) |
| Worktree parent directory and branch prefix | `../worktrees/<repo>-<lane>`, branch `wave/<wave>/<lane>`. A `../worktrees/hudkit` symlink makes `../hudkit` path dependencies resolve from a worktree |
| Dependency/worktree preparation command | None beyond `git worktree add`; SwiftPM resolves on first build |
| Local services start and health check | n/a for most lanes. MacHUD test instance: `MACHUD_SOCKET=<tmp>.sock MACHUD_CONFIG=<tmp dir>/layouts.json MACHUD_NO_HOTKEYS=1 build/MacHUD.app/Contents/MacOS/MacHUD`, health `MACHUD_SOCKET=<tmp>.sock scripts/machud hello`. Its voice host runs with no microphone, brain, orb or real Keychain item (`MACHUD_VOICE_LIVE=1` opts back in; see README's isolation table) on `<tmp>-voice.sock`, checked with `MACHUD_SOCKET=<tmp>.sock scripts/machud voice status`. It applies no startup loadout, re-applies nothing on display changes and launches no `autoLaunch` app unless `MACHUD_APPLY_STARTUP=1`. Add `HUD_NO_ANNOUNCE=1` to `./build.sh` so the build does not announce itself to the live MacHUD |
| Backend identity check | n/a (no backend). The live instance is the dev build `build/MacHUD.app` of the integration checkout on `/tmp/machud-<uid>.sock` (check with `ps`); tests never target it |
| Local test fixture setup and reset authority | Temp dirs per test instance; no shared fixtures |
| Shared resource coordinator | Orchestrator (live MacHUD, microphone, fn event tap, privacy grants) |
| Generation and freshness commands | n/a |
| Fast integration check after each merge | `swift build` then `swift test` in the merged repo |
| Focused test command and filter syntax | `swift test --filter <TestClass>[/<testMethod>]` |
| Full integration checks | `swift test` and `./build.sh` in every touched repo; `scripts/hud-workspace.sh build` and `test` across the family; `scripts/integration-smoke.sh` for sibling-app behavior |
| Visual checks | Apps take `--snapshot <png>`; `screencapture` has no permission from the terminal |
| Browser/device helper and local test identity | n/a |
| Migration procedure | n/a |
| Schema dump/derived documentation command | n/a |
| Git hooks and files they modify | `scripts/install-hooks.sh` (per repo, via HUDKit) |
| Signing | `./build.sh` signs with the Apple Development identity unless `HUD_SIGN_IDENTITY` names another. The live instance's Accessibility grant is tied to its Developer ID signature, so the orchestrator rebuilds it with `HUD_SIGN_IDENTITY="Developer ID Application: <name> (<team>)"`; an Apple Development rebuild comes up with Accessibility off. Lanes' own builds keep the default. Releases use Developer ID through `../hudkit/scripts/hud-release.sh` |
| Available agents and maximum active | Claude Code Agent tool; up to 6 implementers plus reviewers |
| Model selection | Opus for interactive, cross-cutting or stateful lanes; Sonnet for contained ports and mechanical lanes |
| Practical lane concurrency | 4 to 6 lanes, one repo area each |
| Session recovery/report location | Wave doc in `dev/tasks/wave-<name>.md`; briefs are saved there before dispatch |
| Push and release authority | Explicit user authorization for each push or release |
| Commit attribution | Family repos (hudkit, machud, sift, stash, scratch, mechahud, ffmpeghud, magickhud, servershud): commits authored by the user only, no co-author trailer |

## Local environment procedure

Nothing talks to a remote backend. What is shared across worktrees on this Mac:

- The live MacHUD (the dev build `build/MacHUD.app`) and its socket, config (`~/.config/machud`)
  and UserDefaults domain (`com.jrisberg.machud`). A test instance must set
  `MACHUD_SOCKET` and `MACHUD_CONFIG`, and must not run `settings set`, since it shares
  the UserDefaults domain.
- The user's real windows and apps. An isolated instance still drives them through
  Accessibility: `apply`, `capture`, `clear`, `park`, `place`, previews and the editor act on
  the live desktop. Tests and lanes must not capture or apply against them; use unit tests
  with fakes and offscreen snapshots instead.
- Sibling sockets in `~/Library/Application Support/MacHUD/sockets/`. A dev build
  announces itself to the live MacHUD unless `HUD_NO_ANNOUNCE=1`.
- The microphone, the fn/Globe key event tap and the privacy database (TCC). Only one
  process may hold the fn tap. Grants need the user at the Mac; the orchestrator
  schedules any lane that needs them.
- The installed SpeakFree app is the user's daily dictation tool: do not run its
  `scripts/dev.sh` (it removes the installed app) or quit it without asking.
