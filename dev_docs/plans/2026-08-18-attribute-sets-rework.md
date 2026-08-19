# Attribute rework: groups → sets on the entities engine

Status: **design approved for build** (Max, 2026-08-18; product direction
from the boss). Panel-reviewed (Gemini 3.1 Pro, Gemini 3.7 Flash, Grok 4.3
+ Claude synthesis, 2026-08-18) — 3-of-4 for the chosen model, unanimous on
the join, guards, read path, and migration shape.

## Product direction (fixed, not up for debate)

1. **Groups die; the unit becomes a SET** — one dimension from one vendor:
   "Ikea colors", "HomeDepot colors", "Ikea widths". Today's
   AttributeGroup→Attribute→Value hierarchy collapses one level.
2. **Items attach MULTIPLE sets** (a door gets "Ikea colors" + "Ikea
   widths"). Today an item holds at most one group.
3. **Storage moves to the entities module** (runtime content-type engine)
   so an admin can later add "price per liter" / "drying time" to a
   color value as just another field — no code, no migration.

## Chosen architecture

### A set = one managed entity blueprint; its records = the values

("Provisioned Model A".) Each set is its own `phoenix_kit_entities`
blueprint, created ONLY through the catalogue's set-management UI from a
locked template — never via the generic "New entity type" flow.

Blueprint contract:

| Piece | Where | Notes |
|---|---|---|
| Set identity | blueprint `name` slug, `catalogue_set_` prefix | Immutable once any item attaches or any order line references it |
| Set display name | blueprint `display_name` (+ `settings.translations`) | Freely renameable |
| Kind `fixed \| multi` | `settings["catalogue"]["kind"]` | Same semantics as today: fixed = shown on card; multi = one value picked per order line |
| Default value | `settings["catalogue"]["default_value_slug"]` | Single slot — enforces "at most one default" structurally (better than N per-value booleans) |
| Managed marker | `settings["catalogue"]["managed"] = true` + `locked_keys` | Drives the entities-side guard (below) |
| Value identity | data record `slug` (unique per blueprint) | The stable key translations can never break; frozen once referenced |
| Value display text | record `title` (+ multilang data) | |
| Value ordering | record `position` (blueprint `sort_mode: "manual"`) | |
| **Extras** (price/liter, drying time, …) | blueprint `fields_definition` | The ONLY thing admins add freely — the whole point of the move |

Rejected alternatives, so nobody re-litigates them:
- **Shared value blueprint (Model B)** — per-set extras become
  all-values-everywhere fields; kills the rationale. Panel verdict: if
  per-set blueprints prove unworkable, STOP and keep catalogue tables
  with a JSONB extras column — never ship B as a compromise.
- **Blueprints per semantic shape** (`color_value`, `dimension_value`,
  Gemini Pro's Model C) — reintroduces cross-vendor schema coupling one
  level down + a "which shape?" taxonomy nobody asked for.

Blueprint-proliferation mitigations: the `catalogue_set_` namespace; the
managed marker **hides these blueprints from the generic entities admin**;
managed blueprints are **exempt from `entities_max_per_user`** (entities-
side change, part of prerequisites). Fallback if exemption is refused:
lazy-fork (sets start on one shared blueprint, fork on first extra field)
— documented, not planned.

### Item ↔ set attachment: catalogue-owned join table

New table (core migration chain — catalogue ships no migrations):

```
phoenix_kit_cat_item_attribute_sets
  item_uuid   uuid  FK → phoenix_kit_cat_items ON DELETE CASCADE
  set_uuid    uuid  (entities blueprint uuid — no cross-module FK; see guards)
  position    integer                     -- display order of sets on the item
  data        jsonb NOT NULL DEFAULT '{}' -- reserved for future per-attachment
                                          -- state (see Future directions)
  UNIQUE (item_uuid, set_uuid)
  INDEX (set_uuid)
```

- **UUID, never slug** — slugs persist until someone "fixes" `ikea-colrs`.
- **Not an entities record** — relations are unimplemented in entities;
  a JSONB pseudo-join would mean unindexed scans and no uniqueness/FK.
- `data` costs nothing now and absorbs every currently-known future
  feature without another migration (selected value, per-item value
  availability — below).

### Contract enforcement: write path, not UI ("UI guards are theater")

Two independent layers:

1. **Entities-side** (in `phoenix_kit_entities`): the write path
   hard-errors on any mutation of a managed blueprint that touches
   `locked_keys`, renames the slug, deletes a value record whose slug is
   referenced, archives, or deletes the blueprint while attachments
   exist. The generic admin UI additionally hides managed blueprints,
   but the interceptor is the guarantee.
2. **Catalogue-side** (`Catalogue.AttributeSets.Contract`): every resolve
   and every catalogue write validates the blueprint contract (kind
   present and valid, default slug exists among records, slug shape).
   Broken contract → `{:error, :contract_broken}` surfaced loudly —
   never a guessed fallback.

Deletion safety: blueprint delete cascades `entity_data` (core FK), so
the entities-side guard blocks deleting attached sets, AND the catalogue
subscribes to entities PubSub to clean orphaned join rows if anything
slips through (belt and suspenders).

### Read path: batch by distinct set; no cache on day one

Values are shared across items — a 50-item page with 6 distinct sets is
**7 queries** (one for attachments, one `list_by_entity` per distinct
set), not M×N. `resolve_for_items/2` assembles per-item shapes in the
context, same pattern as `attached_file_counts/1`. An ETS per-set cache
(invalidated by entities PubSub) is specced but deliberately deferred
until a resolve path measures hot: attribute data is reference data, and
day-one caching buys test pain and stale reads.

### Consumer contract v2 (product card + parent app)

```elixir
%{schema_version: 2,
  sets: [%{key: "catalogue_set_ikea-doors-color", kind: :multi,
           name: "Ikea colors",           # locale-resolved
           default: "oak",
           values: [%{key: "oak", label: "Oak", extras: %{"price_per_liter" => ...}},
                    ...]}]}
```

**Version the pick, not the tree**: order lines store `{attr_key,
value_key}` today. Migration preserves both keys (below), so existing
picks resolve under v2 unchanged. `resolved_group/2` remains as a
v1-shaped shim during dual-run, then deprecates.

## Prerequisites (entities module, before the build)

1. Fix the two known locale bugs flagged in the 2026-08-17 language
   sweep: `get_entity(..., lang:)` exact-key lookup (needs the same
   base-code fallback core Multilang got) and `data_form`'s
   URL-shape/locale mixing.
2. Managed-blueprint write interceptor + generic-UI hiding (layer 1
   above).
3. `entities_max_per_user` exemption for managed blueprints.
4. PubSub events on blueprint/record mutations (verify coverage — the
   catalogue's cleanup and future cache both key off them).
5. `entities_enabled` defaults **false** → catalogue treats a disabled
   entities module exactly like the missing `catalogue_pdf` queue:
   declared dependency, doctor check, loud actionable error.

## Migration

Volumes are small; copy in place, dual-run the READ path only.

1. Each `(group, attribute)` pair → one set blueprint, slug
   `catalogue_set_<group-slug>-<attr-key>` (unique because attr keys are
   unique per group). Boss renames display names ("Ikea doors — Color" →
   "Ikea colors") at leisure; slugs stay.
2. Attribute values → data records; **record slug = old value key**
   (unique within attribute ⇒ unique within set). Old `is_default` →
   `settings.catalogue.default_value_slug`. Ordering → positions.
3. Each item's single group assignment **explodes** into one attachment
   per attribute of that group, positions preserved — nothing an item
   shows today is lost.
4. Old tables (`cat_attribute_groups`/`cat_attributes`/
   `cat_attribute_values`/`cat_item_attribute_groups`) go read-only;
   `resolve(item, version: 1 | 2)` behind a cutover flag;
   shadow-compare v1 vs v2 on max-dev; flip; drop the tables one release
   later.
5. PRO100 pseudo-item migration ("Цвет"/"Кантик"/"Толщина" rows) stays
   **out of scope**, per the original L028 boundary.

## UI work

- **Set management** replaces the attribute-groups page: list of sets
  (name, vendor-ish grouping via name, kind, value count, usage count),
  a set editor driving the entities API underneath (values with drag
  order, default star, per-set extra-field management → delegates to the
  blueprint's field editor), archived semantics as today.
- **Item form Attributes tab**: single-group select → multi-set picker
  (attach/detach/reorder), read-only preview of resolved values per set.
- **Product card**: renders N sets instead of one group — mostly the
  existing markup in a loop; extras render as label/value rows.

## Future directions (explicitly NOT in this build)

Recorded so the schema above visibly anticipates them.

1. **Per-item value availability** ("Ikea offers 5 colors; only 3 in
   stock for this door"): attachment-level state →
   `data["disabled_value_slugs"] = [...]` on the join row. Resolve
   filters them per item; set stays untouched. Zero-migration when its
   turn comes.
2. **Current selection on an item** ("this door IS red with gold trim" —
   *possibly the next iteration*): attachment-level state →
   `data["selected_value_slug"]` on the join row. This is per-item
   *state*, distinct from the order-line *pick* (which belongs to the
   parent app); the card can badge the selected value. Also
   zero-migration.
3. **Variant/combination generation** (3 colors × 3 sizes → 9 combos,
   each with its own image/price/SKU): a genuinely separate feature.
   Sketch: a per-item variants table keyed by the item + the **sorted
   `{set_slug, value_slug}` pair list** (canonical combo identity that
   survives set/value renames), each row carrying overrides (price,
   image via storage, SKU). Generation is a bounded fan-out with an
   explicit cap (5×5×5 is 125 rows — warn before generating). Do NOT
   model combos as entity records: they're per-item, high-count, and
   relational. When this lands, the attachment `data` may grow
   `variant_dimension: true` to mark which sets participate.

## Risks

- **Central risk (unanimous):** a hard domain contract living in a
  relation-less CMS. The write interceptor + catalogue-side validation +
  UUID join ARE the mitigation; they are not optional garnish.
- Entities module is co-owned — the prerequisite changes need
  coordination (PRs to `phoenix_kit_entities`, boss releases).
- The parent app's order-line flow must adopt the v2 resolve at cutover
  (shape change is additive; picks unchanged).
