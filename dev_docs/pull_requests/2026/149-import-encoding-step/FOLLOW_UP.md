# PR #149 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude). No bugs; two NITPICKs, both marked
"not changed" by the reviewer and both still live in current code.

## Fixed (pre-existing)

None.

## Skipped (with rationale)

None.

## Files touched

None — triage only.

## Verification

Findings re-verified against current `main` at commit `899fa9c`.

## Open

Awaiting the maintainer's decision (fix, skip, or punt):

- NITPICK — `to_utf8/2` validates the same bytes more than once on a refused
  file. `lib/phoenix_kit_catalogue/import/encoding.ex:251-253` calls
  `to_utf8/1`, then `needs_code_page?/1` (`:265-266`) calls `to_utf8/1` again,
  and `ImportLive.ask_encoding?/3`
  (`lib/phoenix_kit_catalogue/web/import_live.ex:760-761`) runs
  `needs_code_page?/1` before that. Suggested fix: inside `to_utf8/2`, replace
  `needs_code_page?/1` with the NUL check alone, since `to_utf8/1` has already
  answered `:not_utf8`. Cost today is one extra `:unicode` pass per upload.
- NITPICK — a mostly-UTF-8 file with one stray byte lands on the encoding step
  and previews as mojibake under every page
  (`lib/phoenix_kit_catalogue/import/encoding.ex:265-266`,
  `needs_code_page?/1`). The reviewer judged the refusal the right trade over
  silently importing replacement characters. Suggested fix, if wanted: detect
  "valid UTF-8 except for N bytes" and show a dedicated message naming the
  offending byte offset instead of the code-page picker.

## Codex follow-up — 2026-10-27

Fixed the damaged-BOM fallback described in `CODEX_REVIEW.md`: self-describing
files never qualify for a single-byte encoding, even when decoding fails.
Regression covers invalid UTF-8 and truncated UTF-16 in both byte orders.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
