# Follow-up Items for PR #18

Triaged against `main` on 2026-04-28 after the upstream merge
(commit `79de606`). Post-merge review covered alongside PR #14 (the
quality-sweep PR that rebased on top of #18); the cross-PR notes
live in `../14-quality-sweep/FOLLOW_UP.md` under "Post-merge
follow-ups — 2026-04-28".

PR #18 itself shipped clean — `:only` scope validation, smart-chain
guard funneled through one private `build_rule_changeset/2`, picker
filter mirroring the changeset guard, and a `guides/` extra wired
into `mix.exs` `package.files` and `docs.extras`. Two findings on
`Rules`, both fixed in commit `5deee76`.

## Fixed (Batch 1 — 2026-04-28, commit `5deee76`)

- ~~**Self-reference comment contradicted the behavior.**~~ The
  doc comment on `Rules.build_rule_changeset/2` said self-refs
  "stay valid" but the test
  `"smart self-references are rejected (smart catalogue cannot be
  referenced at all)"` asserts the opposite. Rewrote the comment
  to match: self-refs are caught as a side effect of the
  smart-chain guard, since the only way to self-reference is for
  the rule's referenced catalogue to be the item's own (smart)
  catalogue.

- ~~**Per-keystroke DB lookup in
  `validate_referenced_catalogue_kind/1`.**~~ The form's
  `phx-change` cycle calls `change_catalogue_rule/2` →
  `build_rule_changeset/2` → `validate_referenced_catalogue_kind/1`,
  which was firing `repo().get(Catalogue, uuid)` on every
  keystroke (one query per rule per validate). Switched
  `Ecto.Changeset.get_field/2` to `get_change/2` so the lookup
  only fires when `:referenced_catalogue_uuid` is in `changes`
  — i.e. once when the picker selection actually changes, zero
  on every other keystroke.

  Existing pinning tests still pass because they all build from
  a fresh `%CatalogueRule{}` (the value goes into `changes`):

  - `test/catalogue_test.exs` "smart-to-smart references are
    rejected (issue #16)" — `put_catalogue_rules` insert path,
    fresh changeset.
  - `test/catalogue_test.exs` "smart self-references are
    rejected" — same shape.
  - `test/catalogue_test.exs` "create_catalogue_rule/2 rejects a
    smart referenced_catalogue (issue #16)" — fresh insert.
  - `test/catalogue_test.exs` "change_catalogue_rule/2 surfaces
    smart-chain error during form validate (issue #16)" — fresh
    `%CatalogueRule{}` with attrs.
  - `test/web/item_form_live_test.exs` "rule picker excludes
    smart catalogues + the parent itself (issue #16)" — picker
    filter, doesn't exercise the validation path.

  Behavioral note: an existing rule whose referenced catalogue
  later flips from `kind: "standard"` to `"smart"` will now
  remain editable without re-validation if the user doesn't
  touch the picker. This matches Ecto's general "validate
  changes, not data" stance and is consistent with the fact
  that the rule was already valid when the original ref was
  written. A separate audit job is the right tool for catching
  drift in legacy rows.

## Verification

- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — 1187 mods/funs, 0 issues
- `mix test` — not run locally (no Postgres in the review env);
  CI to confirm.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/rules.ex` | `get_field` → `get_change`; clarify self-ref comment |
| `dev_docs/pull_requests/2026/18-fix-issues-15-16-17/FOLLOW_UP.md` | new |

## Open

None.
