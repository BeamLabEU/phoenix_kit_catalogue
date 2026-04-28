# Follow-up Items for PR #11

Triaged against `main` on 2026-04-26. Single CLAUDE_REVIEW; verdict
"Approved & merged". Eight minor concerns; no bugs. The reviewer
filed two of these explicitly as "follow-up tickets" (#1, #2 below).

## Fixed (Batch 1 — 2026-04-26)

- ~~**#7** `Tree.build_children_index/1` redundant `Map.new`~~ —
  `Enum.group_by(& &1.parent_uuid)` already returns a map; the
  follow-up `|> Map.new(fn {k, v} -> {k, v} end)` was a no-op. Removed
  in a small precommit-cleanup commit on this branch.

## Fixed (Phase 2 sweep on this branch)

- **#1** TOCTOU in `move_category_under/3` — cycle check runs outside
  the transaction. Phase 2 C6 wraps the check + update in a single
  `Repo.transaction` with `lock: "FOR UPDATE"` on the moved row,
  mirroring `move_category_to_catalogue/3`. Two-admins-on-the-same-tree
  race becomes a serial operation.
- **#2** `swap_category_positions/3` racy across overlapping siblings —
  Phase 2 C6 adds `FOR UPDATE` on both rows inside the transaction
  before the position swap (mirroring move's pattern). Two concurrent
  swaps of overlapping siblings serialise.

## Skipped (with rationale)

- **#3** `validate_parent_in_same_catalogue` always does a DB lookup on
  update — micro-perf. Adding an early return when `:parent_uuid` isn't
  in the changeset's changes is straightforward, but the lookup is
  cheap (single FK + one CTE on the subtree) and runs only on
  category create/update. Tracked, not fixed in this sweep.
- **#4** `restore_category` auto-restores all deleted ancestors — by
  design. Documented in the moduledoc; the alternative ("restore to
  detached state") would leave orphaned nodes invisible in the active
  tree. The UX surfacing concern (admin intentionally trashed parent,
  then restores descendant) is real; pinning a confirmation dialog is a
  UX project, not a code defect. The current activity-log row carries
  `subtree_size` + `items_cascaded` + an implicit
  `restored_ancestor_count` so the audit trail reflects what
  happened. No change.
- **#5** `Attachments.soft_trash_file/1` deliberate duplication of
  `PhoenixKit.Modules.Storage.trash_file/1` — pinned against a
  phoenix_kit version that doesn't expose `trash_file/1` yet. The
  duplication carries an inline comment at `attachments.ex:295-300`
  explaining the bind. Removing the duplication requires a phoenix_kit
  bump; that's a separate ticket. Phase 2 C13 documentation pass adds
  a grep-able `# TODO(phoenix_kit-bump)` so the next bump catches it.
- **#6** JSONB `?::text ILIKE ?` no GIN index — same family as PR #7
  2.3 / PR #9 #4. Out of scope (requires core phoenix_kit migration).
- **#8** `find_folder_by_name` collision surface — defensive prefix
  (`catalogue-item-<uuid>` / `catalogue-<uuid>`) plus UUID uniqueness
  makes collisions impossible in practice. Adding a one-line "this is
  why the prefix exists" comment is bikeshedding; the @moduledoc
  already covers the convention.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/tree.ex` | #7 remove redundant `Map.new` after `Enum.group_by` |
| `lib/phoenix_kit_catalogue/catalogue.ex` | #1 + #2 row-locked cycle check + position swap (Phase 2 C6) |

## Verification

- #7 fix: tree.ex `build_children_index/1` shape unchanged
  (`%{nil => [...], parent_uuid => [...]}`).
- #1 / #2 fixes: Phase 2 sweep includes pinning tests in
  `catalogue_test.exs` (transactional path coverage).

## Open

None.
