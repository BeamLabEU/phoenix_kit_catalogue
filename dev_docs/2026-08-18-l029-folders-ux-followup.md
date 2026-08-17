# L029 — folders UX follow-up (working log)

**Branch:** `L029/folders-ux` (worktree `/www/.worktrees/l029`, base `upstream/main` @ `1855c28`,
includes merged #71/#72). Live stand checkout (`/www/phoenix_kit_catalogue`, branch
`L040/item-form-components` @ `ffa18b8`) is left untouched — verified content-identical to
`upstream/main` for `catalogues_live.ex` (`git diff HEAD upstream/main -- .../catalogues_live.ex`
empty), so the running app is valid evidence for upstream behavior where cited below.

## Test-infra note (not part of the feature diff)

Fresh `pk-test` run in the new worktree failed to compile `mdex_native` (transitive dep, unrelated
to folders): `RUSTLER_PRECOMPILED` wants a `--legacy_cpu` NIF variant on this CPU (no AVX/FMA) that
isn't in the local cache, and can't force-build because `rustler` isn't a real dep here. Added
`{:rustler, ">= 0.0.0", optional: true}` to `mix.exs` locally (core `phoenix_kit` already carries
this line for the same reason) and ran once with `MDEX_NATIVE_BUILD=1` to compile from source
(Rust toolchain is present). **This mix.exs line must NOT ship in the PR** — strip it before
sending; it's a local-only workaround so `pk-test` can run in an isolated worktree at all.

---

## Item 1 — "New Folder" toolbar button

**Owner's note (14.08):** click has no effect → remove, keep creation in the modal.
**Premise check result: does NOT hold today. Button works. Recommendation: do not remove.**

### Why the premise doesn't hold — timeline

- `2026-06-28` (5a01d13 / 2e6ece0, Timujeen): folder creation shipped as a **modal**
  ("Folders management modal"). This is almost certainly the state the owner saw on 14.08 — a
  toolbar button that either did nothing on its own or only opened something unrelated to what's
  there now.
- `2026-08-15` (a0d0051, Max Don): "Resume the inline folder tree on the catalogues index" —
  reintroduces `handle_event("new_folder", ...)` in its current form, wired directly to
  `Catalogue.create_folder/2`.
- `2026-08-16` (4210244, Max Don): **"Remove the Folders modal and its toolbar button"** — the old
  modal-era button is explicitly deleted here, more than a day *after* the owner's 14.08 comment.

So the button on screen today is not the button the owner flagged — that one is gone. It's a new,
separately-implemented control built as part of the inline-folder-tree rework.

### Code reading (`lib/phoenix_kit_catalogue/web/catalogues_live.ex`)

- Button: lines 2268–2281, `phx-click="new_folder"`, `phx-value-parent` = current drill-down
  folder's uuid (if any). Handler: lines 1340–1364, calls `Catalogue.create_folder/2`; on success
  assigns `renaming_folder` (opens inline rename) and reloads; on error flashes
  "Failed to create folder."
- The `.table_toolbar` block (containing this button) renders **once, unconditionally**, above the
  `tree?`/`card_level?` branch (line 2287+) that decides table vs. card layout — so the button is
  identical in both view layouts. Not layout-dependent.
- The only gate is `@catalogue_view_mode == "active"` (line 2269) — the exact same condition as the
  sibling "New Catalogue" link right next to it (line 2282). `load_data/2` (~line 288–324) confirms
  there are only two view modes, `"active"` and `"deleted"`; hiding the button in `"deleted"`
  (trash view) is correct behavior, not a defect — you can't create folders while browsing trash.

Conclusion: no mode/layout combination where the button is visible but inert.

### Empirical check

`test/web/catalogues_live_test.exs:379`, `"new_folder honors a validated parent from the drill
level"`, already `render_click`s the event and asserts real side effects (new folder parented
under the drilled-in folder; a forged/unknown parent falls back to root instead of erroring). No
`@tag` excludes it. Ran the whole file through `pk-test` (real `migration_test_db`, integration
half included):

```
41 tests, 0 failures
```

### Verdict

Button works, in the only mode it's shown, in both view layouts. It is not the dead button from
14.08 — that one was already removed in 4210244. **No code change for item 1.**

---

*Items 2 and 3 not started — reporting item 1 separately per instructions before proceeding.*
