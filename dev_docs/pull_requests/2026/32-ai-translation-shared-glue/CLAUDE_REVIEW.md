# Review: PR #32 — AI translation (shared-glue adoption) + detail-filter/reorder UX + quality

Reviewed 2026-06-04 (post-merge, against `main`). Reviewed through the Elixir
`ecto`/`phoenix`/`elixir` thinking skills.

## Scope

Brings the catalogue onto core's shared AI-translation pipeline (adapter +
form glue), two catalogue-detail UX fixes (status-filter scope, reorder
no-op handling), and a quality pass (PR #31 follow-up, redundant import drop,
adapter unit tests).

## Verdict

Solid, well-commented PR. The risky parts (multilang `data` merge semantics,
concurrent per-language writes, broadcast suppression) are handled correctly
and the design respects the relevant skill "iron laws". Findings below are
small — one applied cleanup, the rest are low-priority/optional.

---

## Verified correct (the parts most likely to harbor bugs)

- **No DB query in `mount/3`.** The three form LiveViews call
  `assign_ai_translation/3` in `mount`, but core's `FormGlue` gates every DB
  lookup (`list_endpoints/0`, `list_prompts/0`, `subscribe/2`,
  `default_*`) on `Phoenix.LiveView.connected?/1`
  (`deps/phoenix_kit/.../form_glue.ex:79,124`). So the mount-twice double-query
  trap is avoided. ✅
- **`broadcast: false` actually takes effect.** `update_*/3` forward `opts` into
  `log_activity/2`, which checks `Keyword.get(opts, :broadcast, true)` before
  calling `broadcast_for/2` (`catalogue.ex:90–96`). The suppression the
  AI-write path relies on is real, and normal admin edits still broadcast. ✅
- **Concurrent per-language jobs serialize correctly.** `put_translation/4`
  re-reads the row `FOR UPDATE` inside the txn and merges against the freshly
  committed `data`, so parallel `enqueue_all_missing` jobs can't drop each
  other's languages (`ai_translatable.ex:95–113`). ✅
- **`force_put_language/3` merges rather than replaces** the lang subtree, and
  force-stores values equal to the primary so untranslatable strings don't
  read as "translation failed". Covered by tests. ✅

---

## Findings

### 1. [APPLIED] Dead `_ = primary` discard in `force_put_language/3`

`ai_translatable.ex` had an explicit `_ = primary` plus a comment claiming
`primary` "is bound only to seed the marker above." That's misleading —
`primary` is genuinely used in the `base` else-branch
(`%{"_primary_language" => primary, primary => existing_data}`), so the discard
suppressed nothing. Removed the line and trimmed the comment. Recompiles clean
with `--warnings-as-errors`.

### 2. [LOW] Adapter test coverage gaps

`test/phoenix_kit_catalogue/ai_translatable_test.exs` (10 tests) covers the
`item` resource type well but leaves gaps:

- `source_fields/2` only exercises the **column-fallback** path. The
  `_`-prefixed multilang-override branch and the legacy plain-key branch
  (`field_value/3`, `ai_translatable.ex:63–69`) — the more interesting
  paths — are untested.
- `fetch/2` and `put_translation/4` are only tested for `"catalogue_item"`.
  The `"catalogue"` / `"catalogue_category"` dispatch clauses (and their
  `persist_target/1` mappings) have no coverage, so a wrong schema/updater
  pairing would slip through.

Suggested additions (low risk, mirror existing patterns): a `source_fields`
test that seeds `data[lang]["_name"]` and asserts the override wins over the
column; a `fetch`/`put_translation` round-trip for a category. Not applied here
because the suite needs a live Postgres that isn't available in this
environment — flagging rather than pushing unverified test code.

### 3. [LOW / optional] Duplicated AI-translate wiring across 3 LiveViews

`catalogue_form_live.ex`, `category_form_live.ex`, and `item_form_live.ex` each
repeat byte-for-byte:

- the `import PhoenixKitCatalogue.Web.Helpers, only: [...]` block (10 names)
- the `import PhoenixKitWeb.Components.AITranslate, only: [...]` block
- six `handle_event/3` clauses (`ai_toggle_modal`, `ai_select_endpoint`,
  `ai_select_prompt`, `ai_select_scope`, `ai_generate_prompt`,
  `ai_translate_lang`)
- one `handle_info({:ai_translation, …})` clause
- the button/progress/hint markup block (differs only by a margin class)

A `__using__` macro (e.g. `PhoenixKitCatalogue.Web.AITranslateForm`) could fold
the imports + event/info clauses into one `use`. **Tradeoff:** injecting
`handle_event`/`handle_info` clauses via macro tends to trigger the "clauses of
the same name/arity should be grouped together" compiler warning (each host LV
defines its own `handle_event`s elsewhere), and macros hide the wiring. The
current explicit delegation is verbose but greppable and warning-free. Net
recommendation: **leave as-is** unless a 4th consumer appears; revisit then
with a `@before_compile`-based injection that keeps clauses grouped.

### 4. [INFO] `column_value/2` `String.to_existing_atom` + rescue

For the fixed set `@translatable_fields ["name", "description"]`, a compile-time
`%{"name" => :name, "description" => :description}` lookup would be marginally
clearer and drop the `rescue ArgumentError`. The current form is more general
and harmless — noting only, not worth changing.

---

## Quality gates

- `mix compile --warnings-as-errors` — clean (core release with
  BeamLabEU/phoenix_kit#582 present).
- Test suite not runnable in this environment (no local Postgres / `psql`);
  PR notes report `mix format --check-formatted`, `credo --strict`, and the
  10 adapter tests green against a local core.

## Applied in this pass

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/ai_translatable.ex` | Drop dead `_ = primary` discard + correct the trailing comment in `force_put_language/3` |

## Open / recommended (not applied)

- Add the `source_fields` override-path and catalogue/category
  `fetch`+`put_translation` tests (Finding 2) — needs a DB to verify.
- Optional macro de-duplication of the per-LiveView AI wiring (Finding 3) —
  deferred by recommendation.
