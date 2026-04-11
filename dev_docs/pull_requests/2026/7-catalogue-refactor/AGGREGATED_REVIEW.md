# Aggregated Review — PR #7: Catalogue refactor

**Date:** 2026-04-11
**Reviewers:** Pincer 🦀, Claude (Anthropic)

---

## Verdict: ⚠️ Approve with bugs to fix

Two real bugs found that should be addressed before release. The rest is solid.

---

## Bugs (HIGH — should fix)

| # | Issue | Location | Source |
|---|-------|----------|--------|
| 1 | **`next_category_position` called outside transaction** — race condition: two concurrent moves to same catalogue can get the same position | `catalogue.ex:1170` | Claude |
| 2 | **`move_item_to_category` missing `FOR SHARE` lock** — can read stale `catalogue_uuid` if category is being moved concurrently. `create_item` has the lock but moves don't | `catalogue.ex:1797` | Claude |
| 3 | **`confirm_delete!` MatchError crash** — `{"item", uuid} = confirm_delete!(socket)` crashes the LiveView process if confirm state holds a different entity type | `catalogue_detail_live.ex:167, 251` | Claude |

---

## Design (MEDIUM — should address or document)

| # | Issue | Source |
|---|-------|--------|
| 4 | **`restore_catalogue`/`restore_category` over-restores** — restores ALL deleted items, including ones individually deleted before the catalogue was trashed. Document intent or add cascade tracking | Claude, Pincer |
| 5 | **`load_filter_options` fetches 1000 rows** for dropdown options instead of `SELECT DISTINCT`. Scales poorly | Claude |
| 6 | **`reset_and_load` fires 5-6 sequential queries** on every mutation — could be consolidated into 1-2 queries | Claude |
| 7 | **`actor_opts/1` duplicated across 7-8 LiveViews** — extract to shared helper | Pincer, Claude |
| 8 | **`InfiniteScroll` JS hook inlined in 2 LiveViews** — should be in shared JS bundle | Pincer, Claude |
| 9 | **JSON data field searched as raw text** via `?::text ILIKE ?` — unindexable, matches JSON punctuation | Claude |

---

## Low Priority / Nitpicks

- `deleted_count_for_catalogue` issues 2 sequential queries where 1 would suffice
- `log_activity` silently discards errors — no audit trail on failure, caller never knows
- No concurrency tests for the `FOR SHARE`/`FOR UPDATE` locking strategy
- Some error branches in handlers return socket without reloading data (potential stale state)

---

## Recommendation

**Bugs 1-3 should be fixed before release.** Bug 1 and 2 are real concurrency issues — low probability but data corruption when they hit. Bug 3 is a crash edge case.

The over-restore behavior (#4) is a design decision that should at least be documented. Items 5-8 are maintainability/performance improvements for a follow-up PR.

The test coverage is excellent and the overall architecture is sound. These are fixable issues in an otherwise well-executed refactor.
