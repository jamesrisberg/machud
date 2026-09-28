---
name: reconcile-docs
description: Reconcile current-system documentation against the codebase after changes or drift, preserving design intent separately and refreshing only verified claims.
---

# Reconcile current-system documentation

Paths are relative to the target repository root. Read `AGENTS.md` and
`docs/policy/code-comments.md`. Establish the requested documentation scope.

1. Inventory live system docs. Keep task docs, vision, archived history and generated
   artifacts separate. Inspect existing edits before touching files.
2. Assess each scoped doc against actual code: keep, update, move to vision, or retire.
   Record specific claims and evidence; similar names alone do not prove staleness.
3. Resolve cross-doc contradictions and product-intent uncertainties. Ask only for
   undecided consequential dispositions; continue confirmed factual corrections.
4. Apply scoped changes in dependency order. Describe current behavior in present
   tense, retain reasons, remove obsolete claims, and repair links. Refresh generated
   documentation through its configured generator; report a blocked generator.
5. Read the result and verify referenced paths/symbols and edited claims. Report
   changed docs, unresolved contradictions and limits. Follow source-control policy.
