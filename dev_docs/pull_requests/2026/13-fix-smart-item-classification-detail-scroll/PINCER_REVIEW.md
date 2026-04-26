# Pincer Review — PR #13

**Module:** phoenix_kit_catalogue
**Title:** Fix smart-item classification and detail-view scroll
**Author:** mdon
**Files:** 8 changed, +230/-63

---

## Summary

Two related fixes bundled together:

1. **Smart-item classification** — removes the `:if={@catalogue_kind != "smart"}` guard on the Classification section (Category + Manufacturer fields) in `item_form_live.ex`. Smart items can now be assigned categories and manufacturers for organizational purposes, without affecting rule-based pricing.

2. **Detail-view scroll / PubSub storm** — adds `parent_catalogue_uuid` to the PubSub broadcast payload so `CatalogueDetailLive` can filter out events from other catalogues. Previously, every item edit anywhere in the system triggered `reset_and_load` on every open detail page, wiping scroll position and potentially trapping the LV in a spinner during imports.

### Key changes:

- **`PubSub.broadcast/3`** — new third arg `parent_catalogue_uuid`. Backward-compatible default `nil`.
- **`CatalogueDetailLive.handle_info/2`** — pattern-matches on parent UUID; ignores cross-catalogue events. Replaces `reset_and_load` with new `refresh_in_place` that updates counts/category tree without wiping `loaded_cards` or cursor.
- **`log_activity/2`** — gains `opts` keyword list. Supports `broadcast: false` for bulk callers. Pops `parent_catalogue_uuid` from attrs before persisting to activity log.
- **`lookup_parent/2`** fallback — when callers don't thread `parent_catalogue_uuid`, looks it up via DB. One indexed pkey query per broadcast on the "cold" path.
- **`Import.Executor`** — passes `broadcast: false` per row; emits single roll-up `:catalogue` broadcast at end of import.
- **`Rules`** — direct `PubSub.broadcast/3` calls with parent catalogue UUID, with its own `item_parent_catalogue_uuid/1` lookup helper.

---

## What Works Well

- **The core idea is sound.** Adding parent scoping to PubSub is the right fix for cross-catalogue noise. The `refresh_in_place` vs `reset_and_load` split is well-designed — preserving scroll state while keeping counts fresh.
- **Backward compatibility** — `broadcast/3` defaults parent to `nil`, so any callers that haven't been updated still work. The detail LV treats `nil` parent as "defensive refresh" — same as pre-filter behavior.
- **Import optimization** — the `broadcast: false` + roll-up pattern is clean. A 1k-row import going from 1k broadcasts to 1 is a real UX win.
- **Smart-item classification** — small, uncontroversial change. The AGENTS.md update explains the rationale clearly.
- **Type spec updated** — `@type event` now includes the 4-tuple.
- **Documentation** — module docs, comments, and AGENTS.md all updated consistently.

---

## Issues Found

### #1 — MEDIUM: `lookup_parent/2` does a DB query inside broadcast path

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:119-139`

27 of 28 `log_activity` callers don't thread `parent_catalogue_uuid`. Each falls back to `lookup_parent/2`, which issues a DB query. In normal admin usage (one mutation at a time) this is fine — "adds ~ms to mutations on the rare path." But during bulk operations that *don't* go through the executor (e.g., batch API calls, future sync endpoints), this could add up.

**Verdict:** Acceptable for now — the comment explicitly acknowledges the trade-off. High-frequency callers (import executor) already suppress broadcasts. If batch API endpoints are added later, they should follow the same `broadcast: false` + roll-up pattern.

### #2 — LOW: Duplicate `lookup_parent` — once in `Catalogue`, once in `Rules`

**Files:**
- `lib/phoenix_kit_catalogue/catalogue.ex:126-128` — `lookup_parent(:item, uuid)`
- `lib/phoenix_kit_catalogue/catalogue/rules.ex:352-354` — `item_parent_catalogue_uuid(item_uuid)`

Both do the same query: `from(i in Item, where: i.uuid == ^item_uuid, select: i.catalogue_uuid)`. The Rules module calls `PubSub.broadcast/3` directly (bypassing `log_activity`), so it needs its own lookup.

**Verdict:** Minor duplication. Could be extracted to a shared `Catalogue.item_catalogue_uuid/1` helper, but not worth blocking on.

### #3 — LOW: `nil` parent fallback is overly broad in detail LV

**File:** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:109`

```elixir
when kind in [:category, :item, :smart_rule] and
       (parent == catalogue_uuid or is_nil(parent))
```

A `nil` parent is treated as "defensive refresh" — any category/item/smart_rule event with `nil` parent triggers `refresh_in_place`. This means manufacturers/suppliers don't cause refreshes (correct — they have their own handler clauses that don't match), but any unscoped event still hits the detail LV.

**Verdict:** By design — matches pre-filter behavior and handles callers that haven't been updated yet. Good defensive choice.

### #4 — LOW: `handle_info/3` clause ordering — catch-all placement

**File:** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:112-113`

The catch-all `def handle_info(_msg, socket)` is now defined *before* the rescue clause in `handle_catalogue_data_changed/1`. The rescue was previously part of the main `handle_info` clause. This is actually cleaner — the rescue is now in a dedicated private function. No issue.

**Verdict:** Noted as positive restructuring.

---

## Verdict

**✅ APPROVE — clean merge, no blockers.**

The changes are well-designed, well-documented, and backward-compatible. The `refresh_in_place` vs `reset_and_load` split is the right architectural choice. Minor issues (#1, #2) are acknowledged in comments and acceptable for follow-up if they become noisy.
