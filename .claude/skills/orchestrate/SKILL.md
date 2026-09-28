---
name: orchestrate
description: Coordinate an explicitly requested wave of parallel implementer agents with worktrees, bounded briefs, review, local merges, and integration checks. Use for delegated multi-outcome implementation; use recover-session for interrupted waves.
---

# Orchestrate a bounded wave

Paths below are relative to the target repository root, not this skill directory.
Read `AGENTS.md`, `docs/agent-project.md`, `docs/policy/orchestration.md`,
`docs/policy/source-control.md` and the requested task docs.

1. Establish the authorized scope from the request and existing decisions. Ask only
   for missing scope or required decisions; do not reconfirm settled instructions.
2. Inspect Git state and available agent capacity. Verify configured commands and that no
   lane will touch the live MacHUD. The orchestrator coordinates shared resources. Resolve required UNSET configuration before dependent actions.
3. Inspect the contracts directly or use a read-only scout. Save a wave doc using
   `docs/templates/wave.md`. Choose independent outcomes and dependency order.
4. Create a worktree per lane from the explicit local integration ref and prepare it
   using the configured procedure. Dispatch the brief below within capacity.
5. Monitor progress and answer questions. Review risky lanes independently per policy.
   Return fixes to the same agent and inspect the final fixed diff.
6. Triage what the lanes saw (`docs/policy/orchestration.md` § Triage). Objective
   items go on a sweep-up list; once the lane reports are in and reviewed, dispatch
   one sweep-up lane (or one per platform) with that list as its brief, in the ordinary
   lane shape, before the wide checks. Judgement items become owner questions with a
   stated default under the task doc's Owner decisions heading. A brief's "leave X
   alone" must cite a ruling; if it cannot, X goes in a brief or in the questions.
7. Merge one lane at a time in dependency order and preserve all release-note entries. Run the configured fast integration check after each.
8. Run configured wide checks on the integrated result. Audit plans against the tree,
   update system docs, forward remainders and archive finished tasks. Audit the Owner
   decisions list: an objective item there goes back to a sweep-up lane first.
9. Report integrated branch/SHA, outcomes, evidence, limits, decisions, and the owner
   decisions collected (each a judgement call with its default). There is no "debt
   walked past" list: an objective item still open means the wave is not done. Local
   integration does not authorize publishing.

## Implementer brief

```text
You own Lane <name>: <one coherent outcome>.
Worktree: <absolute path>; branch: <branch>; base: <local ref and SHA>.
Write only in that checkout. Inspect integration read-only with git -C.
Owned paths: <paths>. Dependencies and available contracts: <details>.

Read first: <verified files/symbols and why each matters>.
Verified map: <path:line and responsibility>.
Decided design: <specific behavior and constraints>.
Desired user behavior: <trigger and expected result>.
Non-goals: <boundaries, each citing the ruling that excludes it>.
Open owner decisions: <question and which work depends on it>.
Only use defaults already authorized by the owner.

Before changing behavior, find the tests that pin the current behavior of what you
change (function names, constants, copy), rewrite them to the desired behavior FIRST,
watch them fail, then implement.

Verification: <exact focused commands, test cases, and local environment check>.
If a batch of tests times out uniformly, re-run one file at a time; a wall of
timeouts is a starved runner, not your code.
Shared resources: <isolation env, what the orchestrator coordinates>. Never touch the
live MacHUD or the installed SpeakFree, open the mic or an fn event tap outside a
unit test, or run the wave's full integration gate.
Report a need for additional verification or a shared schema change to the manager.

Commit only owned changes under source-control policy. Inspect the resulting diff
and git show --stat. Do not push. Stop when the brief is complete and focused checks
pass; if blocked, report what is needed rather than inventing a product decision.
Report paths changed, branch/SHA, commands/results, decisions, questions, and
everything you noticed outside this brief, each marked objective (two implementers
would write the same fix; give the one-line fix) or judgement (say what the owner
would be deciding). A small objective item in a file you already have open, fix in
your own hunk and say so.
```

## Reviewer brief

```text
Review Lane <name> read-only. Do not modify files.
Brief: <complete brief and follow-ups>.
Diff: <base SHA>...<lane SHA>, worktree <path>.
Check desired behavior and contract correctness, applicable policies, authorization,
transaction boundaries, retry/offline behavior where relevant, reuse and clarity.
Report blocking / should-fix / nit findings with file:line, concrete consequence and
suggested correction. State verification limits. Fixes return to the implementer.
```
