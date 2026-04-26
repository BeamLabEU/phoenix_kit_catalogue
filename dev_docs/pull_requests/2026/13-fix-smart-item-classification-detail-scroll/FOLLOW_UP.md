# Follow-up Items for PR #13

Triaged against `main` on 2026-04-26 after the upstream merge
(commit `6887741`). Single PINCER_REVIEW (also captured in
`AGGREGATED_REVIEW.md`); verdict "✅ APPROVE — clean merge, no
blockers". Four findings, all acknowledged in code by the PR itself.

## No findings (acknowledged-in-code)

- ~~**#1 (MEDIUM)** `lookup_parent/2` does a DB query inside the
  broadcast path~~ — `lib/phoenix_kit_catalogue/catalogue.ex:119-139`.
  The reviewer's verdict: "Acceptable for now — the comment explicitly
  acknowledges the trade-off. High-frequency callers (import
  executor) already suppress broadcasts." Re-verified the inline
  comment is present + the executor still passes `broadcast: false`
  per row + rolls up a single `:catalogue` broadcast at the end of
  import. No action needed.

- ~~**#2 (LOW)** Duplicate `lookup_parent` between
  `Catalogue` and `Rules`~~ — minor duplication; the Rules module
  bypasses `log_activity` so it needs its own lookup helper. Reviewer
  verdict: "Could be extracted to a shared
  `Catalogue.item_catalogue_uuid/1` helper, but not worth blocking
  on." Re-verified the duplication exists at
  `catalogue.ex:126` and `catalogue/rules.ex:352`; the duplication is
  semantic (both fetch `item.catalogue_uuid` for an item UUID). No
  action — flagging for the next sweep if the helper count grows.

- ~~**#3 (LOW)** `nil` parent fallback is overly broad in the detail
  LV~~ — by design. The `is_nil(parent)` clause keeps the LV
  responsive to broadcasts from older callers that haven't been
  updated to thread `parent_catalogue_uuid` yet. Re-verified at
  `web/catalogue_detail_live.ex:109`. No action.

- ~~**#4 (INFO)** `handle_info` clause restructuring~~ — positive
  cleanup; the rescue is now in a dedicated `handle_catalogue_data_changed/1`
  private function. Re-verified at `web/catalogue_detail_live.ex:115-127`.
  No action.

## Skipped (with rationale)

None — the PR ships clean.

## Files touched

None in this Phase 1 batch — all four findings are documented as
intentional in-code or acceptable trade-offs.

## Verification

- All four reviewer findings re-verified against current `main`
  (post-merge). The code matches what the PINCER review described.
- The Phase 2 quality sweep on this branch (commits `3c8e586`,
  `b73006a`, `17bedb9`) was rebased cleanly over PR #13 — no
  conflicts. Confirmed by `mix compile --warnings-as-errors` clean
  + `mix test` 651/651 passing on the rebased state.

## Open

None.
