---
name: recover-session
description: Recover an interrupted orchestration wave from saved briefs, reports, Git state and relevant session history, preserving existing work and resuming only unfinished lanes.
---

# Recover an interrupted wave

Paths are relative to the target repository root. Read `AGENTS.md`,
`docs/agent-project.md`, and the source-control and orchestration policies.

1. Confirm the prior agents are stopped; use the harness's normal resume facility
   when available. Do not dispatch duplicate writers into a live lane.
2. Read the saved wave doc, original briefs, follow-ups and reports. Inspect every
   relevant worktree's status, branch, diff and commits. Attribute uncommitted edits
   by the brief and evidence; preserve edits whose ownership is unclear.
3. Consult only relevant authorized session history if records are incomplete. Use
   the configured harness location and format; extract decisions, dispatches and
   final progress rather than loading all logs or copying them into the repository.
4. Mark completed, unfinished and uncertain lanes based on Git and verification
   evidence. A prior report is evidence to check, not permission to skip missing
   integration or review. Never rebuild code already present.
5. Re-establish the local environment without resetting shared data. Resume unfinished
   lanes with their original spec, follow-ups, existing SHA/diff and remaining checks.
   State: 'The work is already here; verify it, finish only the remainder, and report.'
6. Follow the normal review/merge/closing loop. Report recovered work, ownership
   uncertainty, remaining decisions and exact verification state.
