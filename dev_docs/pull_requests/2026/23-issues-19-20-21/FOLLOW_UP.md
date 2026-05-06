# PR #23 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code (post-merge).

## Fixed (pre-existing)

The reviewer's six "Minor concerns" were re-verified against the
current `main` branch. Five had already been addressed between
merge and this triage:

- ~~**MEDIUM #1: Integration tests dark on main against current Hex
  pin** — `test/test_helper.exs` already narrows the rescue to
  `[DBConnection.ConnectionError, Postgrex.Error]` (`test_helper.exs:77`),
  with a separate `catch :exit, _` for sandbox-owner exits. Anything
  else (including `UndefinedFunctionError`) propagates loudly so
  version mismatches don't masquerade as "DB unavailable".~~
- ~~**LOW #2: `merge_preloads/2` doc contradicts the new test
  contract** — current docstring at
  `lib/phoenix_kit_catalogue/catalogue/helpers.ex:95-103` matches the
  pinning test exactly: "Ecto merges the two: the parent association
  loads *and* the nested child loads. Pinned by the
  `:preload collision with default atom` test in `catalogue_test.exs`."~~
- ~~**LOW #3: Paged fetchers got `:preload` threading but no test
  coverage** — `test/catalogue_test.exs:2081` covers
  `list_items_for_category_paged/2 merges :preload with defaults`;
  `:2096` covers `list_uncategorized_items_paged/2 merges :preload
  with defaults`. Both assert the nested-assoc load shape that the
  non-paged tests pin.~~
- ~~**LOW #4: `SmartPricing` raise message points at wrong assoc** —
  `smart_pricing.ex:127-132` (catalogue raise) names `:catalogue`;
  `:140-143` (catalogue_rules raise) names `:catalogue_rules`. Each
  message is correct for its own missing assoc.~~
- ~~**LOW #6: `apply_summary_mode/2` is local-only — fine, but watch
  for drift.** Informational reviewer note ("three is the right
  number for promoting to a shared helper, and we're at one"); no
  code change required. Tracked here so the next addition is
  intentional.~~

## Fixed (Batch 1 — 2026-05-06)

- ~~**LOW #5: Float qty carries float imprecision into Decimal math.**
  Added a `## Numeric precision for `:qty`` section to
  `SmartPricing`'s moduledoc spelling out that `1.1`-style floats
  carry their binary-float imprecision through `Decimal.from_float/1`
  into the per-catalogue ref-sum. Caveat tells billing-precision
  callers to prefer `Decimal.t()` or `integer()`. Added pinning test
  `non-exact float qty is accepted; carries Decimal.from_float
  imprecision` in `test/smart_pricing_test.exs` that asserts both
  halves of the contract: float input doesn't crash AND
  `Decimal.from_float(1.1) != Decimal.new("1.1")`. Pure-function test,
  no DB.~~

## Skipped

None.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/smart_pricing.ex` | Add `## Numeric precision for `:qty`` moduledoc section (LOW #5) |
| `test/smart_pricing_test.exs` | Add pinning test for the float-imprecision contract (LOW #5) |

## Verification

`mix precommit` not run in this triage — the catalogue's standalone
test suite is dark on the current Hex pin until 1.7.105 publishes (the
reviewer's MEDIUM #1 fix is by design — `UndefinedFunctionError`
propagates rather than silently excluding `:integration`). The new
test is pure-function (no DB) and uses the existing in-memory
`%CatalogueSchema{}` / `%Item{}` / `%CatalogueRule{}` helpers, so it
will run as soon as the pin lands. Will surface in CI on the next
push once `BeamLabEU/phoenix_kit#515` merges and `mix deps.update
phoenix_kit` bumps the lock.

## Open

None.
