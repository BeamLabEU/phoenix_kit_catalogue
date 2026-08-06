# PR #51 — Raise the core floor to 1.7.231, the release that ships UrlState

Merged as `9302904` (branch `fix/core-version-floor`, commit `34af78b`,
author @timujinne).

## Goal

Correct the declared `phoenix_kit` requirement so it matches what the code
actually needs. PR #49 adopted `PhoenixKitWeb.Live.UrlState` in three
LiveViews; `mix.exs` still declared `~> 1.7.189`, a range that includes releases
with no such module.

## What changed

One line in `mix.exs`, plus a comment recording why the floor is where it is:

```diff
-      pk_dep(:phoenix_kit, "~> 1.7.189"),
+      pk_dep(:phoenix_kit, "~> 1.7.231"),
```

`mix.lock` already carried 1.7.231, so no build in this repo changes. What
changes is the contract a consumer resolves against.

## Related PRs

- The PR that created the requirement: [#49](/dev_docs/pull_requests/2026/49-url-state-search)
- Companion: [#50](/dev_docs/pull_requests/2026/50-pro100-sync-key)
