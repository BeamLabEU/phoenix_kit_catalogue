# PR #78 — Grok review

**Reviewer**: Grok (xAI, `grok -p`, no tools)
**Scope**: Design of the Duplicate action, with excerpts of duplication.ex
**Date**: 2026-08-24
**Method**: Design questions answered from excerpts (grok bails on large diffs)

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

**(1) First bite: SKU, then shared files, then names. Concurrent positions last.**

SKU copied as-is. Failure: every Duplicate yields two live rows with the same SKU. Search, Pro100/Universal export, supplier matching, and “find by SKU” immediately go dual. If you later add a unique index, bulk Duplicate starts failing on *every* row. This is the daily one.

Files are aliases (`FolderLink` to files still homed in the source folder). Failure: trash/purge the original (or empty/purge its home folder). Storage deletes files with that home; the copy’s “own” attachments and the copied featured-image UUID vanish. Unlink-from-copy is safe; delete-original is not. Won’t show up on day one, will on first cleanup.

`"(copy)"` is English, written into every language map, and stacked on re-duplicate (`"Uks (copy) (copy)"`). Ugly in et/ru, not data loss. Child categories/items keeping names is correct.

`place_item_after` SELECTs all non-deleted siblings with no `FOR UPDATE`, then N `update_all`s. Two admins duplicating (or one duplicate + one drag-reorder) both compute 1..n; last commit wins; copies share positions or the other reorder is wiped. Rare in a small admin, catastrophic in a fat category (rewrites the whole sibling list per copy).

**(2) Missed vs a conventional catalogue copy**

- New SKU/slug/barcode (or a unique suffix).  
- Own file bytes or a copy-home, not links into the source home; featured-image pointer is the same shared UUID.  
- Force `status: "active"` — `@item_fields` copies archived/deleted.  
- Always allocate a new files folder. `files == []` skips `put_folder_pointer!`; if `copy_data` left `files_folder_uuid`, the copy keeps the source folder and the next upload writes into the original.  
- Per-item attribute *values* if they are not the set/group join rows.  
- PDF-library / related-item / external-id rows, if those exist.  

Current-only supplier rows, fresh comment threads, no activity/comments: correct.

**(3) Per-source + best-effort is right for 50**

All-or-nothing: item 47 hits a unique/rule/storage error and rolls back 46 good copies. Users retry blind. Duplicate-selected is 50 independent intents; a category tree is already one transaction. Emit a per-uuid error list and one PubSub after the loop. Cost: partial sibling order if some fail — acceptable.

**(4) Ecto**

`insert(cs, on_conflict: :nothing)` on conflict returns `{:ok, _}`, not `{:error, cs}`. The `rollback` arm never runs for dup links; conflicts are swallowed. `:nothing` and rollback are opposite policies. Drop `:nothing` or treat `{:ok, %{uuid: nil}}`.

`Repo.rollback/1` only works inside `transaction/1`. Fine if bulk always wraps; a bare `copy_item` raises.

`update_all` *does* roll back with the transaction. That part is fine. It skips validations/`updated_at`. The bug is the unlocked SELECT. `FOR SHARE` is wrong: two duplicators can both hold it and both renumber. Use `FOR UPDATE` on the sibling rows (or an advisory lock on the parent).

Inserting the copy at `source.position` *before* renumber: any unique `(catalogue, category, position)` index raises `ConstraintError` (not a changeset) and the UI gets a 500. If Storage folders commit on another Repo/path, a later rollback orphans folders.
