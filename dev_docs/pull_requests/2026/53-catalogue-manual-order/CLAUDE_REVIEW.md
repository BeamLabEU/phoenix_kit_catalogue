# PR #53 — Restore manual ordering for the catalogues index

**Reviewer:** Claude (post-merge sweep, 2026-08-11)
**Verdict:** Merged. One HIGH bug fixed on main. A second, unrelated packaging
bug found in the same file and fixed.

## Summary

Good PR. The diagnosis is precise (`5a01d13` replaced the folder tree with a
flat sortable table, `reorder_catalogues/2` survived but lost its only caller,
so `position` kept existing with nothing able to write it), and modelling manual
order as a **sort-only pseudo column** (`managed?: false`) rather than a
separate mode is the right shape — it reuses the sort dropdown instead of adding
a mode toggle.

The PR is also unusually honest about its own limits: it says plainly which
tests could not run and why (`test/test_helper.exs:47` calls a `mix test.setup`
alias `mix.exs` never defines; `ViewConfig.save/3` reaches
`Auth.update_user_custom_fields/3`, which wants a `%User{}` while the test
`on_mount` supplies a bare map). Both check out. That is worth fixing, and is
out of scope here — but it is the direct cause of the bug below going unnoticed.

## BUG - HIGH: the reorder guard was render-side only

`lib/phoenix_kit_catalogue/web/catalogues_live.ex` —
`handle_event("reorder_catalogues", …)`.

The PR correctly identifies the hazard and states it in its own comment:

> `Catalogue.reorder_catalogues/2` re-indexes exactly the uuids it's given into
> 1..N with no sibling/scope check […] dragging a filtered subset would renumber
> just those rows and silently clash with untouched rows outside the filter.
> That is exactly how `position` ended up with duplicate values in the first
> place.

It then gates only the **rendering** of the drag handles, via
`manual_order_draggable?/2`, and the event handler acts on `ordered_ids` with no
check at all. The handler's comment asserts the guarantee —
"`manual_order_draggable?/2` guarantees is the full unfiltered set whenever
handles are shown" — but "whenever handles are shown" is a statement about the
last render, not about the message that just arrived.

A `phx-hook` event is a client message. Two ways to reach the unguarded path
without doing anything unusual:

1. **Deliberately** — `pushEvent("reorder_catalogues", {ordered_ids: [...]})`
   from the console, at any time, in any view mode.
2. **By accident, and far more likely** — a drag begins in manual order and the
   event lands after the user has typed in the search box, applied a filter, or
   switched to the deleted view. Nothing serialises those.

Either way `reorder_catalogues/2` renumbers the submitted subset into 1..N and
collides with every row outside it: the exact duplicate-`position` corruption
the PR set out to stop recurring, reachable through the door it left open.

**Fixed on main:** the handler now re-checks
`manual_order_draggable?(catalogue_view_mode, current_cfg(assigns))` before
touching the data, and otherwise logs `:not_in_manual_order`, flashes the same
"Clear search and filters to drag-and-drop reorder." string the toolbar already
shows, and reloads. Reuses the function the PR extracted, so the render-side and
server-side rules cannot drift apart.

Not covered by a test, for the reason the PR documents: no LiveView test in this
module can currently round-trip an event. `manual_order_draggable?/2` itself has
direct unit coverage.

## BUG - MEDIUM (not from this PR): `priv/` was never shipped to Hex

Found while checking the `files:` list, and fixed in the same commit because it
is the same bug two sibling PRs in this sweep were opened for
(`phoenix_kit_manufacturing` #9, `phoenix_kit_warehouse` #17).

`mix.exs` had `files: ~w(lib guides .formatter.exs mix.exs README.md
CHANGELOG.md LICENSE)` — no `priv`. Two consequences for anyone installing from
Hex rather than from this checkout:

- **Every string renders in English.** `priv/gettext/{en,et,ru}` never arrives,
  so Gettext falls back to the msgid.
- **The PDF viewer is broken.** `Paths.pdf_viewer/1` points an iframe at
  `/_pdfjs/web/viewer.html`, and both documented delivery routes for those
  assets — the host endpoint's `Plug.Static` mount and core's
  `PdfViewerController` fallback — read them out of `priv/static/pdfjs/` in the
  installed package. With `priv` unshipped there is nothing to serve, and the
  symptom is an iframe that fails to load rather than any error naming the
  cause.

**Fixed on main:** `priv` added to `files:`. Adds ~11 MB uncompressed
(`priv/static/pdfjs` is the bulk of it); that is the cost of the feature
working at all.

## Notes, not defects

- `sort_dir_for("position", _)` pinning `:asc` is right — direction is
  meaningless for a drag order, and hiding the flip control alongside it is
  consistent.
- The `apply_columns` change (keep `sort_by` when it is still sortable, rather
  than when it is still *displayed*) is a genuine fix in its own right:
  "position" is never in `ids`, so without it Apply silently knocked manual
  order off.
