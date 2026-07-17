# Review — PR #45: Unit-cost revisions with validity-window price history

Merged as `05dfc17` (fork sync from `timujinne/feature/unit-cost-revisions`,
commits `a2347b1` + `ba2d295`). Reviewed against the Ecto and Phoenix thinking
skills, cross-checked against the sibling `../phoenix_kit` checkout for the
migration history this feature depends on.

**Overall:** solid, well-tested extension of the PR #44 supplier-info layer.
`revise_unit_cost/3`'s close-then-insert `Ecto.Multi` correctly frees the
partial-unique `is_primary` index inside the transaction before the successor
inherits it, and every read path (`list_for_item/1`, `primary_for_item/1`,
the new `audit_supplier_refs` query) was updated in lockstep to filter on
`is_nil(valid_to)` so closed rows don't leak into "current" views. Unlike
PR #44, this PR does **not** introduce a migration-drift gap: `valid_from` /
`valid_to` have existed on `phoenix_kit_cat_item_supplier_info` since core's
`V149`, and the `is_primary` partial-unique index this code relies on (core
`V151`) has been in the pinned `mix.lock` (`phoenix_kit` 1.7.199, index
lands at 1.7.197) since before this PR's commits landed — the "Known
blocker" from `44-parties-supplier-info/CLAUDE_REVIEW.md` was already
resolved by the time this branch started. Gettext coverage for the new
strings is complete across en/ru/et.

One real bug found and fixed with a regression test; one concurrency gap
documented as a known limitation (fixing it needs a core `phoenix_kit`
migration, out of scope for this repo alone per its own "no DB migrations
of its own" convention).

---

## 1. Currency-only revision silently no-ops — **bug, fixed**

`revise_unit_cost/3`'s guard decided "nothing to do" using only the cost
comparison:

```elixir
Decimal.compare(new_cost, info.unit_cost || Decimal.new(0)) == :eq ->
  {:ok, info}
```

But the function's own docs advertise currency correction as a first-class
use case: `opts[:currency]`, "when provided and different from the row's
currency, the successor stores the new currency; both old and new
currencies are recorded in the activity metadata." A caller correcting a
mis-recorded currency without also changing the cost (e.g.
`revise_unit_cost(info, info.unit_cost, currency: "USD")`) hit the no-op
branch: no successor row, no activity log entry, no currency change — the
call silently did nothing while returning `{:ok, info}`, indistinguishable
from success. The existing test suite didn't catch this because every
currency-change test paired it with a cost change (`8.00 -> ... currency:
"USD"`), never the same-cost case.

**Fix**: the no-op guard now also requires `opts[:currency]` to be absent
or equal to the row's current currency:

```elixir
caller_currency = opts[:currency]
currency_unchanged = is_nil(caller_currency) or caller_currency == info.currency

cond do
  not is_nil(info.valid_to) -> {:error, :not_current}
  Decimal.compare(new_cost, info.unit_cost || Decimal.new(0)) == :eq and currency_unchanged ->
    {:ok, info}
  true -> do_revise_unit_cost(info, new_cost, opts)
end
```

Added `"same cost but different currency still creates a revision (not a
no-op)"` to `test/item_supplier_infos_test.exs`, asserting a successor row
is created, the currency changes, the original closes, and
`history_for_pair/2` now returns 2 rows.

---

## 2. No guard against concurrent revisions producing two "current" rows for a non-primary supplier — **not fixed (needs a core migration)**

`revise_unit_cost/3` reads `info` in memory, then in a transaction closes
that specific row and inserts a successor. There is no `WHERE valid_to IS
NULL` (or row version) check tying the close to the row's state *at commit
time*, and the schema deliberately carries no uniqueness on
`(item_uuid, supplier_uuid)` (see the schema's own moduledoc: "There is
intentionally NO uniqueness ... multiple rows per supplier are allowed").

For the **primary** row this is self-correcting: if two concurrent
revisions race, both successors would carry `is_primary: true` and the
existing partial-unique index (`phoenix_kit_cat_item_supplier_info_primary_uniq`)
rejects the second insert outright — the caller gets a loud
`{:error, changeset}`.

For a **non-primary** row, nothing catches it: two concurrent
`revise_unit_cost/3` calls on the same non-primary junction row can both
close the original (idempotent — both just set `valid_to: today` on a row
that's already headed there) and both successfully insert a successor with
`is_primary: false`, `valid_from: today`, `valid_to: nil`. The result is
two simultaneous "current" rows for the same item/supplier pair.
`list_for_item/1` would then show a duplicate line for that supplier, and
`Suppliers.active_info_for/2` (`limit: 1`, no explicit tiebreaker) would
pick one of the two arbitrarily.

This is more than a theoretical concern given the documented call site:
`Suppliers.active_info_for/2`'s doc says it's "the function warehouse calls
to check whether a receipt line's unit price diverges from the catalogued
cost," and `revise_unit_cost/3`'s `:source` option gives `"goods_receipt"`
as the example — i.e. the intended caller is automated receipt processing,
where two receipts for the same item/supplier landing close together is a
plausible, not exotic, race.

**Not fixed here**: closing the gap properly needs a partial unique index
in core, e.g.
`CREATE UNIQUE INDEX ... ON phoenix_kit_cat_item_supplier_info (item_uuid, supplier_uuid) WHERE valid_to IS NULL`,
which is a `phoenix_kit` migration, not something this repo can ship per
its own "no DB migrations of its own" rule. Flagging here so it's on record
for a follow-up core migration + a `unique_constraint` sibling in
`ItemSupplierInfo.changeset/2` and `revise_unit_cost/3`'s insert step
(mirroring how the primary-uniq index is already handled).

---

## 3. Nitpick — redundant `unique_constraint/3` in `do_revise_unit_cost/3`

```elixir
Multi.insert(:successor, fn _ ->
  ItemSupplierInfo.changeset(%ItemSupplierInfo{}, successor_attrs)
  |> Ecto.Changeset.unique_constraint(:item_uuid,
    name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
    message: "another supplier is already marked primary for this item"
  )
end)
```

`ItemSupplierInfo.changeset/2` already registers this exact constraint
(same name, same message) at the bottom of the changeset pipeline. The
second call is dead weight — harmless (Ecto just carries a duplicate
constraint entry), but worth dropping in a follow-up cleanup pass rather
than copy-pasting it again the next time this pattern is needed.
Not changed in this pass to keep the fix diff minimal.

---

## Verification

- `mix format` — clean.
- `mix compile --warnings-as-errors` — clean.
- `mix test` — not run in this environment (no local Postgres available,
  same condition noted in the 0.10.0 and 0.11.0 release notes). The fix in
  finding 1 is covered by a new unit test that will run against CI/a
  Postgres-backed environment; the rest of the PR's own test suite
  (`test/item_supplier_infos_test.exs`) was read in full and manually
  traced against the transaction logic in finding 2 rather than executed.
