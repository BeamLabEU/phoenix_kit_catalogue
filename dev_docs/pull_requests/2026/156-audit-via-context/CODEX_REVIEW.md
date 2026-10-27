# PR #156 — Activity source from API context

Reviewer: Codex · Author: @timujinne · Reviewed: 2026-10-27
Local merge: `8708366` · Status: reviewed, no additional defect found.

Checked `Common.write_opts/3` and all handler call sites against core's executor
context and actor definition. A non-empty string source is retained; older/key
contexts and unusable values fall back to `api`. Session actors retain the
`key_prefix` field with a nil value, so the existing metadata access also works
for session/assistant calls. The approving actor metadata remains intact.

The focused API suite includes the source/fallback tests. No implementation
change was warranted. Final validation includes the full suite and precommit.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
