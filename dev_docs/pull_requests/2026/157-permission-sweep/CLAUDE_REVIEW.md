# PR #157 — permission sweep: review record

**Author:** Max Don (with Claude)
**Reviewer:** codex; findings checked against the code by Claude before fixing
**Verdict:** every confirmed finding fixed in this PR, each with a test that fails when the fix is reverted.

## Findings

- LOW — the `save_sweep_langs` refusal test cleared an already-empty selection, so it couldn't fail → it now stores `["et"]` first and reads the raw value back.
- HIGH (shared with ecommerce) — `AITranslate.Embed` halts the modal events and dispatches with no permission check → `Web.AITranslateGate` attached before the embed on all four forms (here it guards the base key, which core also re-checks: defence in depth).
- Checked, sound: settings mount/event checks, the backfill (raising lookup, retryable, idempotent, flag after success).
