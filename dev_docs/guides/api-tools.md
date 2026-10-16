# Shop API tools

The catalogue's part of the shop API: eight admin tools that core's API layer (keys, scopes, rate limits, JSON Schema validation, the confirmation flow for dangerous operations, the REST and MCP transports) serves. This module declares the tools and owns the data rules; it does no authentication of its own.

## The tools

| Tool | Scope | What it does |
|---|---|---|
| `catalogue.list_products` | `catalogue.products:read` | One catalogue's items, oldest change first, keyset pages (`cursor`), exact `count`, filters `category_id` `status` `q` (name, description, sku) `updated_since` (inclusive) `include_deleted` |
| `catalogue.get_products` | `catalogue.products:read` | Up to 50 items by reference; `fields` picks what comes back; shop fields only with `ecommerce.prices:read` |
| `catalogue.create_products` | `catalogue.products:write` | Up to 500 items; never overwrites (`skipped` + `already_exists`); no price, not visible in the shop |
| `catalogue.update_products` | `catalogue.products:write` | `{ref, changes}` pairs: name, description, sku, external_id, category, status, unit, attribute values |
| `catalogue.set_translations` | `catalogue.products:write` | Per language: name, description, slug, SEO title and description |
| `catalogue.delete_products` | `catalogue.products:delete` | To the trash, never hard delete; **always** needs confirmation |
| `catalogue.list_categories` | `catalogue.categories:read` | The category tree |
| `catalogue.upsert_categories` | `catalogue.categories:write` | Create or update by id or external_id, in order; an id with `external_id: null` clears the link |

All need the role permission `catalogue` as well; core checks both on every request.

## References, catalogues, batches

- A **reference** is `{"id"}`, `{"sku"}` (items) or `{"external_id"}`; exactly one key. `sku` is not unique: several matches answer `ambiguous_ref` with the candidate ids. `external_id` lives at `data["api"]["external_id"]` and is unique per catalogue among live rows (the V5 indexes). Resolution is `PhoenixKitCatalogue.API.resolve_refs/2` (sibling modules use it too). Nothing else belongs under `data["api"]`: `Duplication` reads any short key there as a language bucket.
- A tool works in one **catalogue**: `catalogue_id`, required when the install has more than one active standard catalogue (`API.resolve_catalogue/2`). Smart catalogues are not available.
- A batch answers `{"results": [row], "summary": {action => n}}`; a row is `{"ref", "action", "id"}` plus `"error": {"code", "message", "context"}` when it failed. Actions: `created updated unchanged skipped removed found error`. **A bad row never stops the others.**
- Hard caps: 500 rows per write, 50 references for `get_products`, 100 per page.
- **Dry run.** With `ctx.dry_run?` a write handler changes nothing and returns `{:preview, %{"rows" => ..., "summary" => ...}, fingerprint}`; the fingerprint follows the current values the operation touches, so the confirmation flow can tell that state moved between preview and confirm.

## Confirmation

`delete_products` always, and any write call with more than `api_confirm_batch_over` rows (default 50), answers `{"executed": false, "status": "confirmation_required", "preview": {...}, "confirm_token": ..., "expires_at": ..., "expires_in_seconds": ...}` (the code lives `api_confirm_ttl_seconds`, default 120 s); the same call plus `confirm_token` runs. `dry_run: true` on any write tool answers `{"executed": false, "dry_run": true, "preview": {...}}` and never creates a code. A key with `requires_approval` gets `status: "pending_approval"` and an `approval_id` instead (`system.get_approval`). A 500-row import therefore takes two calls with the default setting. The threshold is core's: the tools declare only `danger: :always` on `delete_products`.

## What the tools never touch

`base_price`, markup, discount and raw `data` are not in any input schema, at any depth (a test walks them). In the catalogue source `base_price` is the shop price and is written only by the e-commerce tools. Writes own **paths**, not whole keys: `update_item/3`'s `:data_owned_paths` deep-merges only the named leaves under a row lock, so a price write and a Shopify sync cannot lose each other's keys.

## Context features the tools are built on

All are options of the ordinary context functions and are useful without the API:

- `Catalogue.update_item/3` and `update_category/3`: `:data_owned_paths` (apply the update to the row locked `FOR UPDATE`; copy only these `data` paths), `:logged_data_paths` (these paths appear in the entry's `changes` as `data.a.b`), `:log_metadata` (merged into the entry's metadata; the entry's own keys win). `create_item/2`, `trash_item/2`, `restore_item/2`, `create_category/2`, `move_item_to_category/3` take `:log_metadata` too.
- `slug` is a logged field: `changes` has `slug.<lang>` entries, so a changed slug leaves the old one in the log.
- `Catalogue.update_items/2`: many rows, one transaction, rows independent (savepoints), one `Activity.log_many/2` insert, one `{:catalogue_bulk_change, catalogue, :updated, uuids, from}` broadcast; after the commit the media folders of the rows that changed follow their renames and moves in one pass (`MediaFolders.follow/2`), and a row that failed leaves its folder alone. Inside a caller's own transaction (the price, availability and image writes of the e-commerce API do this) the activity entries, their announcement and the bulk events go out before that transaction commits (`broadcast: false` holds back the catalogue events), and a failing activity insert or folder statement, which run without a savepoint, can abort the caller's transaction while the call still answers `{:ok, _}`.
- `Catalogue.move_item_to_category_deferred/3` leaves the folder step to the caller: it returns the `{before, moved}` pair (`before` is the row the move locked), and the caller passes the pairs of all its moves to `Catalogue.follow_moved_items/2` once, which re-reads the moved rows first. `update_products` moves its items that way, so N moves are one folder pass, and it runs the pass in an `after`, so a row that raises does not leave the earlier moves' folders behind.
- A rename costs about 12 queries and 2 advisory locks per record in the folder pass (`MediaFolders.follow/2` renames one folder at a time); a plain move is one `UPDATE` for the group. 100 renames through `update_items/2`: 1,209 queries, 187 ms, against 206 and 37 ms with the layout off (settings cache running). A 500-row rename, the cap, is some 6,000 queries after the commit, inside the request.
- `Catalogue.trash_item_outcome/2` tells whether this call trashed the item (`:trashed`) or found it in the trash already (`:already_trashed`); `delete_products` answers `unchanged` for the latter. A trash (`delete_products`) leaves an item's folder where it is, as in the admin; creating a record makes no folder.
- `Catalogue.preview_item_update/3`: the diff `update_item/3` would log, without writing.
- `Catalogue.list_items_keyset/1`, `count_items_matching/1`, `decode_items_cursor/1`: keyset paging for exports.
- `{:error, :external_id_taken}` from `restore_item/2`, `restore_category/2`, `restore_catalogue/2` when a live row took the id of a trashed one; `bulk_restore_items/2` restores none of such a batch and answers `{:error, :external_id_taken}`; so do `move_item_to_catalogue/3` and the bulk moves. Copies (`duplicate_*`) never carry `data["api"]["external_id"]`.

## The log

Every API write is logged by the context, with the key owner as actor, `mode: "auto"` and metadata `via: "api"`, `key_prefix`, `request_id`, `tool` (and `approved_by_uuid` for an approved operation). The diff has the usual shape `changes: %{field => %{from, to}}`. Entries follow the install's Activity retention (90 days by default).

## Adding a tool

1. A schema in `API.Schemas` (only the keywords core's validator implements; close every object), a handler `API.<Verb>.call/2`, an entry in `API.Tools.all/0`.
2. Resolve the catalogue with `API.resolve_catalogue/2` and references with `API.resolve_refs/2`; write through the `Catalogue` facade with `Common.write_opts/3`; never pass `base_price`, markup or raw `data`.
3. A write handler supports `ctx.dry_run?` (preview + fingerprint) and answers per-row results.
4. Tests through `PhoenixKitCatalogue.Test.ApiCase.call/3`, which validates the input like the executor does. Add the tool to `tools_conformance_test.exs`.
