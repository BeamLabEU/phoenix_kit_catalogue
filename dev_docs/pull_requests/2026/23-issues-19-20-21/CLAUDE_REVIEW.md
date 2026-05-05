# PR #23: Close #19/#20/#21 + #16/#17 housekeeping — preload opt, evaluate_smart_rules, category_summary

**Author**: @mdon (Max Don)
**Reviewer**: @fotkin (Dmitri)
**Status**: Merged
**Merge commit**: `94fe469` (content: `278c283`)
**Date**: 2026-05-05
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/23

## Goal

Three issue-driven additions plus housekeeping for two already-shipped
items:

1. **#19 — `:preload` opt on bulk fetchers + `list_items_by_uuids/2`.**
   Threads a `:preload` option through every list/get path in the
   `Catalogue` module so consumers can request smart-pricing
   preloads (`[catalogue_rules: :referenced_catalogue]`) without
   reaching for `Repo.preload/2`. New `list_items_by_uuids/2`
   gives order-preserving snapshot rehydration in one query.

2. **#20 — public `Catalogue.evaluate_smart_rules/2`.** The package
   now owns the canonical smart-pricing algorithm. Previously
   consumers were directed to the 100-line reference implementation
   in `guides/smart_catalogues.md` and asked to copy-paste it; now
   they call one function with one consumer-policy injection point
   (`:line_total` lambda).

3. **#21 — `Catalogue.category_summary_for_catalogue/2`.**
   Combines three lazy-load primitives that consumers always called
   together (categories metadata, per-category counts, uncategorized
   count) into one call, two queries.

4. **#16 / #17 — housekeeping closures.** Both shipped in PR #18
   (merged 2026-04-27, released in 0.1.14) but didn't auto-close on
   GitHub. Closing here.

Pairs with `BeamLabEU/phoenix_kit#515` — companion PR shipping
`PhoenixKit.Migration.ensure_current/2`, which the new test_helper
calls. Until 1.7.105 ships, the test_helper falls into its rescue
branch and integration tests are excluded.

## What Was Changed

10 files, +1205 / −176.

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue.ex` | `+187 / −59`. `:preload` opt threaded through `list_items_for_category/2`, `list_items_for_catalogue/2`, `list_uncategorized_items/2`, `list_items_for_category_paged/2`, `list_uncategorized_items_paged/2`, `get_item/2`, `get_item!/2`. New `list_items_by_uuids/2` (order-preserving, soft-delete excluded, deduped). New `category_summary_for_catalogue/2` returns `%{categories:, item_counts:, uncategorized_count:}` in two queries. New `apply_summary_mode/2` private helper. `evaluate_smart_rules/2` defdelegate to `SmartPricing`. |
| `lib/phoenix_kit_catalogue/catalogue/smart_pricing.ex` | **New** (181 lines). Public smart-rules evaluator. Pure function over `[%{item:, qty:}]` lists; standard entries pass through, smart items get `:smart_price` written. Loud `ArgumentError` raises when `:catalogue` or `:catalogue_rules` is `%NotLoaded{}`. `:line_total` lambda is the single consumer-policy injection point; default is `base_price × qty`. `:write_to` configures the output key (default `:smart_price`). |
| `lib/phoenix_kit_catalogue/catalogue/helpers.ex` | `+13 lines`. New `merge_preloads/2` — `defaults ++ Keyword.get(opts, :preload, [])`. Single source of truth (was duplicated in `catalogue.ex` + `search.ex` per the original `:preload` landing). |
| `lib/phoenix_kit_catalogue/catalogue/search.ex` | `+8 / −4`. `search_items/2` and `search_items_in_catalogue/3` now thread `:preload` via `Helpers.merge_preloads/2`. |
| `guides/smart_catalogues.md` | `+76 / −72`. §4 rewritten — old 100-line reference impl deleted, replaced with a `Catalogue.evaluate_smart_rules/2` call site + `:line_total` / `:write_to` customization examples. §5 (preload pitfall) updated to point at the new `:preload` opt. |
| `test/catalogue_test.exs` | `+274 lines`. Two new describe blocks: `:preload opt on bulk fetchers (issue #19)` (8 tests covering the non-paged variants + a `:preload` collision pin) and `list_items_by_uuids/2 (issue #19)` (7 tests: order, missing UUIDs, soft-delete, dedupe, empty input, default preloads, merge with `:preload`). New `category_summary_for_catalogue/2` tests (2). |
| `test/smart_pricing_test.exs` | **New** (451 lines). Pure-function unit coverage of every algorithm branch — pass-through, percent rules, flat rules, mixed, value inheritance, no-rules, missing ref catalogue, unknown unit, nil base_price, smart-don't-contribute-to-ref-sums, qty type variance (int/Decimal/float), preload guards, `:write_to`, `:line_total`. All cases run with in-memory structs, no DB sandbox, `async: true`. |
| `test/smart_catalogues_guide_test.exs` | `+19 / −86`. Inline `Apply` reference module deleted. The guide test now calls `Catalogue.evaluate_smart_rules/2` exactly the way the guide tells consumers to — making this the integration test for the public surface. Loads items via the new `list_items_by_uuids/2` to mirror the documented snapshot-rehydration shape. |
| `test/test_helper.exs` | `+11 / −15`. Switches schema setup from `Ecto.Migrator.run([{0, PhoenixKit.Migration}])` to `PhoenixKit.Migration.ensure_current/2`. Comment block captures the bug story. |
| `AGENTS.md` | `+2 / −2`. Test-setup section updated to reference `ensure_current/2`. |

## PR-Specific Findings

### Solid

1. **Loud preload guards in `evaluate_smart_rules`.** The `%NotLoaded{}`
   raises (`smart_pricing.ex:127-132` and `:140-143`) catch what would
   otherwise be silent-zero pricing or a deep `Decimal` math
   `FunctionClauseError`. The hint message points at the bulk-fetcher
   `:preload` opt that just landed — closing the loop between the new
   error and the new ergonomic. Right call to make this a hard raise:
   smart-pricing on a missing assoc would be a billing bug.

2. **`list_items_by_uuids/2` shape.** Order-preserving, dedupe via
   `Enum.uniq()`, soft-delete excluded at the SQL layer, `nil` results
   collapsed via `Enum.flat_map`. The `Map.new(&{&1.uuid, &1})` plus
   `flat_map` flow keeps it O(n) without N+1 — and the early-return
   for `[]` (`catalogue.ex:2510`) skips a useless `WHERE … IN ()` round
   trip. Snapshot rehydration is exactly what consumers (orders, saved
   carts) reach for, and the doc framing makes the use case explicit.

3. **Guide §4 rewrite is the right call.** Replacing a 100-line
   copy-paste reference with `Catalogue.evaluate_smart_rules(entries)`
   eliminates the drift class entirely — there's no longer a "the guide
   has its own version, the test pins it, hope they stay in sync"
   maintenance contract. The `Apply` module deletion in
   `smart_catalogues_guide_test.exs` follows naturally: the guide test
   is now an integration test for the public function, not a parallel
   implementation.

4. **`smart_pricing_test.exs` shape.** Pure-function unit coverage with
   in-memory `%Item{}` / `%CatalogueRule{}` / `%CatalogueSchema{}` —
   no sandbox, `async: true`, every branch covered (percent / flat /
   unknown unit / NULL inheritance / NotLoaded / custom `:line_total`
   / custom `:write_to` / smart-don't-contribute-to-ref-sums). The
   `_, out_b]` assertion in the smart-don't-contribute test
   (`smart_pricing_test.exs:330-339`) is particularly clean — it pins
   the algorithm's most subtle invariant without needing any DB shape.

5. **`merge_preloads/2` extraction to `Helpers`.** Was duplicated in
   `catalogue.ex` and `search.ex` per the earlier `:preload` landing.
   Single source of truth, follows the same de-dupe convention as
   `item_catalogue_uuid/1` from PR #13. The `:preload collision`
   test (`catalogue_test.exs:2065`) is a particularly thoughtful
   addition — it pins Ecto's bare-atom-vs-nested-keyword merge
   behavior so a future Ecto upgrade that changes the semantics
   surfaces here, not in production.

6. **`category_summary_for_catalogue/2` query shape.** Two queries
   (categories metadata + a single `GROUP BY` on items) replaces the
   three-roundtrip pattern lazy-load consumers had. The
   `Enum.reduce` over rows builds both `:item_counts` and
   `:uncategorized_count` in one pass, keying on the `nil` row for
   uncategorized. Empty categories simply don't appear in the map
   — the doc tells consumers to treat missing keys as 0, which
   matches the existing `item_counts_by_category_for_catalogue/2`
   contract.

7. **`get_item!/2` default-preload widening was a real fix, not a
   gotcha.** The arity-1 form was silently missing `:catalogue` —
   PR #18's smart→smart guard work needed it; old call sites that
   wanted it were doing their own `Repo.preload(item, :catalogue)`
   afterward. Default `[:catalogue, :category, :manufacturer]` is
   the right shape now. PR description correctly flags it as a
   per-call extra query for callers that don't access `.catalogue`.

8. **Test `:preload` collision pin is auditable contract pinning.**
   The test at `catalogue_test.exs:2065-2079` deliberately exercises
   the bare-atom + nested-keyword collision — `[:catalogue, ...]`
   default + caller's `[catalogue: :categories]`. Asserts both load.
   Comment explains the rationale ("a future Ecto upgrade that
   changes the merge semantics surfaces here"). This is exactly the
   kind of test that pays for itself once.

### Minor concerns

1. **MEDIUM: Integration tests are dark on main against the current
   Hex pin.** `test/test_helper.exs:65` calls
   `PhoenixKit.Migration.ensure_current/2`, which doesn't exist in
   `phoenix_kit 1.7.103` (pinned in `mix.lock`). The companion PR
   `BeamLabEU/phoenix_kit#515` ships it in 1.7.105.

   The `rescue e ->` clause at `test_helper.exs:69-77` catches the
   `UndefinedFunctionError` and prints "⚠ Could not connect to test
   database — integration tests will be excluded." Two problems:

   - **Wrong diagnosis.** It's not a connection error, it's a
     missing function. Anyone running `mix test` on main between now
     and 1.7.105's release will be nudged toward `mix test.setup`,
     which fixes nothing.
   - **Future regressions hide.** Today this rescue is correct-by-
     accident for the version-skew window. Tomorrow it will silently
     swallow real breakage in `ensure_current/2` — a regression in
     core would ship a green CI with all 584 `:integration` tests
     excluded (per the PR's own test plan: 909 ran, 584 excluded).

   **Suggested fix:** narrow the rescue to catch
   `DBConnection.ConnectionError` / `Postgrex.Error` only, and let
   `UndefinedFunctionError` propagate so the version mismatch is
   loud. Or pin a `phoenix_kit` git/path dep until 1.7.105 lands.
   As-is, ~64% of the test suite is dark on main.

2. **LOW: `merge_preloads/2` doc contradicts the new test contract.**
   The docstring at `catalogue/helpers.ex:96-106` says:

   > Callers passing nested specifications (e.g. `catalogue:
   > :categories`) on a key already present as a bare atom should
   > know what they're doing — Ecto silently prefers the nested spec.

   But the new pinning test at `catalogue_test.exs:2065-2079`
   asserts the *opposite* — that **both** the bare-atom load and
   the nested child load happen:

   ```elixir
   item = Catalogue.get_item!(smart_item.uuid, preload: [catalogue: :categories])
   assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
   assert is_list(item.catalogue.categories)
   ```

   Update the docstring to match what the test pins ("Ecto merges
   the bare and nested forms — parent loads, plus the nested
   child"), or flip the test if the doc was the intended contract.
   Right now they disagree, and the test is more recent.

3. **LOW: Paged fetchers got `:preload` threading but no test
   coverage.** `list_items_for_category_paged/2` (`catalogue.ex:786`)
   and `list_uncategorized_items_paged/2` (`catalogue.ex:819`) accept
   `:preload` and run it through `Helpers.merge_preloads/2`, but
   there are no tests under `:preload opt on bulk fetchers (issue
   #19)` pinning either function — the seven sibling tests cover
   the non-paged variants only. Code follows the same pattern as
   `list_items_for_category/2`, so it's almost certainly correct,
   but a future refactor that loses the merge in just the paged path
   would ship green. Two extra `assert` lines would close it.

4. **LOW: `SmartPricing` raise message points at the wrong assoc.**
   `smart_pricing.ex:127-132` raises when `entry.item.catalogue` is
   `%NotLoaded{}`, but the hint says:

   > Use `Catalogue.list_items_*(... preload: [catalogue_rules:
   > :referenced_catalogue])` or chain `Repo.preload` before calling.

   A reader debugging this would think the missing assoc is
   `:catalogue_rules`, not `:catalogue`. The message is correct for
   the smart-item-rules raise (`smart_pricing.ex:140-143`) but
   misleading for the catalogue raise. Suggest splitting: each
   raise names its own missing assoc.

5. **LOW: Float `qty` carries float imprecision into Decimal math.**
   `SmartPricing.to_decimal/1` does `Decimal.from_float/1` for
   floats (`smart_pricing.ex:180`). The `@type entry` accepts `qty:
   number()`, so it's in-contract — but a one-line caveat in the
   moduledoc telling billing-precision callers to prefer `Decimal`
   or integer for `:qty` would prevent a foot-gun. The existing
   "qty accepts integer, Decimal, and float" test
   (`smart_pricing_test.exs:341-358`) only checks `3.0` (exact
   in float), not something like `1.1`.

6. **LOW: `apply_summary_mode/2` is local-only — fine, but watch for
   drift.** The private helper at `catalogue.ex:980-984` is a clean
   extraction for `category_summary_for_catalogue/2`, but the same
   `case mode do …` shape is inlined in
   `list_items_for_category_paged/2`,
   `list_uncategorized_items_paged/2`,
   `list_uncategorized_items/2`, etc. Don't fold yet — three is the
   right number for promoting to a shared helper, and we're at one.
   Just noting so the next addition is intentional, not accidental.

## General Module Review (Elixir / Phoenix / Ecto skill lens)

Skills invoked: `elixir-thinking`, `ecto-thinking`. (No LiveView surface
in this PR, so `phoenix-thinking` not applicable.)

### Elixir-thinking

- **Iron Law (no process without a runtime reason)** — ✅ No new
  `use GenServer`, `use Agent`, `use Task`, or supervision
  introduced. `SmartPricing` is a plain module with pure functions
  over data; perfect application of the "Modules organize code,
  processes manage runtime" rule.
- **Pattern matching on function heads** — heavily used in
  `SmartPricing`. `standard?/1` has three clauses (standard / smart /
  NotLoaded raise); `compute_price/3` splits smart-with-rules vs
  pass-through; `default_line_total/1` splits nil-base-price vs the
  arithmetic case; `to_decimal/1` splits across the three numeric
  types. No nested case statements. Idiomatic.
- **Defaults via `/3` Keyword variants** — ✅ `Keyword.get(opts,
  :line_total, &default_line_total/1)`,
  `Keyword.get(opts, :write_to, :smart_price)`, etc. No
  `case Keyword.get(opts, :foo) do nil -> ...` anti-pattern.
- **`raise` only on programmer errors** — `ArgumentError` for
  `%NotLoaded{}` is right (it's a "you forgot to preload" bug, not a
  recoverable condition). The `{:ok, _}` / `{:error, _}` shape isn't
  appropriate here — the function is purely transformational.
- **Behaviors / protocols** — none introduced; not needed. The
  `:line_total` lambda is the right level of indirection for the
  single piece of consumer policy. Reaching for a behavior would be
  over-engineering.
- **No process dictionary, no `Application.put_env` test coupling**
  — ✅. Tests stay `async: true`.

### Ecto-thinking

- **Context = setting that changes meaning** — ✅. `evaluate_smart_rules`
  takes `[%{item:, qty:}]` entries — the entry shape is the smart-pricing
  context's domain object, distinct from `Item.t()` itself. The function
  doesn't query: it operates on already-loaded data. Clean separation
  between "fetch" (the bulk fetchers) and "compute" (`SmartPricing`).
- **Cross-context references via IDs, not associations** — N/A here;
  this is internal to the catalogue context.
- **Preload vs join trade-offs** — the new `:preload` opt is
  *separate preloads*, not join preloads. Right call for the
  smart-pricing case where `catalogue_rules` is has-many — the
  10x-memory join trap is avoided. The bulk fetchers' use of `join`
  for the `WHERE` clause + `preload` for the data load is the
  correct two-clause pattern.
- **`merge_preloads/2` semantics** — `defaults ++
  Keyword.get(opts, :preload, [])`. Ecto's preload normalizer
  handles atom dedup and bare/nested merging at preload time. The
  `:preload collision` test pins this. ✅
- **`list_items_by_uuids/2` SQL** — single `WHERE i.uuid IN ^uuids
  AND i.status != "deleted"` query plus in-memory order/dedupe via
  `Map.new` + `Enum.flat_map`. No N+1, no `Repo.preload` chained
  separately (the `preload: ^preloads` is part of the same query).
  ✅
- **`category_summary_for_catalogue/2` two-query pattern** — one
  `from(c in Category, …)` for metadata (delegated to
  `list_categories_metadata_for_catalogue`) plus one `from(i in Item,
  group_by: i.category_uuid, select: {…})` for counts. Single
  in-memory `Enum.reduce` builds both result fields. ✅
- **`apply_summary_mode/2` query composition** — uses
  `where(query, [i], …)` to compose onto the base query. Idiomatic
  Ecto query composition, no string-interpolation, no `dynamic/2`
  needed.
- **No raw SQL fragments introduced** — ✅. No `fragment("…")` calls
  anywhere in the new code. Everything routes through Ecto.Query.
- **Soft-delete consistency** — `list_items_by_uuids/2` excludes
  `status != "deleted"`. Matches the rest of the catalogue's
  active-by-default convention. ✅
- **No prepared-statement or pgbouncer concerns introduced** — ✅.
- **Sandbox compatibility** — `SmartPricing` is pure; tests don't
  need the sandbox at all. The integration tests in
  `smart_catalogues_guide_test.exs` use `PhoenixKitCatalogue.DataCase`
  (sandbox-aware). ✅

### Idioms

- Structs over maps for known shapes (`%Item{}`, `%CatalogueRule{}`,
  `%CatalogueSchema{}` in the smart-pricing tests) — ✅
- `@spec` annotations on every public function in the new module — ✅
- `@type entry :: %{required(:item) => Item.t(), required(:qty) => …}`
  pins the entry contract at the type level — ✅
- Doc examples match real call shape (not pseudo-code) — ✅
- Decimal arithmetic throughout (no float math in pricing paths) — ✅
- Prepend-don't-append for lists in `merge_preloads/2`: `defaults
  ++ caller_preload` is concat, not prepend, but the order matters
  here (defaults first so caller's nested specs override). Doc
  could be clearer about the order; the test pins it.

## Verdict

Ship-ready as merged. Three test/doc nits and one substantive
follow-up (#1 — narrow the test_helper rescue and either pin
`phoenix_kit` to a version with `ensure_current/2` or live with
integration tests excluded until 1.7.105 ships). The smart-pricing
extraction is clean architecture work — the package now owns the
algorithm, the consumer-policy seam (`:line_total`) is in the right
place, and the loud preload raises close a footgun class that would
otherwise surface as silent zero-pricing in production.

## Related

- Companion core PR: [BeamLabEU/phoenix_kit#515](https://github.com/BeamLabEU/phoenix_kit/pull/515)
  — adds `PhoenixKit.Migration.ensure_current/2` (1.7.105)
- Issue: [#19](https://github.com/BeamLabEU/phoenix_kit_catalogue/issues/19)
  — `:preload` opt + `list_items_by_uuids`
- Issue: [#20](https://github.com/BeamLabEU/phoenix_kit_catalogue/issues/20)
  — public smart-rules evaluator
- Issue: [#21](https://github.com/BeamLabEU/phoenix_kit_catalogue/issues/21)
  — category summary helper
- Issue: [#16](https://github.com/BeamLabEU/phoenix_kit_catalogue/issues/16)
  — smart→smart references (shipped in PR #18)
- Issue: [#17](https://github.com/BeamLabEU/phoenix_kit_catalogue/issues/17)
  — smart catalogues guide (shipped in PR #18)
- Previous PR: [#22 — DnD reorder](/dev_docs/pull_requests/2026/) (no review dir)
- Previous review: [#13](/dev_docs/pull_requests/2026/13-fix-smart-item-classification-detail-scroll/PINCER_REVIEW.md)
  — established the `merge_preloads`-style single-source convention this PR continues
- Previous review: [#11](/dev_docs/pull_requests/2026/11-nested-categories-attachments/CLAUDE_REVIEW.md)
  — earlier `:preload` / search work
