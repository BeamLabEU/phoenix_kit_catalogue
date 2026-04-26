# Follow-up Items for PR #10

Triaged against `main` on 2026-04-26. Single CLAUDE_REVIEW; verdict
"Approved & merged". Three minor concerns + three carryover items
from PR #7's review (which the PR #10 reviewer carried forward).

## Fixed (pre-existing — carryovers from PR #7 closed in subsequent PRs)

- ~~Carryover **#1** `next_category_position/1` outside transaction in
  `move_category_to_catalogue/3`~~ — closed by PR #11. Verified at
  `lib/phoenix_kit_catalogue/catalogue.ex:1240`.
- ~~Carryover **#2** `move_item_to_category/3` lacks `FOR SHARE` lock~~ —
  closed by PR #10/#11. Verified at
  `lib/phoenix_kit_catalogue/catalogue.ex:1830`.

## Fixed (Phase 2 sweep on this branch)

- **Carryover #3** `actor_opts/1` duplicated across 8 LiveViews —
  Phase 2 C6 extracts to a shared `PhoenixKitCatalogue.Web.Helpers`
  (or analogous) module so all 8 LVs alias one implementation.
  Currently 8 copies (verified by `grep -n "defp actor_opts"
  lib/phoenix_kit_catalogue/web/*.ex`).

## Skipped (with rationale)

- **Minor #1** `@rule_known_keys` includes `"item_uuid"` — by design.
  In `put_catalogue_rules/3` the value is overwritten by
  `rule_attrs_with_item_and_position/3`; the explicit
  `create_catalogue_rule/2` API allows callers to pass `"item_uuid"`
  via form params for that single-create path. The reviewer flagged it
  as "worth naming" — adding a comment is bikeshedding; the public
  function's @doc already covers the contract.
- **Minor #2** Unit vocab open-ended VARCHAR with no DB-level CHECK —
  intentional. `CatalogueRule.changeset/2` validates against the closed
  `~w(percent flat) ++ [nil]` set; the open VARCHAR allows downstream
  hosts to add new units without a phoenix_kit migration. This is the
  documented tradeoff — see `catalogue_rule.ex` moduledoc. No change.
- **Minor #3** `discount_amount/3` recomputes `sale_price` and
  `final_price` independently — three Decimal walks. Not a hot path
  (called once per item display, not in any inner loop). Inlining
  intermediate values would harm readability for sub-millisecond gain.

## Files touched

None in this Phase 1 batch — `actor_opts/1` consolidation lands as
part of Phase 2's C6 component cleanup commit.

## Verification

- All carryover claims grep-verified.
- `actor_opts/1` count = 8 (`grep -c "defp actor_opts"`).

## Open

None.
