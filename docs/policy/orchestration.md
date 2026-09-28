# Orchestration policy

A wave is a bounded set of requested outcomes. The orchestrator owns coordination,
shared services, review and integration; implementers own specific changes. Use
parallel lanes only when authorized and when work can proceed independently.

## Roles

- Orchestrator: verifies the map, defines the scope and dependency order, briefs lanes,
  answers questions, schedules review, merges and performs the closing checks.
- Scout: read-only investigation that supplies a verified file map when needed.
- Implementer: one outcome in one worktree, focused verification, a scoped commit,
  and a concise final report. Stops when the brief is complete.
- Reviewer: independent read-only comparison of the diff, brief and relevant policies.
  Findings return to the original implementer for fixes.

Use the configured harness/model defaults and available agent capacity. Reserve room
for review; do not assume a fixed lane count or context budget. Split work before its
brief becomes open-ended. Save briefs and progress to a wave doc so recovery does not
rely on an agent retaining its conversation.

## Brief contract

Every brief carries the worktree/branch/base SHA, owned paths, relevant verified files
with reasons, decided design, desired observable behavior, dependencies, explicit
non-goals, exact focused checks and report format. Distinguish a user-approved default
from an unresolved decision. Do not implement an invented default for a product
question that needs an answer. Continue the independent portion and report the blocker.

A brief's scope exclusion cites a ruling. "Leave X alone" is legitimate when an
owner decision or a policy line says so; when the orchestrator cannot point to one,
X is either in the brief or in the owner questions, never excluded for convenience.

Before changing behavior, a lane finds the tests that pin the current behavior of
what it changes, rewrites them to the desired behavior first, watches them fail,
then implements. The wide checks are not where the old truth should be discovered.

The report names everything noticed outside the brief, each item marked objective
(with the one-line fix) or judgement (with what the owner would be deciding). A small
objective item in a file the lane already has open, the lane fixes in its own hunk
and says so; the rest is the sweep-up lane's (see Triage).

## Verification and review

Lanes run focused checks that prove their behavior, then report and stop. Repeat when
edits or failures justify it; do not repeatedly run full project gates. Record exact
commands, exit/results, test environment and the tested commit. Confirm a test runner
actually filters the requested files. A batch of uniform timeouts is a starved runner,
not the code; re-run one file at a time before reading it as a failure.

The orchestrator runs the configured fast check after each merge, then the full
integration checks once the wave is integrated. Re-run affected checks if integration
fixes invalidate the evidence. UI interaction, layout and motion need browser/device
evidence when automated tests cannot establish the requested behavior.

Use an independent reviewer for privacy grants, the microphone or event taps, destructive
operations, process supervision, or cross-repo contracts (HUDKit's public API, the
socket contract). Review correctness first, then policy
compliance, reuse, and clarity. Review the final fixed diff before merging. If reviewer
capacity is unavailable, report that limitation and explicitly perform the review
locally; do not imply independent review occurred.

## Triage

Every item a lane, a reviewer or the orchestrator notices outside a brief is sorted
by one test: would two implementers write the same fix?

- Yes: objective. A deprecated alias, a duplicated helper with identical copies, a
  comment that narrates history, a site the wave's own new rule now covers, a raw
  figure beside a formatted one, a fixed width a longer value overflows. It is fixed
  in this wave. Small and adjacent, the lane that saw it fixes it in its own hunk;
  otherwise it goes on the sweep-up list.
- No: judgement. Anything with a product, taste or scope dimension: a new variant
  nobody asked for, a rule extended to a different quantity, spacing that may be
  deliberate on one platform. It becomes an owner question with a stated default and
  goes in the task doc's Owner decisions section.

The sweep-up lane is a wave step, not an afterthought. After the lane reports are in
and reviewed, before the wide checks, the orchestrator collects the objective items
into one brief (or a few, by platform) and dispatches it like any other lane. The
checks already run once at the end, so the sweep-up costs one lane, not another round
of checks. A wave is not done while an objective item is unfixed. A report has no
"debt walked past" section; a task doc has none either. An objective item found under
Owner decisions in the closing pass is a process bug, and the fix is to dispatch it.

## Shared resources

One coordinator, the orchestrator, owns the resources every worktree shares on this
Mac: the live MacHUD and its socket, config and UserDefaults domain; the microphone;
the fn/Globe event tap; and the privacy grants (Microphone, Accessibility). Lanes run
isolated test instances (`docs/agent-project.md`) and never touch the live app. A lane
that needs the mic, the fn tap or a new grant says so in its report; the orchestrator
schedules it with the user at the Mac. Two processes on the fn tap fight each other,
so the installed SpeakFree is quit only with the user's agreement.

## Merge and close

Review and fix lanes as they finish. Merge dependency providers before consumers (HUDKit before its apps), one at a
time. Preserve unrelated edits and all release-note entries.

After the wide checks pass, audit each plan sentence against the integrated tree.
Move shipped facts into system docs, carry remaining work into live tasks, preserve
unresolved owner rulings, and archive completed tasks. Read the release note as prose.
Audit the Owner decisions list: every item on it is a judgement call with a stated
default, and an objective item there goes back to a sweep-up lane before the wave hands
back. Report what landed, verification and its limitations, decisions, and the owner
decisions collected. There is no debt list: an objective item still open means the
wave is not done. State the final local branch and revision. Publishing is a separate
action.
