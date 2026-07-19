# Code Review — 2026-07-17: recent commits (0.11.0–0.12.1) + general sweep

Scope: the 12 non-merge commits from `662a31a` through `5684bbf` (HEAD) — PRs #44 (parties/supplier-info), #45 (unit-cost revisions), #46 (import multilang auto-switch-language) and their review follow-ups — plus a repo-wide hygiene sweep. Reviewed against the current dependency pins in `deps/` (notably `phoenix_kit` 1.7.199, whose `V151` migration carries the `supplier_source` / `is_primary` columns and the `phoenix_kit_cat_item_supplier_info_primary_uniq` partial index). Where a claim hinged on core behavior it was verified against core source (e.g. `deps/phoenix_kit/lib/phoenix_kit_web/components/multilang_form.ex:197-212` for the switch_language hook).

**Overall:** this is a disciplined run of commits — every review commit ships a written findings doc, version bumps always hit both locations, known limitations are disclosed in the changelog instead of buried, and the trickiest invariants of the supplier-info feature (partial-unique primary, `force_change` on re-promote, in-transaction index freeing) are handled correctly. The recent commits themselves are largely clean; the findings below are mostly follow-through gaps the feature chain left behind. One finding deserves action before the next release: two "current" supplier-info rows for the same item/supplier pair are creatable deterministically from the item form — the same integrity hole the 0.12.0 changelog documents as a race, except reachable by any admin in two clicks, and it silently corrupts the warehouse-facing `active_info_for/2` lookup. Separately, the 0.12.0/0.12.1 changelogs claim `mix credo --strict` is clean; it is not in this checkout (6 issues), and `mix test` still cannot run anywhere without a Postgres client — the same verification gap that let the V149 migration blocker ship unnoticed in #44.

---

## Commit-by-commit

| Commit | Subject | Verdict |
| --- | --- | --- |
| `5684bbf` | Remove dead `switch_language` clauses, bump 0.12.1 | Clean — removal verified against core: the `mount_multilang/2` event hook halts before the LV clause, and both paths call the same helper. The three form LVs are now consistent; ImportLive keeps its clause deliberately. |
| `aaaa34c` | lib upgrades (earmark_parser, mdex) | Clean — lockfile only. |
| `367678f` | Opt out of auto switch_language on import screen | Sound — with `auto_switch_language: false` core skips only the event hook; ImportLive's own immediate-switch clause stays reachable. One nit below (#11). |
| `6ca7325` | Fix currency-only revision no-op, bump 0.12.0 | Clean — the guard now requires currency unchanged too; regression test included; the remaining race is candidly documented as needing a core migration. |
| `ba2d295` | Review minors (current-only audit totals, dead merge, Close translation) | Clean — verified against current code. |
| `a2347b1` | Price revision history on item_supplier_infos | Core logic correct (close+insert in one Multi, Decimal handling sound). Leaves findings #1, #5, #6, #7. |
| `46c1ea3` | Bump mint to 1.9.3 (EEF-CVE-2026-59249) | Clean — advisory is real and affects mint `< 1.9.3`; the existing `~> 1.9` constraint already allowed it. |
| `4983503` | Fix supplier-facade bugs, bump 0.11.0 | Clean — four real bugs fixed (non-existent `PartyRoles.list_suppliers/0`, contact/company mislabeling, missing `actor_uuid` threading, PubSub typespec gap); `FakeCRMPartyRoles` exercises the guarded paths. |
| `fa514b1` | CRM source persistence, primary-unique constraint, activity parity | Clean — the `force_change` catch in `set_primary` (empty diff skipped the UPDATE after `clear_primary` had demoted the row) was a genuinely subtle find. |
| `29bf82a` | Item supplier-info junction table | Foundation is sound; schema↔migration alignment with core V149/V151 verified (constraint name matches exactly, no DDL in this repo). Its bugs were fixed by its own follow-ups. |
| `d82c62c`, `662a31a` | Test-support fixes | Clean and minimal; stale-test rewrites track the drill-down redesign accurately. |

## Findings

### 1. Duplicate current supplier-info rows creatable from the item form — open, MAJOR

`ItemSupplierInfos.create/2` (`lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:78`) has no uniqueness guard on `(item_uuid, supplier_uuid)` for current rows, and the add-supplier dropdown in the item form (`lib/phoenix_kit_catalogue/web/item_form_live.ex:1314`) iterates `@all_suppliers` without filtering already-linked ones — so an admin can add the same supplier twice and get two current rows, no race required. `Suppliers.active_info_for/2` (`lib/phoenix_kit_catalogue/catalogue/suppliers.ex:229`) then picks one arbitrarily (`limit: 1`, no tiebreaker) — exactly the warehouse divergence-check this feature exists to serve. The 0.12.0 changelog documents the concurrent-call variant of this hole as a known limitation needing a core partial-unique index (`WHERE valid_to IS NULL`); that index closes both paths, but a dropdown filter (plus a `create/2` guard returning a tagged error) is a cheap stopgap that doesn't need a migration.

### 2. ItemFormLive bypasses the public `Catalogue` facade — open, MINOR

`item_form_live.ex:36-38` aliases `Catalogue.Helpers`, `Catalogue.ItemSupplierInfos`, and `Catalogue.Suppliers` and calls them directly throughout (`Suppliers.list_all()` at :152, `ItemSupplierInfos.create/2` at :552, `.set_primary/2` at :582, `.list_for_item/1` at :557/:584/:636/:662, `.history_for_pair/2` at :603, `.delete/2` at :632). Every one of these was given a public delegate in `4983503` (`Catalogue.list_all_suppliers/1`, `create_supplier_info/2`, `set_primary_supplier_info/2`, `list_supplier_infos_for_item/1`, `supplier_info_history_for_pair/2`, `delete_supplier_info/2` — `catalogue.ex:293-325`). AGENTS.md is explicit that LiveViews must not call internal submodules directly; the facade delegates added in the same release are unused by the one LV that motivated them. Same leak, smaller scale: `pdf_search_modal.ex:67` calls `PdfLibrary.item_titles/1` and `item_form_live.ex:481` calls `Helpers.dedupe_keep_last/1`, neither of which has a public delegate at all. (Direct `PubSub`/`ActivityLog` calls elsewhere in the web layer are documented plumbing and deliberately kept.)

### 3. `mix credo --strict` is red despite the changelog claiming clean — open, MINOR

Six issues on this checkout (148 files, exit 8):

- `lib/mix/tasks/phoenix_kit_catalogue.audit_supplier_refs.ex:40,74` — `audit_junction_rows` too complex (cyclomatic 11, max 9), nested too deep (depth 4, max 2), and an `apply/3` with a known arg count.
- `lib/phoenix_kit_catalogue/catalogue/suppliers.ex:263,298,316` — three `apply/3` calls in the CRM soft-dependency shims (`try_resolve_crm`, `list_crm_companies`, `list_crm_contacts`). These are intentional dynamic calls into an optional sibling, but credo flags them regardless — they need `# credo:disable-for-next-line` annotations or a `.credo.exs` exclusion, not a changelog blind eye.

The 0.11.0 changelog said credo was "at parity with the pre-existing baseline"; 0.12.0 and 0.12.1 upgraded that to "clean". It isn't — and since `mix precommit` gates on credo, the next committer hits this immediately.

### 4. `test_helper.exs` crashes when the `psql` binary is missing — open, MINOR

`test/test_helper.exs:26` calls `System.cmd("psql", ["-lqt"])` and only handles a non-zero exit. On a machine without the Postgres client installed, the missing binary raises `ErlangError :enoent` before `ExUnit.start` — so even the non-integration unit tests can't run, instead of the documented "integration auto-excluded without DB" behavior. One-line fix: rescue the raise around the probe. Broader note: every release since 0.11.0 was cut without a single test executed (no Postgres anywhere in the release environment); the changelogs disclose this honestly, but the V149 migration gap that shipped in #44 is exactly the class of bug a real CI run catches. A CI job with a Postgres service should be treated as release-blocking infrastructure, not a nice-to-have.

### 5. Deleting the primary supplier-info row leaves the item with no primary — open, MINOR

`ItemSupplierInfos.delete/2` (`item_supplier_infos.ex:137`) hard-deletes without re-promoting a sibling. Afterwards `primary_for_item/1` silently returns `nil` until someone calls `set_primary/1` by hand. `fa514b1`'s commit message claims "no-primary remains reachable only by explicit demotion" — deletion isn't demotion, so the stated invariant doesn't hold. Either auto-promote the oldest remaining current row (matching the create-side auto-promote) or document the gap.

### 6. `update/3` can wedge the partial-unique primary index — open, MINOR

`ItemSupplierInfos.update/3` (`item_supplier_infos.ex:112`) lets an API caller set `valid_to` on a primary row without clearing `is_primary`. The row then occupies the `WHERE is_primary` partial index while no longer being "current", so `primary_for_item/1` returns `nil` yet `set_primary/1` on any sibling fails with the unique-constraint error. The test at `test/item_supplier_infos_test.exs:688-691` constructs exactly this state but only asserts the read side. No UI path reaches it today (the form never edits `valid_to`); a changeset guard (`valid_to` set ⇒ `is_primary` must be false) closes it.

### 7. Activity-log pin coverage has fallen behind — open, MINOR

`test/activity_logging_test.exs` pins ~20 of the ~62 distinct action atoms now emitted in `lib/`. Everything from the newer generations is unpinned: `item_supplier_info.*` (5), `pdf.*` (5), `smart_rule(s).*` (5), `item.bulk_*` (4), `import.*` (2), all the `*.permanently_deleted` variants, `folder.*`, and most `moved`/`reordered`/`restored` atoms. The file's own moduledoc (`activity_logging_test.exs:9`) still claims "Pinning every action atom + every threaded actor here", which is no longer true, and AGENTS.md's "extend it for new actions" hasn't been followed since the folders generation. A typoed action string in any of those paths would regress silently.

### 8. `link_manufacturer_supplier/2` / `unlink_manufacturer_supplier/2` skip the actor/logging contract — open, MINOR

Both are public (defdelegated at `catalogue.ex:333-334`), mutating, and take no `opts` — no `actor_uuid`, no activity row, no PubSub broadcast (`lib/phoenix_kit_catalogue/catalogue/links.ex:28,45`). Callers today (import executor, sync wrappers) log on their behalf, so nothing is silently unlogged in practice, but the public pair breaks the "every mutating context function takes `actor_uuid:` opts" rule and invites an unlogged call from the next consumer.

### 9. Error-atom convention drift between AGENTS.md and `errors.ex` — open, MINOR

~20 atoms returned from the context have no `Errors.message/1` clause: `:too_many_uuids`, `:wrong_scope`, `:invalid_strategy`, `:uuids_outside_scope`, `:duplicate_positions`, `:folder_not_found`/`:folder_trashed`, `:cycle`, `:move_target_not_found`/`:cross_catalogue_move`, `:wrong_catalogue_scope`/`:missing_catalogue_scope`, `:not_current` (`item_supplier_infos.ex:281`), and the PDF `:missing_actor`/`:no_extraction`/`:already_extracted`/`:enqueue_*` family. Verified: every LV handles its relevant atoms with bespoke gettext flashes or a generic failure flash, so nothing user-facing breaks — `errors.ex:66-68` explicitly sanctions the LV-decides pattern. But AGENTS.md still states "a new error atom requires a `message/1` clause plus a pin in `test/errors_test.exs`." The two documents contradict each other; reconcile one. (`:not_current` is the exception worth a clause regardless — only external consumers like warehouse can trigger it, and they get `"Unexpected error: :not_current"`.)

### 10. `create/1` misreports failure when auto-promote loses a race — open, MINOR

On the auto-promote path, `ItemSupplierInfos.create/2` (`item_supplier_infos.ex:98-106`) returns whatever `set_primary/2` returns. If `set_primary` fails (concurrent primary race), `create` reports `{:error, _}` even though the row was committed — the LV shows "Failed to add supplier." for a row that now exists. Narrow race, but the return contract is misleading; re-read and return `{:ok, info}` with the demoted state, or wrap both writes in one transaction.

### 11. Nits — collected

- `import_live.ex:377-379` — ImportLive's own `switch_language` clause assigns any `lang_code` without validating against enabled languages (core's `handle_switch_language/2` ignores unknown codes). A crafted event sets an arbitrary `current_lang`, which feeds `import_lang`. Admin-only, low impact; a one-line guard closes it.
- `catalogue_form_live.ex:120` (and siblings) — comment says `mount_multilang/1`; the function is now `/2` with a default arg.
- `item_supplier_infos.ex:331-334` — redundant `unique_constraint/3` on the successor insert; `changeset/2` already attaches the identical one. Known and deliberate per the PR #45 review doc.
- `audit_supplier_refs.ex:92` — output still says "Total junction rows" without noting it now counts only the current (`valid_to IS NULL`) subset.
- `suppliers.ex:230` — `import Ecto.Query` inside `active_info_for/2`'s body duplicates the module-level import at :19.
- `Catalogue.revise_supplier_info_cost/3` (`catalogue.ex:325`) — the intended stable surface for external consumers has no caller in `lib/` or `web/` and no test pinning the public name (the only test calls the `Suppliers` shim directly, `item_supplier_infos_test.exs:756`).
- `erl_crash.dump` (11 MB, May 2) in the repo root — gitignored, safe to delete locally.

## Working-tree note: uncommitted AGENTS.md rewrite

`git status` shows a modified, unstaged `AGENTS.md` — a rewrite from 759 lines to 112 (verified: it moves feature semantics out to `@moduledoc`s/`dev_docs/` and keeps only conventions and boundaries). The rewrite is a clear improvement in signal density, but it was authored alongside the findings above and inherits two of the drifts: it still mandates the `Errors.message/1`-per-atom rule that `errors.ex:66-68` contradicts (#9), and "pins one test per action atom" that `activity_logging_test.exs` no longer satisfies (#7). Reconcile before committing it.

## Verification

Checks run on this checkout (2026-07-17):

- `mix format --check-formatted` — **pass**.
- `mix compile` and `mix compile --force --warnings-as-errors` (dev) — **pass**, zero warnings across 76 files. (Test-env compile emits harmless "redefining module" warnings for `test/support/*.ex` from the `Code.require_file` workaround in `test_helper.exs`.)
- `mix credo --strict` — **fail**, 6 issues (finding #3).
- `mix test` — **could not run**: no Postgres server reachable (localhost:5432 refused) and no `psql` client installed; the missing binary crashes `test_helper.exs` before ExUnit starts (finding #4). Zero tests executed; all test-side claims in this review were verified by manual trace, same disclaimer as the 0.11.0–0.12.1 changelogs.
- `mix dialyzer` — not run here (PLT build cost); the 0.11.0 changelog reports a clean pass after the PubSub typespec fix, and nothing since touches the affected specs.
- Version consistency — **pass**: `mix.exs` `@version`, `PhoenixKitCatalogue.version/0` (`lib/phoenix_kit_catalogue.ex:92`), and the top CHANGELOG heading all read 0.12.1.
- Hygiene scan — clean: no TODO/FIXME/HACK markers, no `IO.inspect`/`dbg` in `lib/`, no commented-out blocks, no `@tag :skip` or test focus left in, no hardcoded URL paths outside `web/routes.ex`, `enabled?/0` rescues and catches `:exit` per convention, `errors_test.exs` matches the Errors module clause-for-clause.

## Recommended next actions

In priority order:

1. Stopgap finding #1 (filter already-linked suppliers from the dropdown; tagged-error guard in `create/2`) and file the core-migration request for the `WHERE valid_to IS NULL` partial-unique index.
2. Fix credo (#3) — refactor `audit_junction_rows`, annotate the three intentional `apply/3` calls — so `mix precommit` is green for the next committer, and correct the 0.12.0/0.12.1 verification claims going forward.
3. Guard the `psql` probe in `test_helper.exs` (#4) and stand up a CI job with Postgres before the next release.
4. Route ItemFormLive's supplier-info calls through the `Catalogue` facade (#2).
5. Bring `activity_logging_test.exs` back to one-test-per-atom and fix its moduledoc (#7); reconcile the errors convention docs (#9).
6. Batch the small correctness guards (#5, #6, #10, #11) into one maintenance commit.
