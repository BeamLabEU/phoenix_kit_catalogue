# FOLLOW_UP — PR #28 (Catalogue folders, detail drill-down rework, quality sweep)

Triaged against the released **0.3.0** state (PR #28 merged as `49b45e3`;
review follow-ups shipped in `e32e960`, released in `578efa7`).

`CLAUDE_REVIEW.md` recorded two findings it fixed in-line plus three
observations left as-is. Re-verified each against the released code.

## Fixed (pre-existing — closed by the post-merge commit `4afd43f`)

- ~~**#1 — Redundant queries in the index render**~~. `load_data(:index)`
  loads the active folder tree once and threads it into both
  `build_active_rows/2` and `folder_options/1`; per-folder counts are
  derived from the already-loaded `catalogues_by_folder` map instead of
  a separate `GROUP BY`. Verified.
- ~~**#2 — Dead code**~~. `list_child_folders/2` and
  `folder_catalogue_counts/0` (both new in this PR, zero callers)
  removed. Verified.

## Fixed in 0.3.0 review follow-ups (`e32e960`)

The two observations the review left as-is were subsequently **fixed**
in the 0.3.0 review-fixes commit — they were worth addressing after all:

- **Folder-move race** → `move_folder/3` now runs its cycle check +
  target validation + update inside a transaction with `FOR UPDATE` on
  the moved row (`run_locked_folder_move/2`), so a concurrent move can't
  commit a cycle that then vanishes from `list_folder_tree/1`.
- **No folder purge** → `permanently_delete_folder/2` added (+ the
  `handle_event` and a deleted-view "Delete" action). It re-roots child
  folders and unfiles catalogues before deleting the row, closing the
  gap where a trashed folder could never be removed.
- Plus a reorder status guard and query trims in the same commit.

(Earlier triage classified the move race + missing purge as benign /
out-of-scope; the maintainer fixed both in 0.3.0. Recording the actual
resolution here, per the "after-action, not deferral" convention.)

## Reviewed — remaining as-is

- **Self-echo reload** — the index LV reloads on its own folder
  broadcast (one redundant, idempotent `load_data` on an admin-only
  page). The lightweight `{:catalogue_data_changed, …}` events carry no
  `from`-pid by design; adding one touches the shared topic contract
  across four LVs for no user-visible gain. Not fixed in 0.3.0; left as
  a documented non-issue.

## Verification

| Check | Result |
|---|---|
| #1 single active-tree load + derived counts | confirmed in 0.3.0 |
| #2 `list_child_folders/2` / `folder_catalogue_counts/0` removed | confirmed |
| folder-move `FOR UPDATE` lock (`run_locked_folder_move/2`) | confirmed in `e32e960` |
| `permanently_delete_folder/2` present | confirmed in `e32e960` |

## Open

None.
