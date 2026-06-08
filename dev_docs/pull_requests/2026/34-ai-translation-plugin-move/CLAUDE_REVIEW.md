# Code Review: PR #34 — Move AI translation to the phoenix_kit_ai plugin

**Reviewed:** 2026-06-08
**Reviewer:** Claude (claude-opus-4-8)
**PR:** https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/34
**Author:** Max Don (mdon)
**Head SHA:** 13a6ea5b5b1fdad0674d5e9145dd5c0fa253e3a3
**Merge commit:** 8f5c0a7d9db63a055fa7afe58a776c1fb8a27cec
**Status:** Merged (post-merge review against `main`)

> **Update — 2026-06-08 (re-review after `phoenix_kit_ai` 0.4.0 upgrade):**
> Issues 1 and 2 below are **resolved**. `phoenix_kit_ai` **0.4.0** now ships
> the full translation surface (`PhoenixKitAI.{Translatable,Translations,
> Translatable​s,Translation,TranslateWorker}` and
> `PhoenixKitAI.Components.AITranslate.{Embed,FormBinding,FormGlue}`); the lock
> was bumped to 0.4.0 (commit `dee6333`). Verified with **no** local-path
> overrides: `mix deps.get` resolves against published pins and
> `mix compile --force --warnings-as-errors` is green for both
> `phoenix_kit_ai` and `phoenix_kit_catalogue` (the `@behaviour` callbacks line
> up — a signature mismatch would have tripped `--warnings-as-errors`). Two
> follow-up fixes applied: `mix.exs` constraint bumped `~> 0.3` → `~> 0.4` (so
> the constraint no longer admits the pipeline-less 0.3.x), and the CHANGELOG
> note corrected to `>= 0.4.0` with the module list. Issue 3 (`pk_dep/3` empty
> `<APP>_PATH`) is unchanged — still optional/low-severity.

## Summary

Rewires catalogue's AI-translation consumer from the now-removed core
namespaces to the `phoenix_kit_ai` plugin:

- `@behaviour PhoenixKit.Modules.AI.Translatable` → `PhoenixKitAI.Translatable`
- `PhoenixKitWeb.Components.AITranslate{,.Embed,.FormBinding,.FormGlue}` →
  `PhoenixKitAI.Components.AITranslate{…}`
- Drops `@impl PhoenixKit.Module` from `ai_translatables/0` (core dropped the
  callback; the plugin duck-types the function).
- Adds `{:phoenix_kit_ai, "~> 0.3"}` as a direct dependency.
- Adds an env-gated `pk_dep/3` helper in `mix.exs` for building/testing against
  a local `phoenix_kit*` checkout (`<APP>_PATH`), plus an AGENTS.md section.
- Docs-only: CHANGELOG rewording, PR #33 `FOLLOW_UP.md` stub.

The namespace rename itself is mechanical and **complete** — no stale
`PhoenixKit.Modules.AI` or `PhoenixKitWeb.Components.AITranslate` references
remain in `lib/` or `test/`. The `AITranslatable` adapter logic (field
mapping, FOR UPDATE merge, force-put) is untouched and correct.

## Issues Found

### 1. `main` does not compile against the published / locked dependency set — BLOCKING for release

The AI-translation modules this PR now `use`/`@behaviour` against **do not
exist** in any published `phoenix_kit_ai`. The latest Hex release is **0.3.0**
(`mix hex.info phoenix_kit_ai`), and it ships only the completion/prompt/
endpoint/playground modules:

```
PhoenixKitAI, .AIModel, .Completion, .Endpoint, .Errors, .OpenRouterClient,
.Prompt, .Request, .Routes, .Web.{AuthHelpers,EndpointForm,Endpoints,
Playground,PromptForm,Prompts,SortHelpers}
```

There is **no** `PhoenixKitAI.Translatable`, `PhoenixKitAI.Translations`, or
`PhoenixKitAI.Components.AITranslate.{Embed,FormBinding,FormGlue}` in 0.3.0.
`mix.lock` pins `phoenix_kit_ai` at exactly `0.3.0`, so a clean
`mix compile` against the committed lock fails:

```
error: module PhoenixKitAI.Components.AITranslate.Embed is not loaded and
could not be found
  lib/phoenix_kit_catalogue/web/catalogue_form_live.ex:5: use …AITranslate.Embed
(same for category_form_live.ex, item_form_live.ex)
== Compilation error in file lib/phoenix_kit_catalogue/web/catalogue_form_live.ex ==
```

The PR description frames this as an intentionally "gated" state ("CI is gated
until the plugin releases the pipeline, then greens on `mix deps.update`"), and
the local `mix precommit` the author ran was green only because it resolved
against a local `PHOENIX_KIT_AI_PATH=../phoenix_kit_ai` checkout containing the
unreleased move. That's honest, but it has two real consequences worth
flagging:

- **`main` is red.** Anyone cloning catalogue and running `mix compile` (or CI)
  without the local-path override gets a non-compiling tree. The breakage is on
  `main`, not just CI.
- **The `~> 0.3` constraint cannot express the actual requirement.** Because
  0.3.0 is already published *without* the pipeline, `~> 0.3` is satisfied by a
  release that lacks the needed modules. A parent app adding the current
  catalogue resolves `phoenix_kit_ai` to 0.3.0 and gets a broken build — the
  constraint admits exactly the version that doesn't work. Catalogue itself is
  still at `@version 0.7.0` and HEAD is 6 commits past the `v0.7.0` tag, so the
  broken state is **not yet published** to Hex — good — but it must stay
  unpublished until the plugin ships the AI-move release.

**Recommended actions:**
- Do **not** publish catalogue (keep it at/under 0.7.0) until `phoenix_kit_ai`
  publishes the release that actually contains the translation pipeline.
- Once that version is known, fix the CHANGELOG note (see issue 2) and bump the
  constraint floor to it, mirroring the existing `phoenix_kit` style
  (`~> 0.3 and >= 0.3.x`). This keeps the constraint loose (per project
  preference) while excluding the 0.3.0 that lacks the modules.
- After bumping, run `mix deps.update phoenix_kit_ai` so `mix.lock` no longer
  pins the broken 0.3.0.

### 2. CHANGELOG note understates the real `phoenix_kit_ai` requirement

The new note reads:

> **Requires `phoenix_kit_ai ~> 0.3` for AI translation** — the shared embed
> macro and translation pipeline now live in the AI plugin.

This is inaccurate as written: `~> 0.3` is satisfied by 0.3.0, which does
**not** contain the embed macro or translation pipeline. Per the project's
"keep constraints loose, document the real minimum in the CHANGELOG" practice
(the same way `phoenix_kit >= 1.7.125` is noted), this note should name the
specific `phoenix_kit_ai` version that first ships the pipeline once it
releases — otherwise the CHANGELOG actively points consumers at a version that
won't compile.

### 3. Minor — `pk_dep/3` treats an empty `<APP>_PATH` as a path override

```elixir
case System.get_env(env_var) do
  nil when opts == [] -> {app, requirement}
  nil -> {app, requirement, opts}
  path -> {app, [path: path, override: true] ++ opts}
end
```

`System.get_env/1` returns `""` (not `nil`) when the variable is exported but
empty, which falls through to the `path` clause and yields
`{:phoenix_kit, [path: "", override: true]}` — a silently broken path dep.
A common shell mistake (`export PHOENIX_KIT_AI_PATH=` / an unset-but-exported
var in CI) would produce a confusing resolve failure rather than the intended
"unset ⇒ published pin" behaviour. Consider matching empty alongside nil:

```elixir
case System.get_env(env_var) do
  blank when blank in [nil, ""] and opts == [] -> {app, requirement}
  blank when blank in [nil, ""] -> {app, requirement, opts}
  path -> {app, [path: path, override: true] ++ opts}
end
```

Low severity — the helper is dev-only and the happy path is correct.

## What Was Done Well

- The rename is exhaustive: zero stale old-namespace references remain in
  `lib/`/`test/`, and the `AITranslatable` adapter's non-trivial logic
  (multilang `_`-prefix mapping, FOR UPDATE re-read + merge, `force_put`) was
  left untouched rather than disturbed by the move.
- Dropping `@impl PhoenixKit.Module` from `ai_translatables/0` is correct — the
  callback was removed from core; keeping `@impl` would warn. The function
  stays public so the plugin's duck-typed discovery still finds it.
- The `pk_dep/3` env-gated override is a clean solution to the cross-repo
  bootstrap problem: `override: true` handles diamond conflicts, and "unset ⇒
  exact published pin" keeps `mix hex.publish` / CI deterministic. The AGENTS.md
  section (including the "never hand-edit a `path:` tuple into a committed
  package" warning) is a good guardrail.
- The PR is transparent about the gated/local-only verification status.

## Verdict

The code change is a correct, complete, mechanical namespace migration — no
defects in the moved code. The concern is entirely **release coordination**:
`main` currently does not compile against published/locked deps because the
`phoenix_kit_ai` AI-move release the PR depends on has not shipped (latest Hex
0.3.0 lacks the translation modules, and `mix.lock` pins 0.3.0). This is a
known gated state, but the `~> 0.3` constraint + CHANGELOG note understate the
real requirement and would hand a consumer the broken 0.3.0 today. Hold
publishing, and tighten the floor + CHANGELOG once the plugin releases.

## Open

- ~~Confirm/track the `phoenix_kit_ai` release that ships the translation
  modules, then bump the constraint floor, update the lock, and correct the
  CHANGELOG note.~~ **Done** — 0.4.0 shipped them; lock at 0.4.0, `mix.exs` now
  `~> 0.4`, CHANGELOG note corrected to `>= 0.4.0`. Compiles clean against
  published deps. (Issue 3, `pk_dep/3` empty-`<APP>_PATH` hardening, remains
  optional/low-severity.)
