# Task tracking policy

Task Markdown is the live queue. A board, if added, edits those files rather than
maintaining another source of truth. Board layout metadata owns presentation only.

Each task describes one coherent outcome and has a `Status:` line below its title:
`backlog`, `underway`, or `backburner`, optionally followed by context. Keep the desired
behavior, constraints, unresolved decisions, remaining work and current verification.
Delete resolved checklist items instead of turning the task into a diary.

Owner rulings are decisions. Preserve their wording until clearly represented in the
live task or implemented behavior. Every item under a task's Owner decisions heading
is a judgement call with a stated default; an objective fix does not wait there, it
gets done (`docs/policy/orchestration.md` § Triage). If comments use a marker, reserve
`**[OWNER]**` for actual owner comments; agents must not invent owner rulings. A board
implementation must agree on that marker. Keep every line of multiline comments inside
its blockquote.

A handoff names branch/worktree/base and current SHA, owned edits, exact checks and
results, review state, dependencies and next steps. Keep it current while work is live.

After implementation, audit the task against the tree sentence by sentence. Transfer
current-system facts to system docs. Forward every remainder to a live task before
moving the completed document into `dev/tasks/archived/`; include forwarding links.
Archived docs are historical context, not the current contract.

A walkthrough is a hands-on check of what the user sees: a time budget, what to have
ready, numbered checks with the expected result stated plainly, what the check
deliberately does not cover, and a place to record problems. It lives in a document
of its own, `dev/tasks/walkthrough-<slug>.md`, so the whole set can be seen in one
place and one can be read while a phone is in the other hand. Its status vocabulary
is two words, not the lane names: `owed` (never run, or a rerun is due) and `run`
(findings live in the document as owner comments). A `Checks:` line names the task
document or system document the check belongs to, and is carried rather than
resolved when that target archives or moves.

A walkthrough outlives the task that built the feature: the task document archives
when its work is done, and the walkthrough archives when the check itself retires. An
owed walkthrough is not a remainder that keeps a task live, and a feature with an owed
walkthrough is not represented as fully verified. Run it against the local test
environment (an isolated test instance), never against the live MacHUD.
