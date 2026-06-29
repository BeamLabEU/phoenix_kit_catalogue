# Code Review: PR #36 — Move catalogue admin headers into the global admin header bar

**Reviewed:** 2026-06-29
**Reviewer:** Claude (claude-opus-4-8)
**PR:** https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/36
**Author:** Timujeen (@timujinne)
**Head SHA:** `6fcf1b679613266d92c860da7c7a9865547cd40e`
**Merge commit:** `1d29706964c10765bddb5bd8bf379dd40a687225`
**Status:** Merged (post-merge review against `main`)

## Summary

Adopts the core `/admin/media` **self-wrap layout** pattern across the 8 catalogue
admin LiveViews that previously rendered an in-content `<.admin_page_header>`:

- A per-module `on_mount({__MODULE__, :self_wrapped_layout})` hook resets
  `socket.private[:live_layout]` from the auto-applied admin chrome
  (`{PhoenixKitWeb.Layouts, :admin}`) back to the passthrough
  `{PhoenixKitWeb.Layouts, :app}`.
- `render/1` is wrapped in `PhoenixKitWeb.Components.LayoutWrapper.app_layout`,
  feeding `page_title` / `page_subtitle` / `current_path` / `current_locale`
  into the global admin header (breadcrumb) instead of an in-content header.
- Action buttons and the rich catalogue breadcrumb relocate to in-body toolbars.
- **Events tab:** the broken inline counter
  (`Gettext.gettext(…, "%{count} events", count: @total)`, which rendered the
  Russian singular form for all counts) is replaced by a header subtitle
  `"<module> · Events: %{count}"` using a new agreement-free `"Events: %{count}"`
  msgid translated for en/ru/et.

Files: `catalogue_detail_live`, `catalogue_form_live`, `catalogues_live`,
`category_form_live`, `events_live`, `item_form_live`, `manufacturer_form_live`,
`supplier_form_live`, plus the 4 gettext catalogs.

## Verdict

**Approve — correct and well-implemented. No blocking issues, no PR-introduced
bugs.** The migration mechanically mirrors the core reference; the items below
are low-severity polish plus one **pre-existing** (out-of-PR-scope) version-drift
bug surfaced during review.

## Mechanism verification (the parts most likely to be wrong — all check out)

1. **Chrome opt-out ordering is correct.** Core auto-applies admin chrome to
   external plugin views in `PhoenixKitWeb.Users.Auth.maybe_apply_plugin_layout/1`,
   called once from the `:phoenix_kit_ensure_admin` **live_session** on_mount
   (`auth.ex:597` → sets `live_layout` to `:admin`). Phoenix runs live_session
   on_mounts *before* a module's own `on_mount`, so the module's
   `:self_wrapped_layout` reset to `:app` wins. It is a mount-time hook (not a
   `handle_params` hook), so it is not re-clobbered on navigation. ✔

2. **The reset target is the right one.** `PhoenixKitWeb.Layouts.app`
   (`app.html.heex`) is a pure `{@inner_content}` passthrough, so `:app` + a
   self-wrapping `app_layout` produces exactly **one** layer of admin chrome — no
   double-wrap. (`app_layout` also carries a process-dict double-wrap guard for
   the auto-chrome path, which this pattern sidesteps entirely.) ✔

3. **The assigns the wrapper reads genuinely exist.** `assigns[:url_path]` and
   `assigns[:current_locale]` are provided by core's `:phoenix_kit_ensure_admin`
   on_mount via `attach_locale_hook` / `set_routing_info` (`auth.ex:722`,
   `:753`) — `url_path` is refreshed on every navigation through a
   `handle_params` hook. Catalogue plugin routes live in the same
   `:phoenix_kit_admin` live_session (`integration.ex:491`), so they receive
   these hooks. The `|| Paths.*` fallbacks are therefore defensive/dead but
   harmless. ✔ All `app_layout` attrs (`page_subtitle`, `current_path`, …) are
   declared on the component with safe defaults — no required-attr gap. ✔

4. **`page_title` wiring is intact.** `catalogue_detail_live` sets
   `page_title: catalogue.name` (`:1436`), so the catalogue name — previously the
   in-content `<h1>` — now correctly lands in the global header. The in-body
   breadcrumb only renders when drilled into a category, matching the new design.
   `events_live` `@total` is reactive (`total:` assigned at `:38` and `:156`), so
   the subtitle count updates live. ✔

5. **Events plural fix is valid.** The old single-form translation could not
   express Russian plural agreement; the colon form `"Events: %{count}"` sidesteps
   agreement and `Gettext.gettext/3` with a `count:` binding is the right call
   (no `ngettext` needed). ✔

## Issues Found

### 1. Version drift — `version/0` reports `0.2.0`, package is `0.8.0` — PRE-EXISTING, MEDIUM

`lib/phoenix_kit_catalogue.ex` `def version, do: "0.2.0"` while `mix.exs`
`@version` and the latest Hex release are both **0.8.0**. AGENTS.md mandates the
version be kept in sync across three places (`mix.exs`, the module `version/0`
callback, the compliance test); this is the runtime-accessible `PhoenixKit.Module`
callback, so the module reports a six-minor-versions-stale value. The drift was
introduced by the `0.8.0` release commit (`d498de1`, which bumped `mix.exs` only)
— **not by this PR** — but the compliance test
(`assert PhoenixKitCatalogue.version() =~ ~r/^\d+\.\d+\.\d+/`) is a format-only
regex and cannot catch a value mismatch, so nothing flagged it.

**Recommended fix:** set `version/0` to the current/next release version, and
tighten the test to an exact-string assertion (`== "x.y.z"`) per AGENTS.md, so the
three-places rule is actually enforced. (Deferred to the release decision since
the correct target depends on the version being shipped.)

### 2. Migration is incomplete for cross-view consistency — LOW

The 4 remaining catalogue admin LiveViews — `export_live`, `import_live`,
`pdf_library_live`, `pdf_detail_live` — were **not** migrated; they never used
`<.admin_page_header>`, so they still render via the auto-admin-chrome path. They
each set `@page_title`, so the auto-chrome header still shows a title and there is
**no regression**. The catalogue admin surface now mixes two chrome mechanisms,
though. Worth folding the remaining four into the self-wrap pattern in a later
pass for uniformity. Not fixed here — out of this PR's scope and the views render
correctly as-is.

### 3. Form views lose their explicit "back" affordance — LOW (verify-intent)

The 5 form views previously passed `back={Paths.<parent>()}` to
`<.admin_page_header>`, rendering a back-arrow link to the parent list/detail.
The new `app_layout` wrapper has no back slot, and no in-body back link was added,
so form pages now rely entirely on the global header breadcrumb (`current_path`)
+ sidebar for upward navigation. This matches the adopted core self-wrap pattern
(media/orders behave the same way), so it reads as deliberate. Flagging only to
confirm the global breadcrumb provides equivalent reachability for the
deep-linked form routes. Not "fixed" — adding bespoke back buttons would diverge
from the pattern the PR is standardizing on.

### 4. `catalogues_live` renders an empty toolbar wrapper — NITPICK

The relocated action bar `<div class="flex flex-wrap items-center justify-end
gap-2 mb-2">` has no `:if`; each button inside is individually guarded, so on a
tab/state where no button matches it renders an empty div carrying `mb-2` (a small
dead vertical gap). In practice at least one button shows on every tab, so the
impact is negligible. Could guard the wrapper on "any action visible" if desired.

### 5. `project_title` not threaded to `app_layout` — NITPICK

The `media` reference passes `project_title={@project_title}` (fetched from
settings) for the browser `<title>` / branding; the catalogue views omit it
(defaults to `nil`, with `app_layout` falling back internally). Harmless but an
inconsistency vs. the reference the PR cites.

### 6. Orphaned gettext msgid — NITPICK

The retired `"%{count} events"` msgid remains in `default.pot` and the en/et/ru
`.po` files (now unused). A `mix gettext.extract --merge` pass would mark it
obsolete. Cosmetic cleanup debt only.

## Why no code fixes were applied in this review

The PR contains no actual defects — items 3–6 are either deliberate consequences
of the pattern being standardized or sub-cosmetic, and "fixing" them risks
diverging from the very pattern the PR adopts (over-engineering). Item 1 is a real
bug but pre-existing and coupled to the release version, so it is handled as part
of the release decision rather than silently patched here. Item 2 is a deliberate
scope boundary.

## Verification

- `mix precommit` (compile `--force --warnings-as-errors` + `deps.unlock
  --check-unused` + `hex.audit` + `format --check-formatted` + `credo --strict` +
  `dialyzer`) — see chat for the run result against `main`.
- The `.formatter.exs` has no `Phoenix.LiveView.HTMLFormatter` plugin, so the
  cosmetic HEEX indentation in the diff is not gate-checked and does not fail
  `format --check-formatted`.
- ExUnit is DB-gated (no standalone PostgreSQL here); per AGENTS.md the gate, not
  `mix test`, is the bar for this module.
