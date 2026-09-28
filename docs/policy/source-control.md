# Source control policy

## Publication

Local commits and merges are distinct from publishing. A request to merge authorizes
only a local merge unless it explicitly includes a push. One authorized push does not
create standing permission for future pushes. Record any automatic deployment tied
to the integration branch in the project configuration. Do not bypass checks without
an explicitly authorized reason.

In the MacHUD family repos (listed in `docs/agent-project.md`) commits carry the user's
name only, with no co-author trailer, and repository docs describe the current state
only. Plans, task and wave docs stay in the gitignored `dev/tasks/`.

## Shared working tree

Inspect status before editing, staging, committing and merging. Do not stage, revert,
reset, or stash unfamiliar edits. Use explicit paths, never blanket adds.

For files entirely owned by the task, inspect their diffs and use a path-scoped commit
if appropriate. For a file containing another person's hunks, prefer moving the work
to an isolated worktree. If partial staging is unavoidable, coordinate exclusive
index access, stage only owned hunks, inspect `git diff --cached`, and commit that
reviewed index without path arguments. `git commit -- path` reads the working-tree
version of the path and can include unstaged foreign hunks. If exclusive index access
cannot be established, defer the commit or use a separate worktree.

Inspect `git show --stat` and the resulting diff after every commit, including changes
made by hooks. Repair a contaminated commit only after establishing ownership and
whether it has been published; never blindly reset a shared branch's latest commit.

## Worktrees and merges

Create each branch from the explicit local integration ref and record its base SHA.
Prepare dependencies and necessary local configuration using the verified project
procedure. Do not copy production secrets as a default setup step.

An implementer writes only in its assigned worktree. Inspect the integration checkout
read-only with `git -C <integration-checkout> ...`; do not change into it to write.
Before merging, inspect unfamiliar edits in the destination. If the merge overlaps
those edits, defer or coordinate their preservation rather than reverting or stashing.

Merge one lane at a time with `--no-ff` to retain a reviewable unit. Resolve release-note
conflicts by retaining every relevant user-facing change. Retry transient
index lock contention after checking the owning process; never delete an active lock.
