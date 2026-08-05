# Review — PR #49: Put the catalogue list search and filters in the URL

Merged as `3377b9e` (`e0c0240` + `f5643f0`, author @timujinne). Reviewed against
the Phoenix thinking skill and cross-checked line-by-line against the
`PhoenixKitWeb.Live.UrlState` source in the pinned `phoenix_kit` (1.7.208,
`deps/phoenix_kit/lib/phoenix_kit_web/live/url_state.ex`).

**Overall: correct, and it follows the module's contract closely.** Every rule
`UrlState`'s moduledoc lays out for an `@impl`-annotating LiveView is honoured —
declared assigns removed from `mount/3` (UrlState's `on_mount` assigns them
before `mount` runs, so leaving them would have clobbered the decoded values),
an explicit `@impl true def handle_params(_params, _uri, socket)` stub in each
of the three modules rather than letting `__before_compile__` inject an
un-annotated one, `cast: :string` + `in:` on the one whitelist param, and
`replace: true` on the debounced search boxes but not on the discrete filter
click. The `:patch`-vs-`:history` trap doesn't apply: all three LiveViews are
router-mounted through `admin_tabs/0`, and all three already exported
`handle_params/3` before this PR, so nothing became un-embeddable that wasn't
already.

The load-shedding is the good part. `handle_url_state/2` fires once per debounce
pause, and both screens that would otherwise re-query on every one of those
gate on a structural change instead — `prior_filter` on the PDF library,
`prior_category_uuid` on the detail page. `f5643f0` is that fix for the PDF
screen after `e0c0240` regressed it, and it is the right shape: `list_pdfs/1`
returns a byte-identical row set for a search change, because the search is
applied client-side by `filter_by_search/2` at render.

Four findings, three fixed. Nothing here is a data-integrity or security issue.

---

## 1. BUG - MEDIUM — an empty `?category=` leaves `""` in the assign, mangling DOM ids and re-writing itself into the URL — fixed

`CatalogueDetailLive.handle_url_state/2` normalized the incoming value into a
local (`cat_key = normalize_category_key(state.current_category_uuid)`) and
branched on that, but left `@current_category_uuid` holding whatever UrlState
decoded. Those diverge for `?category=` with an empty value: `decode/2` finds
the key, `cast_value/2` runs it through `validate_allowed(_, %{allowed: nil})`
and returns `""` verbatim, so the assign is `""` while every branch in the
module treats the level as root (`normalize_category_key("")` → `nil`).

Two consequences, both real:

- `catalogue_detail_live.ex:2683,2824` build the item-list DOM ids as
  `"items-bulk-" <> (@current_category_uuid || "root")`. `""` is truthy in
  Elixir, so the ids come out `items-bulk-` / `items-body-` instead of
  `items-bulk-root` / `items-body-root`. Still unique, but the `phx-update`
  container ids stop matching what every other code path produces for the root
  level.
- `push_url_state/3` reads its merge base back from the *assigns*, not from the
  bookkeeping state map (`current_state/2`, and the moduledoc's "Setting a
  declared param outside an event" section explains why). `"" != nil`, so
  `encode/3` does not drop it — the empty `?category=` is faithfully re-written
  into the URL on every subsequent search patch.

**Fixed** by writing the normalized key back over the raw one, unconditionally,
before the change detection. UrlState explicitly documents a plain `assign/3` on
a declared param as supported precisely so that the freshest value wins and the
URL catches up. Pinned by `test/web/catalogue_detail_live_test.exs` — "an empty
`?category=` normalizes to the root level", which asserts both the `items-body-root`
id and that the next search patches to `?q=oak` with no `?category=` in it.

## 2. BUG - MEDIUM — search results could be stranded on screen with no way to clear them — fixed

New behaviour introduced by this PR. Before it, a node change always ran
`clear_search/1`, so a search could only ever exist in a view the user had
navigated into by hand — and `view_mode` is always `"active"` there, because
the status-tab strip that switches it is hidden while results are showing
(`catalogue_detail_live.ex:2038` gates on `is_nil(@search_results)`). Now `?q=`
survives the level load, which opens a path that couldn't previously be reached:

1. Deep-link (paste, bookmark, Back) `?category=<uuid>&q=<term>` into a node
   whose Active tab is empty but which has trashed items.
2. `load_url_state_level/3` resolves the node, runs the search, then
   `reset_and_load/1` → `load_level/2` calls
   `effective_view_mode("active", status_counts)`, which — finding Active
   empty — settles the level on `"deleted"`.
3. The search results render (`:if={@search_results != nil or @search_loading}`),
   but `<.search_input>` was gated on `:if={@view_mode == "active"}`, so both
   the box and its clear button are gone. The context search excludes deleted
   rows, so the results are typically the "No items match your search." empty
   state — with no visible control to escape it. Only editing the URL gets out.

**Fixed** in the template: the input now also renders whenever a search is on
screen (`@view_mode == "active" or @search_results != nil or @search_loading`).

I deliberately did *not* fix this by forcing `view_mode` back to `"active"`
when a query is present, which was the other candidate. That would leave
`view_mode` disagreeing with the level data `load_level/2` actually loaded for
the `"deleted"` status, so clearing the search would drop the user onto an
Active-labelled view rendering deleted-tab rows — trading a narrow dead end for
a wider inconsistency. Nor did I clear the search on a non-active landing:
silently discarding a `?q=` the user explicitly asked for is worse than showing
it. Pinned by "the search input stays reachable when the level lands on a
non-active tab".

## 3. IMPROVEMENT - MEDIUM — `CataloguesLive`'s `tab_changed?` guard is load-bearing on the tab links being `navigate`, and the comment above it described behaviour that never existed — comment corrected, behaviour pinned by tests

The guard itself is correct *today*, and I left it alone. But it is correct for
a reason nothing in the file stated, and it fails silently if that reason ever
changes:

`handle_url_state/2` calls `load_data/2` only when `live_action != @active_tab`.
The three tabs are separate routes reached through PhoenixKit's `tab_item`,
which renders non-external tabs with `<.link navigate={@path}>`
(`deps/phoenix_kit/lib/phoenix_kit_web/components/dashboard/tab_item.ex:116`,
and `:266` for the mobile variant). `navigate` re-mounts, so `prev_tab` is `nil`
on the one call that matters and the guard always opens. Were those links ever
switched to `patch`, `UrlState.reload?/3` would short-circuit on the *declared*
state being unchanged (`?q=` empty on both sides → `reload?(true, state, state)`
→ `false`), `handle_url_state/2` would not run at all, and the new tab would
render the previous tab's `active_tab`, `page_title` and rows. That's a
whole-page wrong-content failure with no error anywhere.

Also, the comment block asserted a behaviour change that didn't happen —
"previously each tab remembered its own search string when you switched away".
It didn't: tab switches have always re-mounted, so the per-scope `:search` in
`view_configs` was discarded either way. `ViewConfig.save/3` serializes an
explicit key list that has never included `:search`, so it was never persisted
across mounts either.

**Applied:** replaced the comment with the actual invariant and the failure mode
if it breaks, and added two tests — `?q=` applying to whichever tab the route
selected, and a search patch leaving `active_tab` / `page_title` / the loaded
rows intact (the assigns `tab_changed?` guards `load_data` out of).

## 4. BUG - HIGH (pre-existing, outside this PR's diff) — `mix test` aborted outright on any machine without `psql` — fixed

Not introduced here, but it is why the last three CHANGELOG entries all carry
some version of "`mix test` could not be run in this environment (`psql` is not
installed, not just DB-unavailable)", and it meant this PR's own behaviour
changes had no way of being verified locally.

`test/test_helper.exs:26` probed for the test database with
`System.cmd("psql", ["-lqt"], stderr_to_stdout: true)` inside a `case` whose
fallback clause is `_`. But `System.cmd/3` **raises** `ErlangError :enoent` when
the binary isn't on `PATH` — it never returns a tuple to fall through on. So a
machine with no libpq client aborted the whole run before a single test loaded,
rather than taking the documented path of excluding `:integration` and running
everything else. AGENTS.md states integration tests "are automatically excluded
when no database is available"; they weren't.

**Fixed** by probing with `System.find_executable("psql")` first and
substituting a non-zero result, which lands on the existing `:try_connect`
branch and from there on the existing exclusion notice. `mix test` now completes
here: **525 tests, 0 failures, 787 excluded**.

---

## Verified as correct (checked, no change needed)

- **`PdfLibraryLive`'s `prior_filter` guard.** `assign_pdfs/1` reads
  `socket.assigns.filter`, which `UrlState.apply_state/2` has already written
  from the decoded state before invoking the callback (`assign_state/3` runs
  ahead of `socket.view.handle_url_state/2`), so the reload always uses the new
  filter and never the stale one. `prior_filter` being unset on the first call
  is safe: the param is whitelisted to `"active"`/`"trashed"` and can never
  decode to `nil`, so the first call always reloads.
- **Dead-render / connected-render bookkeeping.** All three screens set their
  `prior_*` marker on the disconnected render too, which looks like it would
  suppress the connected render's load. It doesn't — those are separate
  processes, and each guards its actual query on `connected?/1` internally.
- **`?category=` deep-linking still bounces invalid UUIDs.** `resolve_node/2`
  runs before the level load and `:invalid` still flashes + patches to root; the
  `prior_category_uuid` recorded for the invalid key is corrected by the patch
  that follows (root `nil` ≠ the bogus UUID, so the callback re-runs and loads).
- **No new query-per-keystroke.** `CatalogueDetailLive` still issues exactly one
  `start_async(:search, …)` per debounce pause (the event pushes, the patch
  calls back, the callback searches), and its `resolve_node/2` category lookup
  is now *skipped* on a search-only change — a small improvement over the
  pre-PR `handle_params`, which re-resolved on every call.
- **Drill links correctly drop `?q=`.** `Paths.category_browse/2` and friends
  hand-build `?category=…` rather than going through `url_state_path/2`, so
  drilling clears the search — matching pre-PR behaviour. Worth knowing that
  this also drops any unrelated query key UrlState would otherwise preserve;
  fine today, since nothing else patches these routes.
- **`:search` never reaches the users table.** `handle_url_state/2` writes the
  query into `view_configs[scope]`, and the sort/column/view events pass that
  same map to `put_cfg/3` → `ViewConfig.save/3` — which serializes a fixed key
  list (`columns`, `sort_by`, `sort_dir`, `filters`, `view`). The transient
  search cannot leak into `custom_fields`.

## Known limitations (deliberately not addressed)

- **`view_mode` (Active / Deleted / Inactive / Discontinued) is still not in the
  URL** on the detail page, and neither are the table stack's sort, column and
  filter selections on the index (those persist per user via `ViewConfig`
  instead). So a shared detail-page link still doesn't fully reproduce what the
  sender was looking at. Extending the spec is cheap — `view_mode` is already a
  four-value whitelist — but it interacts with `effective_view_mode/2`'s
  auto-pick and with `maybe_auto_flip_to_active/1`, so it wants its own change
  with its own tests rather than being bolted on during a review.
- **The `?q=` round-trip tests added here are `:integration`-tagged** and need
  Postgres, which was unavailable in this environment. They are written against
  the existing `LiveCase` conventions and the assertions are mechanical
  (`assert_patch/2` on the built path, substring checks on rendered rows), but
  they have not been executed. Get a Postgres-backed CI run before treating the
  URL round-trip as verified — finding 4 at least makes that run possible now.

## Verification

- `mix precommit` — clean: `compile --force --warnings-as-errors`,
  `deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`,
  `credo --strict` (2121 mods/funs, no issues), `dialyzer` (9 errors, all 9
  skipped by `.dialyzer_ignore.exs`, 0 unnecessary skips).
- `mix test` — 525 tests, 0 failures, 787 excluded (`:integration`, no local
  Postgres).
- `mix precommit` also required pruning eight orphaned `mix.lock` entries
  (`ex_ast`, `glob_ex`, `igniter`, `owl`, `rewrite`, `sourceror`, `spitfire`,
  `text_diff`) left behind by the dependency bump in `242bad9`; confirmed
  pre-existing by re-running the check against a stashed tree. No `mix.exs`
  constraints touched.
