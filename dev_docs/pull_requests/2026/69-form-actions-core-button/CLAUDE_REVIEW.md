# PR #69 Review — Use the kit's button component for form actions in four forms

**Author**: @timujinne (Tymofii Shapovalov)
**Reviewer**: Claude (Opus 5)
**Status**: Merged, reviewed post-merge
**Merge commit**: `5905ba2` (branch commits `7594a77`, `7698e60`)
**Date**: 2026-08-16

## What landed

Four form LiveViews — `manufacturer_form_live.ex`, `supplier_form_live.ex`,
`catalogue_form_live.ex`, `category_form_live.ex` — swap hand-written
`class="btn …"` markup for core's `<.button>`
(`PhoenixKitWeb.Components.Core.Button`, imported `only: [button: 1]`).
41 insertions, 33 deletions, no context or schema changes.

> **Note on PR numbering.** #69 and #68 are the same change pushed from two
> branches (`refactor/form-actions-core-button` and
> `feature/forms-pk-components-manufacturer-supplier`). GitHub marked both
> MERGED against the single merge commit `5905ba2`. This review covers that
> commit; there is no separate #69 diff.

## Verified as correct

Checked against core 2.8.0's `Core.Button` (`deps/phoenix_kit/lib/
phoenix_kit_web/components/core/button.ex`), not against the PR description:

- **`name` / `value` survive.** The two catalogue and two category submits
  carry `name="save_action" value="stay|exit"`, and `test/web/
  form_lives_test.exs` drives them through
  `put_submitter(~s(button[name=save_action][value=stay]))`. They reach the
  DOM only because core's `attr :rest, :global` declares
  `include: ~w(disabled form name value …)`. It does — both save modes still
  work, and the suite proves it.
- **`navigate` renders a link, not a dead button.** Core has a second
  `button/1` clause that emits `<.link navigate=…>` when any of
  `navigate` / `patch` / `href` is set. The Cancel controls stay `<a>`
  elements, so the "Save is the Enter-key submitter, being first in the DOM"
  comment above each action row still holds — Cancel is not a button and
  cannot capture Enter.
- **Dropping `phx-submit-loading:opacity-75` is safe.** `button_class/3`
  bakes that class into every rendered button. The PR removes it from four
  call sites and loses nothing.
- **The `variant="outline" size="sm"` Move buttons are exact.** They emit
  `btn btn-outline btn-sm`, matching the `btn btn-sm btn-outline` they
  replaced.
- **Core floor is already right.** `navigate`, `variant`, `size` and the
  status variants all ship in core 2.8.0, and `mix.exs` pins `~> 2.8`
  (pinned by `test/core_pin_conformance_test.exs`). No consumer can resolve
  a core where these attrs silently vanish.

## Findings

### BUG - MEDIUM — the "Delete Forever" buttons emit `btn-primary` and `btn-error` together

`catalogue_form_live.ex:641`, `category_form_live.ex:736` (pre-fix):

```heex
<.button phx-click="show_delete_confirm" size="sm" class="btn-outline btn-error shrink-0">
```

`variant` defaults to `"primary"`, and it **replaces** the base colour rather
than being suppressed by `class`. The rendered class list is therefore:

```
btn btn-primary btn-sm phx-submit-loading:opacity-75 btn-outline btn-error shrink-0
```

Two daisyUI colour classes of equal specificity on one element — which one
wins is decided by the compiled stylesheet's ordering, not by the markup.
Core's own moduledoc names this exact case as the reason the status colours
were promoted to first-class variants:

> Status colours (`info` / `success` / `warning` / `error`) are first-class
> variants: passing `class="btn-error"` next to the default `btn-primary` is
> how stylesheet order used to pick the winner.

Today daisyUI happens to emit `btn-error` after `btn-primary`, so the button
still looks red — which is why the change passed visual review. It is one
upstream reordering away from a primary-coloured *permanently delete* button
in the danger zone. The PR set out to stop hand-written classes drifting from
the component and reintroduced the drift in the two most destructive
controls it touched.

**Fixed** — both call sites now use the variant:

```heex
<.button
  phx-click="show_delete_confirm"
  variant="error"
  size="sm"
  class="btn-outline shrink-0"
>
```

`btn-outline` stays in `class` because it is a style modifier, not a colour,
so it composes rather than collides.

### NITPICK — `class="btn-outline"` on the "Save" submits is correct, and now says so

The Save (stay) buttons keep `class="btn-outline"` next to the default
`btn-primary`, reproducing the original `btn btn-outline btn-primary`
exactly. This is **not** the collision above: `btn-outline` sets no colour.
The trap is the obvious-looking cleanup — `variant="outline"` *replaces* the
colour and would leave an uncoloured Save. Added a comment at both action
rows so the next pass doesn't "fix" it.

### NITPICK — the PR description's remaining-count is off

The description says the two leftover hand-written control classes are in
the category form and "carry per-place spacing". In the merged tree the
leftovers are `class="btn-outline"` (catalogue + category) and the
`btn-outline btn-error shrink-0` pair — four sites across two files, one of
which was the bug above. Cosmetic; recorded so the count isn't trusted later.

### Not a finding — the two large forms left alone

`item_form_live.ex` (23 hand-written sites) and
`attribute_group_form_live.ex` (13) are deliberately out of scope, and that
call is right: the item form tunes styling per place and the tests here
assert behaviour, not classes, so a blind swap would move layout invisibly.
106 hand-written `btn` sites remain across `lib/` — a later pass, not this
one.

## Tests added

`test/web/form_lives_test.exs`, new `describe "form action buttons"`:

- The catalogue and category danger-zone buttons assert `btn-error` +
  `btn-outline` and **refute** `btn-primary` — this is what fails if the
  `class="btn-error"` form comes back.
- The catalogue submits pin `name="save_action"` and both `value`s, so a
  core change that dropped `name`/`value` from the `:rest` include list
  fails here rather than in a host's browser.

## Validation

- `mix precommit` — compile (warnings-as-errors), format, `credo --strict`
  (no issues), dialyzer (9 errors, 9 skipped) — **passed**.
- `mix test` against a live database — **2 doctests, 1568 tests, 0 failures**
  (integration included, not excluded).

## Related

- Duplicate PR: [#68](https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/68)
- Core component: `deps/phoenix_kit/lib/phoenix_kit_web/components/core/button.ex`
