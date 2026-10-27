# PR #150 — Attachment thumbnail refresh

Reviewer: Codex · Author: @timujinne · Reviewed: 2026-10-27
Local merge: `d077784` · Status: reviewed, no additional defect found.

Checked the attachment lifecycle hook, subscription before thumbnail reads,
featured-image selection/clearing, checksum-based version URLs, and all three
form/component call sites. Processed-file events update only a displayed file;
the hook continues dispatch so another storage consumer can receive the same
event. Batch instance reads retain schema-prefix handling through the schema,
and read failures degrade to unversioned URLs.

The existing thumbnail-refresh integration tests passed in the 385-test focused
run. No implementation change was warranted by this review. The final full
suite and precommit gate also cover this PR.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
