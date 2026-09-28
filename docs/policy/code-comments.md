# Comments and documentation

Comments explain reasons, invariants and caller contracts that the code cannot show.
Keep the explanation next to the code it governs. Shared reasons belong in a policy
or system document linked from the local explanation.

Use present tense for current behavior. Replace history narration and stale pointers
with the current mechanism and its reason. Preserve meaningful prohibitions when they
explain a real failure mode. Delete comments that only restate code. Put planned work
in task docs and aspirations in vision docs.

Clean comments in files already being changed, in separate hunks. Verify a path or
symbol before linking it. Do not change behavior under a comment-only edit or expand
into a repository-wide cleanup without scope. Report intentional comment cleanup.

Root instructions carry intent and policy; live system docs explain current behavior;
skills carry procedures. Verify claims before moving them among these layers. Generated
documents are refreshed by their generator, never hand-edited to disguise drift.
