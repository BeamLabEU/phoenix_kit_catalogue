# Claude Review — PR #57 (Export tab gettext) and PR #58 (test DB from env)

Reviewed 2026-08-12 as part of the ecosystem PR sweep. Both merged into `main`.

**Verdict: both APPROVED.** Two defects found on `main` that neither PR caused;
one fixed here, one documented because fixing it properly is a refactor rather
than a sweep change.

## PR #58 — Read test DB name and pool size from the environment

`config/test.exs` plus an `AGENTS.md` note. Byte-for-byte the same mechanism as
core `phoenix_kit`'s `config/test.exs` and the sibling change in
`phoenix_kit_ai` #18, including the detail that carries the value: both helpers
`case` on `System.get_env/1` rather than using `System.get_env/2`, because the
two-arity form falls back only when a variable is *unset*. A set-but-empty
`PGPOOL=` yields `""`, which `System.get_env/2` returns happily and
`Integer.parse/1` then fails on, aborting config loading with an
`ArgumentError` that never names the variable.

Defaults are preserved when both are unset, so CI and local runs are
unaffected. Nothing to fix.

## PR #57 — Missing gettext entries for the Export tab and its neighbors

Adds 6 msgids across `default.pot` and all three locales, plus 123 lines of
tests. Verified every msgid resolves to a real call site — all use this
module's fully-qualified runtime form:

| msgid | call site |
|---|---|
| `Export Items` | `web/export_live.ex:54` |
| `Destination` | `web/export_live.ex:87` |
| `Format` | `web/export_live.ex:100` |
| `Select a format...` | `web/export_live.ex:106`, `web/import_live.ex:1684` |
| `Add the catalogue name to the item name` | `web/export_live.ex:131` |
| `Manual order` | (pre-existing; en entry was missing) |

Machine-checked all three catalogues after the change: 335 entries each, zero
`fuzzy` flags, zero empty `msgstr`, and zero `%{...}` placeholder mismatches
between msgid and translation. Placeholder mismatch is the one that degrades at
runtime — a `msgstr` referencing a binding the call site never passes falls
back to the raw msgid — and there are none.

**The test approach is right, and worth copying.** `po_msgstr/2` parses the
`.po` file with `Expo.PO.parse_file` instead of calling `Gettext.gettext/2`
for the `en` assertions. That matters: English translations here are identical
to their msgids, and Gettext's documented behavior on a missing translation is
to return the msgid — so a runtime lookup passes whether or not the entry
exists, and would keep passing with the `en.po` entry deleted outright. The
`et`/`ru` assertions can safely use the runtime path because their translations
differ from the msgid. This is the same trap `phoenix_kit_ai` #17 hit and fixed
the same way.

The two regressions the PR documents are both real: `Export Items` had en/ru
but no et entry with nothing exercising it, and four Export-page strings were
in no locale at all, leaving a Russian or Estonian admin four raw English
strings on that page.

## Finding — `version/0` reported the wrong version (fixed on `main`)

`PhoenixKitCatalogue.version/0` returned `"0.13.0"` while `mix.exs` declared
`@version "0.14.0"`. Predates both PRs — checking out the `v0.14.0` tag shows
the same mismatch, so **the published 0.14.0 package reports itself as
0.13.0**.

This repo already carries the right test for it, and it is not
database-gated:

```elixir
assert PhoenixKitCatalogue.version() == Mix.Project.config()[:version]
```

So `main` was red on `mix test` before this sweep touched it, and the 0.14.0
release was cut anyway. That is the more useful signal than the drift itself —
the guard existed and worked; it just wasn't run before publishing. Worth
keeping `mix test` (not only `mix precommit`, which does not run tests) in this
repo's release path.

Fixed by moving both locations to `0.14.1` together. The test derives its
expectation from `Mix.Project.config()`, so it self-corrects and needs no edit.
This is the same defect `phoenix_kit_ai` shipped in 0.18.1 and fixed in 0.18.2.

## Finding — `gettext.extract`/`merge` would delete ~329 translations (documented, not fixed)

Not caused by either PR, but it is what makes PR #57's hand-editing of `.pot`
and `.po` files necessary, so it belongs on the record.

Almost every string in this module is written as the **runtime function** call:

```elixir
Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export Items")
```

rather than the `gettext("…")` macro. Counted across `lib/`: **891 runtime-form
call sites vs. 7 macro-form**. Only two files (`web/table_config.ex`,
`web/catalogues_live.ex`) carry `use Gettext, backend:
PhoenixKitCatalogue.Gettext`.

`mix gettext.extract` only sees macro calls. A regenerated `default.pot` would
therefore contain roughly those 7 strings instead of the 336 currently
committed, and `mix gettext.merge priv/gettext` — which defaults to
`on_obsolete: :delete` — would then strip the remaining ~329 entries from
`en`, `et` and `ru` in one command. The gate cannot catch this: `precommit`
here is `compile --warnings-as-errors` + `deps.unlock --check-unused` +
`hex.audit` + `quality.ci`, with no gettext step.

The proper fix is to add `use Gettext, backend: PhoenixKitCatalogue.Gettext` to
each LiveView and convert the call sites to the macro form, at which point
extraction works normally and the catalogues stop being hand-maintained.

**Not done here.** It is an 891-call-site mechanical conversion whose failure
mode is a silently mis-bound backend (a `gettext` call written above the `use`
line resolves against core's catalogue instead), and the tests that would catch
it are the LiveView integration tests — all 804 of which are excluded in this
environment for lack of a database. Converting blind during a release sweep
trades a documented hazard for an undetectable one.

Instead, `AGENTS.md` now carries an explicit warning under **Gettext**: do not
run `gettext.extract`/`merge` here, add msgids by hand to all four files, pin
them with a test, and treat the conversion as the real fix when someone can run
the integration suite.
