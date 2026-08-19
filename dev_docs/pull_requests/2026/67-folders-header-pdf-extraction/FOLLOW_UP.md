# Follow-up: PR #67 — Folders, header, PDF extraction

Triaged 2026-08-19 (quality-sweep Phase 1). Source review: `GROK_REVIEW.md` (18 tagged findings + 5 explicitly-left-open items).

## Fixed (pre-existing)

All 18 tagged findings verified implemented in current code — highlights, with the current anchors:

- ~~BUG HIGH ×3: Oban retries dead / `finalize` acked failed status writes / `page_count == 0` counted as success~~ — `pdf_extractor.ex:71,75,169–196`; `pdf_engines.ex:132–159`.
- ~~BUG MEDIUM ×4: cross-type positions, advisory-lock coverage, forgeable `place_level_rows`, unfiltered `:deleted` children~~ — `catalogue.ex:2920/2929`, `lock_catalogues_order!/0` at 11 writers, `:invalid_entry`/`:not_siblings` guards + `test/catalogue_test.exs:408–421`, `:2200`.
- ~~IMPROVEMENT HIGH ×2: doubled drag broadcasts, missing atom/action pins~~ — reorder writers log once via `log_activity/1`; `errors.ex:160–181` + `test/errors_test.exs` + `test/activity_logging_test.exs`.
- ~~BUG HIGH ×2 + BUG MEDIUM: reorder-all folder smash, detail column-editor scope clobber, stale folder filter~~ — `catalogues_live.ex:1657–1658`, `catalogue_detail_live.ex:1343–1349`, `drop_stale_folder_filter/2`.
- ~~remaining IMPROVEMENT/NITPICK items~~ — all verified in place (picker reopen guard, `Ecto.UUID.cast` on `parent`, gettext titles, `\r\n` hyphenation, ViewConfig comment, `new_subfolder` parent lookup).

## Fixed (quality sweep — 2026-08-19)

- ~~IMPROVEMENT MEDIUM (half-applied): AGENTS.md folder bullet still said "soft-delete only"~~ — the second occurrence (`AGENTS.md`, module-map bullet) now mentions `delete_empty_folder/2` hard-delete, matching the Testing-section fix the PR made.

## Skipped (with rationale)

- LOW: `CataloguesLive` reloads once on its own drag broadcast (`catalogues_live.ex:103–110` has no `from == self()` ignore, unlike the sort handler). One redundant `load_data` per originating drag since the duplicate broadcasts were removed; harmless, and threading `from` through the shared data-changed event shape touches every publisher. Revisit if drag latency ever matters.

## Open (left-open by the review, still live — need an owner decision)

1. **pdfium runs in-process; a native fault kills the BEAM** (`pdf_engines.ex:114–147`). Accepted in #67 because uploads are admin-only. A Port/`:peer`-node isolation is the real fix.
2. **`System.cmd` poppler calls have no timeout** (`pdf_engines.ex:73/102/170`) — a wedged `pdftotext` pins the Oban worker slot.
3. **Drop is two transactions** (`catalogues_live.ex:1362–1383`) — a failed `place_level_rows` after a successful move leaves the row moved but unordered.
4. **`ex_pdfium ~> 0.6` ships no musl/Alpine or Windows artifact** — the "zero system packages" claim is glibc-Linux + macOS only.
5. **`scanned_no_text` refuses UI retry** (`pdf_library.ex:507–510`) — `force: true` exists but no UI caller passes it; a partial extraction whose surviving pages are blank is stuck.
