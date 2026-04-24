# PR #12: Tabs + metadata on Catalogue form, featured image on Category form

**Author**: @mdon (Max Don)
**Reviewer**: @fotkin (Dmitri)
**Status**: Merged
**Merge commit**: `20148f9` (content: `a1886c4` on mdon/main)
**Date**: 2026-04-24
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/12

## Goal

Brings the Catalogue form up to parity with the Item form (tabs + metadata + featured image + files) and gives Category a lightweight featured-image card. Extracts the shared wiring so all three forms share one implementation.

1. **Catalogue form** — Details / Metadata / Files tabs; featured image + attached files moved into Files tab.
2. **Category form** — adds a featured image card (no tabs, no file grid — a category is a taxonomy node).
3. **`ItemMetadata` → `Metadata`** — resource-type scoped `definitions/1`. Items keep `color / weight / width / height / depth / material / finish`; catalogues get `brand / collection / season / region / vendor_ref`.
4. **Shared helpers** — `Metadata.build_state/2`, `absorb_params/2`, `inject_into_data/3` (pure form-state) + `Components.featured_image_card/1` + `Components.metadata_editor/1` replace ~150 lines of duplication across the three form LVs.
5. **`Attachments.folder_name_for/1`** — new `%Category{}` clause (`catalogue-category-<uuid>`). Folders are created lazily on first picker open, so categories without a featured image never materialize one.

## What Was Changed

11 files, +1289 / −618.

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/metadata.ex` | **New** (replaces `item_metadata.ex`). Adds `definitions/1` (resource-type dispatch), `build_state/2`, `absorb_params/2`, `inject_into_data/3`. Legacy-key safe — values stored under a no-longer-defined key surface as read-only rows so a code change can't silently wipe data |
| `lib/phoenix_kit_catalogue/item_metadata.ex` | **Deleted.** Replaced by `metadata.ex` |
| `lib/phoenix_kit_catalogue/web/catalogue_form_live.ex` | `+271 / −231`. Adds tab strip (`switch_tab` event, `current_tab` assign), metadata handlers (`add_meta_field`, `remove_meta_field`, `absorb_meta_params` in validate + save), attachments wiring. Files tab hosts the inline upload dropzone previously unique to `ItemFormLive`. Panels stay in DOM (toggled by `hidden`) so multilang + user input survive tab switches |
| `lib/phoenix_kit_catalogue/web/category_form_live.ex` | `+54 / −1`. Adds featured-image card above the main form; wires `open_featured_image_picker` / `clear_featured_image` + `close_media_selector` and the `:media_selected` / `:media_selector_closed` `handle_info` pair. No `allow_attachment_upload` call — categories only carry a featured image |
| `lib/phoenix_kit_catalogue/web/components.ex` | `+321 / −0`. Adds `featured_image_card/1` (thumbnail + name + size card, or dashed empty state + primary button) and `metadata_editor/1` (heading + per-key text input + remove button + add-picker dropdown; legacy keys render disabled + "Legacy" pill). Add-picker cycles its DOM id with `length(attached)` so morphdom replaces the element on each add (avoids "stuck selection") |
| `lib/phoenix_kit_catalogue/web/item_form_live.ex` | `+24 / −299`. Thinner — featured-image card + metadata editor now render via the shared components; resource type is `:item` for the Metadata calls |
| `lib/phoenix_kit_catalogue/attachments.ex` | `+7 / −3`. `folder_name_for/1` gets a `%Category{}` clause returning `{:ok, "catalogue-category-<uuid>"}` |
| `test/metadata_test.exs` | **New.** 27 unit tests covering `definitions/1` (item / catalogue separation, non-empty labels), `definition/2`, `cast_value/2` (trim, blanks → nil, non-binary → nil), `build_state/2` (known-first / legacy-alphabetized ordering, struct input, malformed shapes), `absorb_params/2` (attached-only, no-meta no-op, missing-key preservation), `inject_into_data/3` (blank drop, legacy pass-through, existing data preservation, non-map `data` normalization) |
| `test/web/components_test.exs` | `+127 / −0`. 7 tests for `featured_image_card/1` (set / empty / subtitle override / custom class) + `metadata_editor/1` (empty state / attached rows / legacy pill) via `render_component/2` |
| `AGENTS.md` | `+11 / −6`. Reflects the new form structure and component names |
| `README.md` | `+7 / −7`. Updates form feature list |

### Behavior matrix

| Resource  | Tabs                        | Featured image | Files grid | Metadata       |
|-----------|-----------------------------|----------------|------------|----------------|
| Catalogue | Details / Metadata / Files  | ✓              | ✓          | ✓ (5 fields)   |
| Category  | —                           | ✓              | —          | —              |
| Item      | Details / Metadata / Files  | ✓              | ✓          | ✓ (7 fields)   |

### No migrations needed

All three schemas already have JSONB `data`; `featured_image_uuid`, `files_folder_uuid`, and `meta` all live under that column. Pure application-layer refactor.

## Review Findings

### Strengths

- **Well-tested.** 27 pure unit tests + 7 component tests land with the PR. The `Metadata` three-phase API (`build_state` → `absorb_params` → `inject_into_data`) is factored specifically for unit testability: no DB, no socket, no LV lifecycle — just map-in / map-out.
- **Legacy-key safety is deliberate.** Dropping a definition from `Metadata.definitions/1` surfaces stored values as read-only "Legacy" rows rather than silently nuking them on next save. The `add_meta_field` handler also guards against stale client payloads (`Metadata.definition(:item, key)` → `nil` → `:noreply` unchanged socket) so a dropped-then-re-submitted key can't resurrect itself.
- **Clean rename.** `ItemMetadata` → `Metadata` with resource-type dispatch. No stale references remain in `lib/` or `test/`.
- **Good deduplication.** `featured_image_card/1` and `metadata_editor/1` replace ~150 lines across three forms. Component attrs are typed; moduledocs list the required events so the owning LV knows exactly what to wire.
- **Tab UX detail.** Panels stay in the DOM (toggled via the `hidden` class) so the multilang wrapper + in-progress user input survive tab switches. Save button sits outside the tab panels so it works from any tab. Save is disabled while uploads are mid-flight to prevent racing `handle_progress` against the save path.
- **No migrations.** Confirmed — `Catalogue`, `Category`, `Item` schemas all have `field(:data, :map, default: %{})`.

### Findings

1. **`CategoryFormLive` pays for file-grid queries it never renders** (`category_form_live.ex:90`).
   `Attachments.mount_attachments/2` → `assign_files_state/1` → `compute_files_list/1` → `list_files_in_folder/1` (DB query). The category form has no files grid, so `files_state` is never read in render. Wasted query on every Category form mount. Options:
   - Opt-out flag on `mount_attachments/2` (e.g. `files_grid: false`).
   - Separate `mount_featured_image_only/2` helper that skips `assign_files_state`.
   - Cheap short-circuit inside `compute_files_list/1` when the resource is a `%Category{}`.

   Not blocking — categories are rarely edited — but it's a free win.

2. **Iron Law: DB queries in `mount/3`** (preexisting, amplified).
   All three form LVs hit the DB in `mount/3` (`get_catalogue`, `get_category`, `list_catalogues`, `list_categories_for_catalogue`, `list_category_tree`, `Attachments.mount_attachments/2`). `mount/3` runs twice (HTTP dead render + WebSocket connect), so every query runs twice. `CategoryFormLive` now also pays this cost via `mount_attachments`. The Phoenix idiom is to seed assigns in `mount/3` and defer DB work to `handle_params/3`. Out of scope for this PR; flagging as a broader refactor for the next round.

3. **`metadata_add_options/2` + label lookups rebuild on every render** (`components.ex:304`).
   `Metadata.definitions/1` re-evaluates 5–7 `Gettext.gettext/2` calls each render. Negligible in practice, but could memoize via `assign_new` if this panel ever grows.

4. **`render_legacy_metadata_row` uses `<.input ... disabled>`** (`components.ex:361`).
   Renders as a disabled-looking text input. Functionally fine (disabled inputs don't post, so no save-path surprise), but a read-only presentation (span or `<code>`) might signal "this is archived data" more clearly. Style preference.

5. **`@files_grid_limit = 200` silently truncates** (`attachments.ex:513`).
   Preexisting from PR #11. With Catalogue folders now in play (and the folder potentially containing hundreds of brochures / spec sheets), a "+N more" indicator in the Files tab would help users spot when the grid isn't showing everything. Future-work item.

6. **Metadata add-picker sits inside the outer form.**
   The `<.select name="key" phx-change="add_meta_field">` in `metadata_editor/1` is nested inside `<.form for={@form} phx-change="validate">`. On change, LiveView fires the select's own `phx-change` (not the form's) — verified behavior. On form submit, the select's value would also appear in params as `%{"key" => ...}`, but the save handler only reads `params["catalogue"]` / `params["meta"]`, so the stray key is harmless. Flagging because it's non-obvious; no action needed.

### Verdict

**Nothing blocking.** The findings are either preexisting (Iron Law, grid-limit truncation) or minor polish (category file-grid query, legacy row styling). The metadata extraction is the meat of the PR and it's clean: pure helpers, resource-scoped definitions, legacy-key safety, full test coverage. The component extraction matches the existing item form's UX 1:1.

Ready as-is. Finding #1 (skip `assign_files_state` for category forms) is the smallest concrete follow-up if a cleanup commit is warranted.
