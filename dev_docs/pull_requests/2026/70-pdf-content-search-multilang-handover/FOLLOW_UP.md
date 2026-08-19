# Follow-up: PR #70 — PDF content search + multilang handover

Triaged 2026-08-19 (quality-sweep Phase 1). Source review: `CLAUDE_REVIEW.md`.

## Fixed (pre-existing)

- ~~IMPROVEMENT MEDIUM: attribute-group dropdown didn't localize~~ — `item_form_live.ex` assigns `Catalogue.localize(groups, preview_lang(socket))`; pinned by `test/web/item_form_live_test.exs:525–541`.
- The review's "verified correct" claims still hold: byte→grapheme snippet fix (`pdf_library.ex:1282–1288`), `@preserve_fields` threaded through all four form LVs with `test/multilang_preserve_conformance_test.exs`.

## Skipped (with rationale)

- NITPICK: blanket `rescue _ -> %{}` in `safe_translation/2` (`translations.ex:115–118`) — explicitly "not changed" by the review (defensive read on a render path); unchanged by this sweep for the same reason.

## Open

None.
