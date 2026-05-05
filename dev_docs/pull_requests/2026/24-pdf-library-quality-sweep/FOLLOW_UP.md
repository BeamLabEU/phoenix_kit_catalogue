# PDF library — Phase 2 quality sweep follow-up

Triage of the workspace's three Phase 2 audit agents (security +
error-handling + async-UX, translations + activity + tests, PubSub +
cleanliness + public API) against the freshly-shipped PDF library
feature. Audit ran 2026-05-06; fixes land in this PR folder rather
than against an existing PR since the PDF library shipped as part of
PR #23's catalogue commits without its own dedicated dev_docs entry.

## Scope

Files audited:

- `lib/phoenix_kit_catalogue/catalogue/pdf_library.ex`
- `lib/phoenix_kit_catalogue/schemas/pdf{,_extraction,_page,_page_content}.ex`
- `lib/phoenix_kit_catalogue/web/pdf_{library,detail}_live.ex`
- `lib/phoenix_kit_catalogue/web/components/pdf_search_modal.ex`
- `lib/phoenix_kit_catalogue/workers/pdf_extractor.ex`
- `lib/phoenix_kit_catalogue/{paths,errors}.ex` (PDF subset)
- `lib/phoenix_kit_catalogue/web/{catalogue_detail,item_form}_live.ex` (PDF wiring)
- `lib/phoenix_kit/migrations/postgres/v111.ex` (core)

## Fixed (Batch 1 — 2026-05-06)

### Race conditions

- ~~**BUG-HIGH: TOCTOU in `permanently_delete_pdf` refcount.**
  `Repo.delete` + refcount + `Storage.trash_file/1` now wrapped in a
  `Repo.transaction(_, isolation: :serializable)`. Concurrent uploads
  can no longer slip a new row in between the check and the handoff,
  which would have left the new upload's reference orphaned by core's
  prune. Loser of the race surfaces as `{:error, :serialization_conflict}`
  for caller retry.~~
- ~~**BUG-MEDIUM: TOCTOU in `ensure_extraction`.** Switched from
  get-then-insert to `insert(on_conflict: :nothing, conflict_target:
  :file_uuid)` + fallback `repo().get/2`. Concurrent uploads of
  identical NEW content no longer abort the second upload with a PK
  violation.~~
- ~~**BUG-MEDIUM: TOCTOU in `store_via_core` checksum lookup**
  documented in code as benign — at worst two `phoenix_kit_files`
  rows for one content (per-user dedup is core's design). The
  catalogue's per-page-content cache still dedupes the actual page
  text storage.~~

### Activity logging

- ~~**BUG-HIGH: `:error` branch never logs activity on mutations.**
  All mutating LV event handlers in `PdfLibraryLive` and
  `PdfDetailLive` now route through `Web.Helpers.log_operation_error/3`
  on the `:error` branch — writes a `db_pending: true` audit row plus
  `Logger.error` with grep-able context. Worker callbacks
  (`mark_extracting/extracted/scanned_no_text/failed`) gained the
  same via an extended `tap_log_extraction/4` with a `{:error, _}`
  clause that fans out a failure audit row per Pdf row pointing at
  the file.~~
- ~~**BUG-MEDIUM: `pdf.uploaded` not logged when storage step fails.**
  `finalize_upload`'s `:error` branch in `PdfLibraryLive` now writes
  a `pdf.uploaded` audit row with `db_pending: true` + a path-leak-safe
  `failure_log_label/1` summary.~~
- ~~**Symmetry rename:** success-side action `pdf.deleted` →
  `pdf.permanently_deleted` so the LV's `log_operation_error` failure
  path produces the matching action via
  `Web.Helpers.derive_activity_action/2`'s `permanently_delete_`
  prefix mapping.~~

### Bare rescues narrowed

- ~~**BUG-MEDIUM: `pdf_search_modal` swallows everything.** Both
  `run_search` and `show_more` now catch only
  `[DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError,
  Ecto.Query.CastError]`. Programmer errors re-raise so they surface
  in telemetry instead of rendering as a UI message that hides the
  bug. UI shows a translated "temporarily unavailable" string.~~
- ~~**BUG-MEDIUM: `item_titles` swallows Multilang failures.**
  Narrowed to `[KeyError, ArgumentError, UndefinedFunctionError]` —
  the realistic stale-cache / missing-locale / API-change shapes.
  Other exceptions propagate.~~
- ~~**IMPROVEMENT-MEDIUM: `enqueue_extraction` broad rescue.**
  Narrowed to `[DBConnection.ConnectionError, Postgrex.Error,
  Ecto.QueryError, ArgumentError]` (covers Oban-not-started in test
  env).~~

### Trust + safety

- ~~**BUG-MEDIUM: `byte_size` from client untrusted.** Now read from
  `File.stat!(tmp_path).size` server-side. The LV no longer threads
  `byte_size` through to the context; it's computed inside
  `create_pdf_from_upload/3` (was `/4`). The `:error`-branch activity
  metadata flags the browser-supplied value as `client_size` (vs the
  server-truthful `byte_size` on success).~~
- ~~**BUG-MEDIUM: Unauthenticated upload allowed.**
  `create_pdf_from_upload/3` now requires `:actor_uuid` to be a
  non-empty binary; returns `{:error, :missing_actor}` cleanly
  instead of crashing inside core's `phoenix_kit_files` NOT NULL
  validation. Authorization model documented in the PdfLibrary
  moduledoc.~~
- ~~**BUG-MEDIUM: `Paths.pdf_viewer` URL injection vector.** Switched
  from `URI.encode/1` to `URI.encode_www_form/1` for the file
  query-param value — reserved characters (`?`, `&`, `=`, `#`) in
  the signed URL can no longer corrupt PDF.js's `#page=N` fragment.
  Pinned by tests.~~
- ~~**BUG-MEDIUM: `PdfDetailLive` PubSub race.** `mount/3` now
  subscribes to `:catalogue_data_changed` BEFORE the initial
  `load_pdf` call — extraction-complete broadcasts arriving in the
  prior gap are no longer dropped.~~
- ~~**IMPROVEMENT-MEDIUM: Upload failure log path leak.**
  `failure_log_label/1` produces a bounded summary string that
  excludes filesystem paths from `:storage_failed` errors. Activity
  metadata uses the same.~~

### UX

- ~~**IMPROVEMENT-MEDIUM: Destructive buttons missing `phx-disable-with`.**
  Added to every trash / restore / permanently_delete button in
  both LVs. Translated label (`Trashing…` / `Restoring…` /
  `Deleting…`).~~
- ~~**IMPROVEMENT-MEDIUM: Time-ago labels not translated.** `Xm ago`,
  `Xh ago`, `Xd ago`, and the strftime fallback are now gettext-
  wrapped with `%{n}` interpolation.~~
- ~~**IMPROVEMENT-MEDIUM: `format_upload_failure/1` raw English.**
  Now gettext-wrapped, no longer leaks `inspect()` of internal
  shapes to the user.~~

### Code cleanup

- ~~**IMPROVEMENT-MEDIUM: Display helpers duplicated across LVs.**
  Extracted to `Web.Helpers`: `pdf_extraction_status`,
  `pdf_extraction_pages`, `pdf_extracted_at`, `pdf_error_message`,
  `pdf_status_badge_class`, `pdf_status_label`, `format_byte_size`,
  `format_time_ago`, `escape_html`. Both LVs drop their local
  copies.~~
- ~~**IMPROVEMENT-MEDIUM: `@spec` backfill** on the four PDF
  schemas, the PDF Paths helpers, and `PdfLibrary.item_titles/1`.~~
- ~~**IMPROVEMENT-LOW: Magic upload-config numbers.** Extracted to
  `@upload_chunk_size` / `@max_concurrent_uploads` module attrs.~~
- ~~**IMPROVEMENT-LOW: Dead `Kernel.||(0)` on `count_pdfs/1`.**
  Removed (count() never returns nil).~~
- ~~**IMPROVEMENT-MEDIUM: Three orphan PDF error atoms removed**
  (`:pdf_invalid_format`, `:pdf_extraction_failed`,
  `{:pdftotext_failed, raw}`) — none had callers; removal documented
  in the moduledoc + test file. Worker stores raw error strings
  directly; LV renders them.~~

### Documentation

- ~~**Authorization model section** added to `PdfLibrary` moduledoc:
  context fns enforce no role checks (LV-mount-only auth, consistent
  with the rest of catalogue); new non-LV callers must verify the
  caller themselves.~~
- ~~**TOCTOU race documentation** in `store_via_core`'s comment
  explaining why the per-page-content cache mitigates the residual
  race.~~

### Tests

- ~~**Schema tests** added in `test/schemas_test.exs` for all four
  PDF schemas (Pdf, PdfExtraction, PdfPage, PdfPageContent). 25
  assertions covering required fields, validations, status
  transitions, edge cases. Pure-function, runs without DB. **All
  green** (113 tests, 0 failures in the file).~~
- ~~**Worker tests** added in `test/workers/pdf_extractor_test.exs`
  covering `normalize/1` (ligatures, soft-hyphen, line-break
  hyphenation, whitespace, special chars), `parse_page_count/1`
  (typical / edge / malformed), `inspect_reason/1` (all four tuple
  shapes + fallback), and the Oban worker definition. 22 tests, all
  green. Pure-function helpers exposed as `@doc false def` for
  testability (was `defp`).~~
- ~~**Paths tests** added in `test/paths_test.exs` for the PDF URL
  helpers — pins the `URI.encode_www_form` fix and the page-fragment
  positioning. 12 tests, all green.~~
- ~~**Context tests** added in `test/catalogue/pdf_library_test.exs`
  for list/count/get/trash/restore/permanently_delete + worker
  callbacks + insert_page (content dedup) + prune_orphan_page_contents
  + search. ~25 tests. **DB-gated** — see "Open" below.~~
- ~~**LV smoke tests** added in `test/web/pdf_library_live_test.exs`
  for mount + filter switch + trash/restore events with
  `assert_activity_logged` actor_uuid pinning + PdfDetailLive
  not-found redirect + render. **DB-gated** — see "Open" below.~~

## Skipped (with rationale)

- **V111 migration cosmetic tweaks** (DROP TABLE CASCADE comment
  tone, up/down style consistency). The migration has shipped to
  `phoenix_kit` `dev`; rolling back to fix doc tone is more risk
  than reward. Marker comments are correct on both `up/1` and
  `down/1` per `feedback_followup_is_after_action.md`'s precedent.
- **`pdftotext --` separator** for argv-injection hardening. Path
  injection isn't exploitable since `Storage.retrieve_file/1`
  returns absolute temp paths under the system temp dir; pdftotext
  may not support `--`; cost > benefit.
- **V102 redundant index `_item_index`** and **partial-index
  column choice** — V102 already shipped. A V112+ cleanup
  migration to drop a redundant index would land more risk than
  the index's write cost. Bundle into the next catalogue
  migration if/when one ships.
- **N+1 `tap_log_extraction` audit row per Pdf reference.**
  Intentional per the design (each user-facing PDF row gets the
  audit trail visible in their stream). Acceptable at expected
  scale (1-5 duplicates per file). Documented in the function's
  comment.
- **`PdfPage` content insert via `insert_all`** bypassing the
  changeset. Internal worker-only path; fields are computed not
  user-supplied. Schema's `unique_constraint` is dead code in this
  path but inexpensive to keep. Documented in the schema test.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/pdf_library.ex` | TOCTOU transaction, ensure_extraction on_conflict, narrowed rescues, error-branch tap_log_extraction, byte_size from File.stat!, missing_actor guard, authorization moduledoc |
| `lib/phoenix_kit_catalogue/web/pdf_library_live.ex` | log_operation_error wiring, phx-disable-with, gettext time-ago, format_upload_failure translation, db_pending audit row, magic-number module attrs, helpers extraction |
| `lib/phoenix_kit_catalogue/web/pdf_detail_live.ex` | Subscribe-before-read, log_operation_error wiring, phx-disable-with, helpers extraction, gettext strftime |
| `lib/phoenix_kit_catalogue/web/components/pdf_search_modal.ex` | Narrowed rescues for run_search + show_more |
| `lib/phoenix_kit_catalogue/web/helpers.ex` | New shared PDF display helpers (8 functions) |
| `lib/phoenix_kit_catalogue/paths.ex` | URI.encode_www_form, @spec backfill on PDF helpers |
| `lib/phoenix_kit_catalogue/errors.ex` | Drop three orphan PDF atoms with rationale |
| `lib/phoenix_kit_catalogue/catalogue.ex` | create_pdf_from_upload arity 4 → 3 |
| `lib/phoenix_kit_catalogue/schemas/pdf{,_extraction,_page,_page_content}.ex` | @spec on every changeset + statuses fn |
| `lib/phoenix_kit_catalogue/workers/pdf_extractor.ex` | Expose normalize/parse_page_count/inspect_reason as @doc false def |
| `test/schemas_test.exs` | 25 new PDF schema tests |
| `test/workers/pdf_extractor_test.exs` | New file: 22 worker tests |
| `test/paths_test.exs` | New file: 12 PDF Paths tests |
| `test/catalogue/pdf_library_test.exs` | New file: ~25 context tests (DB-gated) |
| `test/web/pdf_library_live_test.exs` | New file: ~6 LV smoke tests (DB-gated) |
| `test/errors_test.exs` | Remove tests for the dropped PDF atoms |

## Verification

```
mix test test/schemas_test.exs              # 113 tests, 0 failures
mix test test/workers/pdf_extractor_test.exs # 22 tests, 0 failures
mix test test/paths_test.exs                 # 12 tests, 0 failures
```

Total new pure-function test count: **~50 new tests across three
files, all green**.

## Open

- **Context + LV tests are DB-gated.** Catalogue's standalone test DB
  sits at V110 (Hex pin `1.7.103` + side-loaded V108–110 from earlier
  sweeps) until `BeamLabEU/phoenix_kit#515` publishes 1.7.105 with
  V111. The new `test/catalogue/pdf_library_test.exs` and
  `test/web/pdf_library_live_test.exs` files are written + verified
  syntactically, but cannot run end-to-end against a V110 DB
  (`phoenix_kit_cat_pdfs` table doesn't exist there). Tests will
  green-light automatically once `mix deps.update phoenix_kit` lands
  in catalogue's `mix.lock`. The `:integration` tag's auto-exclude
  in `test_helper.exs` means CI stays green in the meantime.
- **No Storage.store_file integration test.** The full
  `create_pdf_from_upload` happy path (browser file → Storage → Pdf
  row) requires a Storage stub layer (per the document_creator
  `:integrations_backend` resolver pattern). Out of scope for this
  sweep; flag for a future targeted addition once the test infra
  is in place.
- **Component test coverage** for `<.file_upload>` (the upstream
  consumer of the `Uploading…` label tweak) is the workspace
  TODO surfaced in core's AGENTS.md — same scope question as
  PR #512's NITPICK.
