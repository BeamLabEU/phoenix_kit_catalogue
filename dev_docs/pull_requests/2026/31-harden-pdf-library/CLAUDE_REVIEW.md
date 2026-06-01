# Review — PR #31: Harden PDF library (viewer fallback, extraction self-heal, bulk-bar fold)

Merged as `4be72df`. Reviewed against the Elixir/Oban/Ecto/Phoenix thinking skills.

**Overall:** strong, well-documented, defensively-written change. The guarded
status transitions (`UPDATE ... WHERE status IN (...)`), the app-side Oban dedup
that sidesteps the `:suspended` enum trap, and the honest `%{requeued, failed}`
counts are all the right calls. Tests pin the important invariants. The notes
below are improvements *we* can make on top of it — nothing here blocks.

---

## 1. `requeued` count still over-reports skipped rows (honesty gap) — **medium**

`requeue_stuck_extractions/1` buckets every non-`{:error, _}` return as
`requeued`:

```elixir
case enqueue_extraction(file_uuid) do
  {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
  _ok              -> Map.update!(acc, :requeued, &(&1 + 1))
end
```

But `enqueue_extraction/1` returns a **bare `:ok`** in two no-op cases:

- the app-side dedup found a live job already covering the file
  (`insert_extraction_job/1` → `extraction_job_pending?/1` true), and
- the worker module isn't compiled in.

Only `do_insert_extraction_job/1` returns `{:ok, %Oban.Job{}}` for an *actual*
enqueue. So a stale `extracting` row whose original job is still `executing`
gets counted as "re-queued" even though we touched nothing — and the docstring
explicitly promises `requeued` is "the number of rows whose extraction job was
(re-)enqueued." This is exactly the kind of dishonest count commit `28df92c`
set out to kill; it just left this seam.

**Fix** — distinguish the genuine insert from the skip and add a `skipped`
bucket (or fold it into the flash text):

```elixir
case enqueue_extraction(file_uuid) do
  {:ok, %Oban.Job{}} -> Map.update!(acc, :requeued, &(&1 + 1))
  {:error, _}        -> Map.update!(acc, :failed, &(&1 + 1))
  _ok                -> Map.update!(acc, :skipped, &(&1 + 1))  # live job already exists
end
```

The library LV's `flash_requeue_result/3` would gain a "already running" arm.

---

## 2. The requeue loop is O(rows) round-trips — batch it — **medium (scale)**

`requeue_stuck_extractions/1` selects up to `@requeue_cap` (1000) file_uuids,
then for **each** one calls `enqueue_extraction/1`, which does:

1. `Oban.config()` read (cheap, but re-done every iteration), then
2. `extraction_job_pending?/1` — an `exists?` against `oban_jobs` filtered by
   `args ->> 'file_uuid' = ?` (a JSON expression with **no index**, so a seq
   scan per call), then
3. an `Oban.insert/1`.

That's up to ~1000 seq scans + 1000 individual inserts on one admin click.
Concrete improvements, cheapest first:

- **Hoist the queue check** out of the loop — `catalogue_pdf_queue_available?`
  / `Oban.config()` only needs to run once per call.
- **Pre-fetch the live-job set in one query** instead of one `exists?` per row:
  `SELECT args->>'file_uuid' FROM oban_jobs WHERE worker = ? AND state IN (...)
  AND args->>'file_uuid' = ANY(?)`, build a `MapSet`, then enqueue only the
  rows not in it.
- **`Oban.insert_all/1`** the survivors in one shot rather than N inserts.

The per-upload and single-Retry paths can keep the simple `enqueue_extraction/1`
— this is only about the bulk path.

---

## 3. No index backs `extraction_job_pending?/1` — **low (infra)**

Related to #2: the dedup lookup `j.args ->> 'file_uuid'` will seq-scan
`oban_jobs` on hosts with a busy queue. If we keep the per-row check, a partial
expression index makes it O(log n):

```sql
CREATE INDEX CONCURRENTLY oban_jobs_catalogue_pdf_file_uuid_idx
  ON oban_jobs ((args ->> 'file_uuid'))
  WHERE worker = 'PhoenixKitCatalogue.Workers.PdfExtractor'
    AND state IN ('available','scheduled','executing','retryable');
```

Optional — only worth it once the corpus / job table is large.

---

## 4. `retry_extraction/2` is unguarded against success-terminal rows — **low**

The context function resets the row to `pending` and clears `error_message`
**unconditionally** via `update_extraction/2`. The docstring acknowledges the UI
only offers Retry on `failed` rows, but `Catalogue.retry_extraction/2` is public
and reachable (RPC, future caller, a programmatic admin tool). Calling it on an
`extracted` row silently drops that PDF out of search until the re-extract
finishes. Cheap belt-and-braces: short-circuit when already in a success
terminal unless an explicit `force: true` opt is passed, or at least restate the
caveat at the `Catalogue` delegation site.

---

## 5. Iron-law: DB queries in `mount/3` (pre-existing, not from this PR) — **low**

Both `PdfLibraryLive.mount/3` (`Catalogue.list_pdfs/1`) and
`PdfDetailLive.mount/3` (`load_pdf/1`) query the DB in `mount`, which runs twice
(dead HTTP render + live socket connect) → the query runs twice on first load.
Neither is URL-param-driven, so the textbook fix is to seed empty/loading
assigns in `mount` and load in `handle_params/3` (detail already has one;
library has none). Pre-existing pattern across the catalogue LVs — noting for a
future consistency sweep, not for this PR.

---

## 6. `extraction_badge/1` hand-builds HTML — **low (style)**

`PdfLibraryLive.extraction_badge/1` concatenates a `<span>` string and wraps it
in `Phoenix.HTML.raw`, leaning entirely on `Helpers.escape_html/1` for safety.
It works, but a small `~H` function component (`<span class={klass}
title={msg}>{label}</span>`) gets auto-escaping and readability for free and
drops the manual `escape_html` calls. Pre-existing style choice; low priority.

---

## Nits

- `import Ecto.Query, warn: false` in `pdf_library.ex` — the module clearly uses
  `from/2` everywhere, so `warn: false` shouldn't be masking anything now; worth
  confirming it's still needed.
- The worker allows two concurrent jobs on the same `file_uuid` to *both* run
  (both pass the terminal short-circuit, both pass the
  `["pending","extracting"]` guard for `mark_extracting`). It's safe — page
  inserts are upserts and the moduledoc says so — but it means the app-side
  dedup is the *only* thing preventing duplicate extraction work; #1/#2 keep
  that path honest and cheap.

---

## Suggested order

1 (honest count) and 2 (batch the loop) are the two with real payoff and are
self-contained. 3–6 are optional polish.

---

## Implementation status — all 6 applied

- **#1 honest count** — `requeue_stuck_extractions/1` now returns
  `%{requeued, skipped, failed}`; only a genuine `Oban.insert_all` counts as
  `requeued`. `PdfLibraryLive.flash_requeue_result/2` gained a "N already
  running" arm.
- **#2 batch the loop** — selection is de-duped against live jobs in one query
  (`live_extraction_job_file_uuids/1`) and enqueued with one
  `Oban.insert_all/1`; queue-availability is checked once, not per row.
- **#3 index** — `oban_jobs` is core/host-owned and this repo ships no
  migrations, so this is **documented**, not migrated: a code comment on
  `extraction_job_pending?/1` and a tracked perf note in `AGENTS.md` give the
  exact `CREATE INDEX` for a future core `phoenix_kit` migration.
- **#4 retry guard** — `retry_extraction/2` refuses a success-terminal row with
  `{:error, :already_extracted}` unless `force: true`. Docstring + tests added.
- **#5 mount query** — `PdfLibraryLive` moves the `list_pdfs` query from `mount`
  into `handle_params/3` (gated on `connected?` so the dead render does no
  query) and now honors a `?filter=` deep-link. `PdfDetailLive` left as-is by
  design: its single cheap `get_pdf` + not-found redirect must stay in `mount`
  for the `:live_redirect` test semantics.
- **#6 badge** — `extraction_badge/1` is now a `~H` function component with
  auto-escaping instead of `Phoenix.HTML.raw` string concat.

**Verification:** `mix compile --warnings-as-errors` clean, `mix format` clean,
`mix credo --strict` clean (105 files, 0 issues). The DB-gated test suite
(`pdf_library_test.exs`, `pdf_library_live_test.exs`) couldn't run in the review
sandbox (no `psql`); new tests cover the `:already_extracted` guard, the `force`
override, and the `skipped` count key.
