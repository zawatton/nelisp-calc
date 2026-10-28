# NeLisp Calc working rules

When working inside Notes, follow the Notes and dev parent rules as well.
For a standalone checkout, follow this file and README.org. Do not edit
the sibling NeLisp, Sumi, or GNU Calc source trees without coordinator review.

## Architecture

- Native Sumi frontend, using the existing NeLisp AOT / GTK4 / Cairo path.
- A genuine GNU Emacs Calc adapter running in a standalone NeLisp process.
- An explicit interaction state layer for Windows Calculator behavior.
- Host GNU Emacs may build and run reference tests. It must not silently serve
  as the application's calculation backend.
- Resolve dependencies from this checkout or environment overrides.
- Keep generated executables, diagnostics and transient data under target/.
- Keep GNU vendor sources unchanged; record their origin and hashes when used.

## Acceptance

Track the full objective in tools/ai/calculator-progress.org. Do not claim
Windows Calculator parity from the first vertical slice. Report host and
standalone results separately. Engine failure must be visible; do not replace
Calc with a different evaluator or a canned result.

Implementation changes use apply_patch. Stage, commit and push only when the
task includes repository publication. Never reset, stash, or modify other
projects as part of implementation. Check focused behavior before broader builds.
