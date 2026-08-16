# Review — PR #67: Folders as a file explorer, header consolidation, in-app PDF extraction

**Author:** Max Don (@mdon)
**Reviewed:** 2026-08-16
**Status:** Merged as `a35c40f` (`e3aa90c` on `mdon/main`)
**Verdict:** SHIP the product work. Several real post-merge bugs fixed
on main before the 0.16.0 Hex publish.

Reviewed against phoenix-thinking, ecto-thinking, oban-thinking, and
elixir-thinking. The index LiveView does not query in `mount/3` (empty
assigns + subscribe; `handle_url_state/2` loads). Job args use string
keys. New user-facing strings were added to the hand-maintained
catalogues.

---

## What landed

Three arcs on top of #64, following the document model (catalogue =
document, categories = chapters, folders = file explorer):

1. **Index as a file explorer** — inline folder tree, card-view group
   boxes, interleaved per-level manual order, empty-only permanent
   folder delete, restore-to-folder-or-root.
2. **Header consolidation** — `page_crumbs`, detail description as a
   clamped line, live columns editors, category form tabs + attachments.
3. **PDF engines** — pdfium first (`ex_pdfium`), poppler fallback,
   `normalize/1` scrubs NUL + invalid UTF-8.

Also batched #63 review follow-ups (browse-on-reopen), #56 (advisory
lock + broadcast on the three reorder writers), and #65 (via core
`UrlState`).

The pre-PR hunt (`0bb5206`) already closed a dozen real findings
(empty `place_level_rows`, card-view DnD guards, deleted-children
*counts*, etc.). This review is the leftover.

---

## Findings

### 1. BUG - HIGH — Oban PDF retries were dead *(fixed)*

`fail/2` called `mark_failed` then returned `{:error, _}`. `perform/1`
treated `"failed"` as a success terminal, so attempt 2 returned `:ok`
and attempt 3 never ran. `mark_extracting/1` also refused `"failed"`,
so even a retry that reached `run/1` would no-op as `:superseded`.

`max_attempts: 3` only helped uncaught exceptions (those leave the row
`extracting`).

**Fix:** success terminals are `extracted` / `scanned_no_text` only.
`mark_failed` runs on the last attempt. `mark_extracting` accepts
`failed`. `success_terminal?/1` is pinned.

### 2. BUG - HIGH — `finalize/2` acked the job when the status write failed *(fixed)*

`_ = PdfLibrary.mark_extracted(...)` then `:ok`. A vanished row left
pages in the cache, the extraction stuck at `extracting`, and Oban
would not retry. Errors now propagate.

### 3. BUG - HIGH — `page_count == 0` was a successful extraction *(fixed)*

pdfium "opens" almost any `%PDF` header. A 0-page open skipped the
all-pages-failed clause (`failed == []`) and stored `extracted` with
`page_count: 0`. Retry then returned `:already_extracted`.

**Fix:** both engines treat `n <= 0` as an open failure (and pdfium
closes the handle) so the chain can fall through to poppler.

### 4. BUG - MEDIUM — create/move positions ignored the other type *(fixed)*

Display order is one interleaved `{position, type, name}` sequence.
`front_folder_position/1` and `next_catalogue_position_in_folder/1`
only looked at their own table. Filing a catalogue into a folder-only
level assigned position 1 and landed next to the first folder, not at
the end. New helpers `next_level_position/1` / `front_level_position/1`
use min/max of both types. `create_catalogue` appends on its target
level, not the global catalogue max.

### 5. BUG - MEDIUM — issue #56 lock did not cover every writer *(fixed)*

Only `reorder_catalogues` / `reorder_folders` / `place_level_rows`
took `pg_advisory_xact_lock`. Create, move, restore, and
`delete_empty_folder` did not — and the last one is the race the
atomic `NOT EXISTS` delete claimed to close (READ COMMITTED does not
re-check `NOT EXISTS` when a child insert does not touch the folder
row; `ON DELETE SET NULL` would silently unfile the new occupant).

Every membership/position writer now takes the same lock. The LV drop
is still two transactions (move, then place); a failed place can leave
the row in the new parent. Not combined in this pass — the lock
serialises the two, it does not make them atomic.

### 6. BUG - MEDIUM — `place_level_rows/2` trusted a forgeable list *(fixed)*

Unknown types (`{"item", uuid}`) raised `FunctionClauseError` inside
the transaction and crashed the LiveView. Mixed-level payloads
rewrote positions on another parent. Context now returns
`:invalid_entry` / `:not_siblings` and the test pins `1,2,3`.

### 7. BUG - MEDIUM — `category_uuids_with_children(:deleted)` was unfiltered *(fixed)*

The numeric `category_children_counts/2` was corrected in the PR; the
chevron query was left as `:deleted -> query`. Restore is
non-cascading, so a deleted parent with only an active child showed a
subcategory affordance whose child list was empty.

### 8. IMPROVEMENT - HIGH — extra broadcasts doubled every drag reload *(fixed)*

`log_activity/1` already broadcasts. The three reorder writers then
broadcast again. `CataloguesLive.handle_info` reloads on both
`:catalogue` and `:folder` and does not ignore `self()`, so every
successful drag `load_data`d 2–3 times on every open tab, including
the originator. Extra broadcasts removed; `place_level_rows` now logs
the first entry's actual resource type.

### 9. IMPROVEMENT - HIGH — new atoms/actions missed the repo pins *(fixed)*

`:not_empty`, `:cycle`, `:folder_not_found`, `:folder_trashed`,
`:invalid_entry` now have `Errors.message/1` + `errors_test.exs`.
`folder.deleted`, `folder.permanently_deleted`,
`catalogue.level_reordered` are pinned in `activity_logging_test.exs`.

### 10. IMPROVEMENT - MEDIUM — AGENTS.md still said folders are soft-delete only *(fixed)*

Deliberate product change, not a slip. Docs updated. Dual API
(`trash_folder` / `permanently_delete_folder`) kept for legacy trashed
rows.

### 11. IMPROVEMENT - LOW — `new_subfolder` skipped the parent lookup *(fixed)*

`new_folder` validates `folder_lookup`; `new_subfolder` passed the
client uuid straight through.

### 12. NITPICK — `normalize/1` missed `\\r\\n` hyphenation *(fixed)*

`Pre-\r\nmium` now unfolds the same way as `Pre-\nmium`.

### 13. NITPICK — ViewConfig comment still said "only the catalogues index" *(fixed)*

`@global_sort_scopes` already included detail items/categories.

### 14. BUG - HIGH — “Reorder all” smashed interleaved folder order *(fixed)*

The modal + `reorder_catalogues` reindexed every catalogue `1..N`
globally. In structure mode the display sort is the interleaved
per-level sequence, so A→Z undid every `drop_row`. The handler also
allowed the event whenever `catalogues_structure_mode?` was true.

**Fix:** hide the button in structure mode; the handler only runs for
the flat unfiltered list (`manual_order_draggable?` and not structure).

### 15. BUG - HIGH — detail column editor clobbered the other scope *(fixed)*

`ViewConfig.save/3` rewrites the whole `custom_fields` JSON from the
socket’s user snapshot. `CataloguesLive.put_cfg/3` already refreshes
`phoenix_kit_current_user`; the detail page did not. Hiding a column on
items then adding one on categories reverted the items change on
reload.

### 16. BUG - MEDIUM — stale folder filter emptied the index after PubSub *(fixed)*

`load_data(:index)` rebuilt `folder_lookup` but left `filters["folder"]`
pointing at a deleted/missing folder. Structure mode then hid, and the
flat filter matched nothing.

### 17. IMPROVEMENT - MEDIUM — picker browse-on-reopen false-positive *(fixed)*

`query == selected name` also fired after a typed search that returned
`[]`. An explicit `searched?` flag (set on `query_change`, cleared when
the parent remounts a selection) keeps browse for the remount case and
retries the typed query otherwise.

### 18. IMPROVEMENT - LOW — drop `parent` UUID cast, gettext titles, deleted badge

Non-UUID `parent` would `CastError` the LV. View-switcher titles now
go through gettext. The deleted category chip uses the existing
`Deleted` msgid. Cross-tab sort `dir` is coerced to `:asc | :desc`.

---

## Left open (documented, not fixed)

- **pdfium is in-process C++.** A native fault kills the BEAM. Accepted
  in the PR because uploads are admin-only. Isolation (Port / node)
  is the right next step if PDFs ever become public.
- **`ex_pdfium ~> 0.6` has no musl/Alpine or Windows precompiled
  artifact.** `mix compile` on Alpine tries a source NIF build and
  fails without rustc. The "zero system packages" claim is
  glibc-Linux + macOS.
- **`System.cmd` for poppler has no timeout.** A wedged `pdfinfo`
  pins the Oban process.
- **Drop is still two transactions.** Combine move + place under one
  lock if a failed place-after-move shows up in the wild.
- **Partial extraction + all-blank surviving pages** still becomes
  `scanned_no_text` and refuses retry. Rare.

---

## Gate

Post-merge fixes plus `mix precommit`. Version bumped to **0.16.0**
(Hex was already at 0.15.1; this is a feature release).
