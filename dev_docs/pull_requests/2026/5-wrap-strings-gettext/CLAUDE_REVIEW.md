# Code Review: PR #5 — Wrap all user-visible strings in Gettext for translation

**Reviewed:** 2026-04-06
**Reviewer:** Claude (claude-sonnet-4-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/5
**Author:** Max Don (mdon)
**Head SHA:** `23bf936c923bfb79ebfa62920cf5f06825cfb4ef`
**Status:** Merged

---

## Summary

This PR wraps 30+ hardcoded user-visible strings across 8 LiveView/component files in `Gettext.gettext(PhoenixKitWeb.Gettext, "...")`. The stated intent is purely additive: no logic changes, rendered output is identical when no translations are configured. Coverage is broad — button labels, tab labels, status dropdown options, section headers, help text, placeholders, unit abbreviations, and flash messages.

---

## What Was Changed

| File | Strings Wrapped |
|------|-----------------|
| `catalogue_detail_live.ex` | Edit, Active, Deleted, Delete, Restore, Delete Forever, No items in this category. |
| `catalogue_form_live.ex` | Active, Archived, Archived help text, Delete Forever, markup placeholder |
| `catalogues_live.ex` | Active, Deleted (tabs), View, Edit, Delete, Restore, Delete Forever (row menus for catalogues, manufacturers, suppliers) |
| `category_form_live.ex` | Move, Delete Forever |
| `components.ex` | "Search items..." placeholder, "pc", "m²", "rm" unit abbreviations |
| `item_form_live.ex` | Pricing & Identification, Classification (section headers), SKU/price placeholders, Move |
| `manufacturer_form_live.ex` | Name label, name placeholder, Contact & Web, website/logo URL placeholders, Active, Inactive, inactive help text |
| `supplier_form_live.ex` | Same pattern as manufacturer |

---

## Issues Found

### 1. [BUG] `Gettext.gettext/3` runtime function bypasses `mix gettext.extract`

**Files:** All 8 changed files
**Severity:** Medium

The PR uses `Gettext.gettext(PhoenixKitWeb.Gettext, "string")` — the three-argument runtime function — throughout. Elixir's standard tooling for i18n works via the `gettext/1` macro (available after `use Gettext`), which enables `mix gettext.extract` to statically scan source files and produce `.pot` templates. The runtime function does **not** participate in extraction.

This means there is currently no automated way to generate a `.pot` file containing these strings. A translator would need to hand-collect all strings from source, which defeats a major purpose of using Gettext.

The pattern was already established before this PR (all pre-existing Gettext calls in the codebase use the same `Gettext.gettext/3` form), so this PR is consistent with what's already there. But it is worth understanding whether `.pot` extraction from the host app is planned, and whether this library should provide its own `.pot` template.

**Background:** Since this is a reusable library and `PhoenixKitWeb.Gettext` belongs to the host app, the library cannot own a `use Gettext` module. If the host app runs `mix gettext.extract`, it will not find these strings. One resolution is for the library to document its strings in a bundled `priv/gettext/en/LC_MESSAGES/default.po` seed file, or to ship a `PhoenixKitCatalogue.Gettext` module and `priv/gettext/*.pot` and let the host app delegate to it.

---

### 2. [MISS] Three groups of user-visible strings not wrapped

**Severity:** Low

These strings were in scope for this PR (user-visible, in changed files) but were not wrapped:

**a. "Description" field label** — appears identically in two files:
- `manufacturer_form_live.ex:176`: `<span class="label-text font-semibold mb-2">Description</span>`
- `supplier_form_live.ex:176`: `<span class="label-text font-semibold mb-2">Description</span>`

**b. Association toggle hint text:**
- `manufacturer_form_live.ex:296`: `Click to toggle supplier associations.`
- `supplier_form_live.ex:286`: `Click to toggle manufacturer associations.`

**c. Empty-state messages in `catalogues_live.ex`:**
- Line 504: `<p class="text-base-content/60">No manufacturers yet.</p>`
- Line 555: `<p class="text-base-content/60">No suppliers yet.</p>`

All six are straightforward wrapping candidates with no complications.

---

### 3. [CONCERN] `"https://..."` URL placeholder wrapped unnecessarily

**Files:** `manufacturer_form_live.ex:214,236`, `supplier_form_live.ex:214`
**Severity:** Low

The placeholder `"https://"` is protocol syntax, not natural language. Translating it creates maintenance noise (it is unlikely to ever differ across locales) and trains translators to expect URL-scheme strings in their catalogue. Consider leaving URL-format hints as plain strings.

---

### 4. [CONCERN] `"0.00"` numeric placeholder is locale-sensitive but input type="number" is not

**File:** `item_form_live.ex:302`
**Severity:** Low / Worth noting

`"0.00"` is correctly wrapped (decimal format is locale-specific — German uses `0,00`). However, this is rendered as the placeholder of a `type="number"` input. Browsers that handle number inputs natively will ignore the `placeholder` attribute in favour of the browser's locale format, making the translation moot in practice. No code change needed, but this is worth knowing when translating.

---

### 5. [MINOR] `search_input` component's attr default is not wrapped

**File:** `components.ex:90`

```elixir
attr(:placeholder, :string, default: "Search...")
```

The `"Search..."` default value is a raw string. All known call sites pass an explicit Gettext-wrapped placeholder, so users won't see this default. But if the component is used without a `placeholder` argument, it falls back to an untranslated string. Wrapping it is awkward in an `attr` declaration (where Gettext is not available at compile time). The better fix is to make the default `nil` and resolve it inside the component function body, or to document that callers must always supply a translated placeholder.

---

### 6. [MINOR] `"Name *"` required-marker split is correct but inconsistent

**Files:** `manufacturer_form_live.ex:159`, `supplier_form_live.ex:159`

```heex
{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")} *
```

Splitting the `*` out of the translated string is the right approach — it keeps the required marker as structural markup and gives translators a clean "Name" token. However, compare with `item_form_live.ex` where the Name field (wrapped in a multilang component) does not have a bare `*` in the template — it likely uses a `required` prop. The inconsistency is cosmetic but worth unifying.

---

## What Was Done Well

**Comprehensive first pass.** The PR covers a wide surface area without any guide rail other than manual inspection — button labels buried in conditional blocks (`@view_mode == "active"`), strings in function heads (`format_unit/1`), and interleaved template/logic code are all caught.

**Interpolated strings use Gettext binding correctly.** Uses like `Gettext.gettext(PhoenixKitWeb.Gettext, "Edit %{name}", name: catalogue.name)` are correct — the variable is bound via keyword args rather than embedded in the string literal, which allows translators to reorder tokens.

**Plural forms handled properly.** The `Gettext.ngettext/5` call in `components.ex:140` (search result count) correctly uses the plural-aware form. This was pre-existing but the PR didn't regress it.

**No logic changes.** The diff is pure string wrapping. Each `Gettext.gettext/3` call evaluates to the first argument unchanged when no translation catalogue is loaded, so existing behaviour is preserved exactly.

---

## Recommendations

1. **Track the missed strings** (Issue #2) — they are small, unambiguous, and can be done in a follow-up commit.

2. **Decide on `.pot` strategy** — either document that hosts must maintain their own `.pot` file for this library's strings, or add a `priv/gettext/` seed to the package so translators have a starting point. This is the most important architectural question raised by this PR.

3. **Fix the `search_input` default** — change `default: "Search..."` to `default: nil` and handle it inside the component function, or add a note to the docs that `placeholder` must always be supplied.

4. **Consider removing `"https://..."` from the translation surface** — it adds translator noise for no benefit.
