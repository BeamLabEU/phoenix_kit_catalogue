# PR #156 — Activity source from API context

[PR #156](https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/156) takes the
catalogue API activity metadata's `via` from core's call context, falling back
to `api` for key/older contexts. This distinguishes confirmed assistant writes
and signed-in session writes. Changes: `API.Common.write_opts/3` and its tests.

See [Codex review](CODEX_REVIEW.md).
