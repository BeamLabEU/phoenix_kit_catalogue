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

---

## Item 2 — filters/menu panel onto the same row as the view-mode toggle

**Owner's note:** the filter/menu panel should be on the same row as the table-view-mode toggle
(card/comfy/table icons); today they hang on separate rows.

**Premise check result: still holds. The maintainer's recent index rework (a0d0051, 4210244,
`d827a10` "Merge the Active/Deleted tabs into the view-toggle row", 2026-08-16) merged the view
toggle with the Active/Deleted trash tabs — not with the filters/toolbar row. So the specific gap
the owner flagged is still there today. Fixed.**

### Before

Two structurally separate rows in the `:index` tab:

1. `table_toolbar` private component (search, folder/status filters, sort, "Reorder all",
   "Columns", New Folder/New Catalogue actions) — lines 2246–2286.
2. A row lower down pairing the Active/Deleted trash tabs with `catalogues_view_toggle`
   (card/comfy/table icons), added by `d827a10` under the rationale "both are 'how am I looking at
   this list' controls" — but that pairing is not what the owner asked to consolidate.

### Change

`table_toolbar` (lines ~2845–2917) already groups its right side into a "view tools" cluster
(sort + "Reorder all" + "Columns") next to a separate "create actions" cluster (the existing
`:actions` slot), per its own comment about wrap-as-a-unit clusters. Added a third, optional
`slot(:view_toggle)`, rendered right after the "Columns" button inside that same view-tools
cluster. The `:catalogues` scope's call site now fills it with
`<.catalogues_view_toggle view={cfg.view} />` (dropped the `class="ml-auto"` — it doesn't need
right-push in its new spot). The other three `table_toolbar` call sites (manufacturers, suppliers,
attribute_groups) don't pass this slot, so they're unaffected — `render_slot` on an empty slot is
a no-op.

The Active/Deleted trash-tabs block keeps its own conditional row (unchanged content, just no
longer paired with the view toggle) — the owner's ask was about the filters panel specifically,
not the trash tabs, and that block only renders at all when there's something in the trash.

### Verification

`mix format` (clean diff, no unrelated churn) + `pk-test test/web/catalogues_live_test.exs`:
**41 tests, 0 failures**, same pre-existing warnings as before the change (missing form ids —
unrelated, present on `main` already).

---

## Item 3 — UX breakdown of folders (analysis only, no code — owner decides)

### What a folder is, and why

Per `AGENTS.md` and the agreed design record (`dev_docs/2026-08-15-folders-categories-document-model.md`,
2026-08-15, product owner via Max): a **catalogue is a document** (the long-term goal is
catalogue → PDF). Folders are the **file explorer around those documents** — a module-global,
self-nesting, **admin-only, untranslated, unexported** organizing shelf, deliberately the
*opposite* of Categories (which are the document's own chapters: scoped to one catalogue,
translated, and they drive export/page order). A folder is closer to a filesystem directory than
to anything product-facing: it never appears in a PDF, never affects pricing or rules, and moving
a catalogue between folders has zero consequence outside the admin's own organization of the list.
That boundary is real and intentional, but it lives only in `dev_docs` — nothing in the UI itself
tells an admin "this is just your shelf, it changes nothing downstream."

### Where folders are actually managed today (full inventory, not just what's visible at a glance)

The functional surface is considerably richer than "filtering, display, move to folder" — it's
just not signaled well:

- **Create**: toolbar "New Folder" (root or current drill level) + a per-folder "New subfolder"
  in its row menu.
- **Rename**: inline, opened from the row menu.
- **Reparent/move** — three separate mechanisms: (a) native drag-and-drop onto a folder or the
  root zone (`move_to_folder`), (b) an edge-drop that reparents *and* reorders siblings in one
  gesture (`drop_row`), (c) an explicit "Move to folder" modal (plain `<select>`) reachable from
  every row's menu — this last one is what the owner referred to.
- **Delete**: row menu → confirm modal; new deletes are empty-only and permanent
  (legacy trashed folders get a separate promote-contents escape hatch).
- **Navigate**: clicking a folder's name (or "Open" in its row menu) drills the tree down into it
  by driving the existing folder filter; the same toolbar filter dropdown can jump anywhere
  directly.
- **Organize**: expand/collapse tree nodes, drag-reorder siblings within a level.
- **Two renderers**: an indented tree-table and a card-level grid (folders as visible boxes around
  their catalogues) — both carry an *identical* row menu (Open / Rename / New subfolder / Move to
  folder / Delete).

So the owner's read ("weakly obvious... no other interaction visible") is accurate as a
**discoverability** complaint, not a completeness one — almost everything above is real and
tested, but hidden behind a row kebab-menu or a drag gesture with no persistent visual cue.

### Concrete weak points found while reading the code

1. **No breadcrumb when drilled in.** `navigate_folder` re-roots the tree by uuid with no path
   trail rendered anywhere — the only sense of "where am I" is the folder name currently selected
   in the filter dropdown. The file-explorer metaphor the design doc invokes usually implies a
   "Root / Estonian stuff / Tables" trail; that piece was never built (the codebase already has a
   *different* breadcrumb helper for category paths — `Catalogue.breadcrumb_categories_for_catalogue/2`
   — that's prior art for the pattern, not directly reusable code).
2. **The tree collapses under search/sort**, and a small caption explains it ("Clear search and
   filters to see the folder tree.") — correct behavior, but it means the "spatial" file-manager
   feel is fragile and disappears exactly when an admin is hunting for something, which is a
   likely first-contact scenario.
3. **CONFIRMED visually (2026-08-18): the "Move to folder" dropdown shows no nesting at all.**
   `folder_options/1` indents child names with `"  "` (plain spaces) per depth. Reproduced the
   exact option markup (`String.duplicate("  ", depth) <> name`, same values as a real 2-level
   tree) in a standalone HTML file and rendered it in headless Chromium
   (`ms-playwright/chromium-1228`, `--headless=new`, `<select size="8">` so every option paints
   inline instead of inside a native closed-dropdown popup that headless Chrome can't screenshot —
   same option text, same default whitespace rules). Screenshot: "Tables", "Round tables", and
   "Chairs" render **flush-left, at the same indent as root-level "Estonian stuff" and
   "Domestic"** — the leading spaces are fully collapsed, exactly as HTML's default whitespace
   handling predicts. So today, the one non-drag move path presents every folder in the module as
   a single flat, unordered-looking list — a real, user-visible defect, not a hypothetical one.
4. **All of the folder-specific verbs live behind a menu**, while catalogues get one visible,
   labeled primary action next to them (folders don't have an equivalent one-click affordance
   beyond drag). A first-time admin has no reason to open a folder row's "..." to discover
   "New subfolder" exists at all.
5. **Nothing in the UI states the folder/category boundary.** An admin moving a catalogue between
   folders has no on-screen cue that this is purely organizational and touches nothing a customer
   or export will ever see — that mental model currently only exists in `dev_docs`.

### Suggestions (owner decides; not implemented)

- Add a breadcrumb strip above the tree/card grid when drilled below root — cheapest single fix
  for the "where am I" gap, and it directly extends the file-explorer metaphor already agreed on.
- Fix the confirmed whitespace-collapse in the "Move to folder" `<select>` — either `&nbsp;`-pad
  or switch to a proper indentation marker (e.g. a `└─`/`—` prefix), so the one non-drag move path
  actually shows structure instead of a flat list.
- Promote "New subfolder" to a small inline icon-button on hover/focus of a folder row (mirroring
  how root-level "New Folder" is already a first-class toolbar button), rather than only living in
  the row menu.
- A short static caption near the folder filter/toolbar (or a tooltip on "New Folder") clarifying
  "folders organize this list only — they don't affect what's exported" would close the "why does
  this exist" gap cheaply, without new interaction surface.

---

*Items 1 and 2 are code-complete in this worktree (commits `f3050f9`, `57690ab`), not sent as a PR
— that's the head-of-cycle's call. Item 3 is analysis only, no code, per instructions.*
