# PR #151 — Split context and Gettext

Reviewer: Codex · Author: @mdon · Reviewed: 2026-10-27
Local merge: `5504944` · Status: reviewed, no additional defect found.

Compared the pre-merge context's parsed function clauses with the six extracted
section modules at the merge commit. After normalizing private/public visibility,
metadata and local calls moved behind `Shared`, `Trash` or the context facade,
the bodies match; only the intentionally repeated `repo/0` definitions differ
in multiplicity. Compared public signatures, including default-argument arities,
with the facade: none are missing.

Also inspected the shared data-ownership helpers, trash-lock/provenance paths,
batch update savepoints and the split Gettext backend. The split retains the
existing dependencies and hand-maintained translation catalogues. No code
change was warranted. Validation includes the final full suite and precommit.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.

`mix format` also normalized one existing assertion's line wrapping in
`test/integration/expected_schema_test.exs`; its behavior is unchanged.
