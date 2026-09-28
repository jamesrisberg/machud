# AGENTS.md

Orientation and standing agreements for agents working in this repository.
Read `docs/agent-project.md` for the project map, commands, and configured environment.
MacHUD is the hub of the MacHUD family (`workspace.json`); a wave that spans sibling
repos is coordinated from here.

## Working agreements

- Stay within the requested outcome. Carry routine implementation choices forward;
  ask about unresolved product decisions that change the result. Continue independent
  work while a decision is pending.
- A local merge does not authorize a push or release. Follow the publication policy
  in `docs/policy/source-control.md` and existing user authorization.
- Treat unfamiliar working-tree edits as another person's work. Stage explicit
  paths or owned hunks, inspect the staged diff, and never stash or discard others' work.
- Prefer one worktree per concurrent implementer. Keep writes inside the assigned
  checkout and coordinate shared resources through the orchestrator.
- The user's installed MacHUD is live. Never `pkill` it, never run a second instance
  with drag watching or hotkeys on beside it, and never write its settings from a test
  instance. Test instances run isolated (`MACHUD_SOCKET`, `MACHUD_CONFIG`,
  `MACHUD_NO_HOTKEYS`); see `docs/agent-project.md`.
- Anything that opens the microphone, installs an event tap, or needs a privacy grant
  (Microphone, Accessibility) is coordinated by the orchestrator: grants need the user
  at the Mac, and two processes on the fn key fight each other.
- Reuse HUDKit's components and the existing helpers. Prefer a structural fix; identify
  any temporary workaround and its remaining limitation.
- Repository docs describe the current system only: no plans, roadmaps, history or
  "previously/renamed" narration. Plans, tasks and wave docs live in the gitignored
  `dev/tasks/`.
- Clean stale comments in files you are already changing, as separate hunks and
  without widening the task. Preserve reasons and invariants.
- Debt you notice is triaged, never walked past. Ask whether two implementers would
  write the same fix. Yes: it is objective, and it is fixed in the same piece of work,
  in your own hunk if it is small and the file is open, otherwise by a sweep-up lane
  before the wide checks. No: it is a judgement call, and it goes to the owner as a
  question with a stated default. A report has no "debt walked past" list. See
  `docs/policy/orchestration.md` § Triage.
- User-facing changes update `CHANGELOG.md` under the unreleased heading, in language
  users understand.

## Where to look

- `docs/agent-project.md`: project intent, architecture map and execution configuration.
- `docs/API.md`, `docs/INTEGRATION.md`, `docs/PLACEMENT.md`: the current system and its socket API.
- `docs/policy/source-control.md`: shared index, worktrees, commits and publication.
- `docs/policy/orchestration.md`: roles, briefs, checks, shared resources and merge loop.
- `docs/policy/task-tracking.md`: queue, decisions, handoff and archival.
- `docs/policy/code-comments.md`: comments and live documentation.
- `docs/templates/`: task, wave and walkthrough formats; copy into `dev/tasks/` when needed.
- `../hudkit/docs/CONVENTIONS.md`, `CONTRACT.md`, `AGENT-GUIDE.md`: the family contract.
- Skills (Claude Code): `.claude/skills/` — `machud`, `orchestrate`, `recover-session`,
  `reconcile-docs`, `reconcile-rules`.
