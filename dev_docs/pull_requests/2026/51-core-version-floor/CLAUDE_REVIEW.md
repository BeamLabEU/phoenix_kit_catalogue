# Review — PR #51: Raise the core floor to 1.7.231

Merged as `9302904` (`34af78b`, author @timujinne).

**Correct as merged. No findings, nothing changed.**

The claim was verified rather than taken from the commit message:

- Three LiveViews `use PhoenixKitWeb.Live.UrlState` —
  `catalogues_live.ex`, `catalogue_detail_live.ex`, `pdf_library_live.ex`. That
  is a compile-time `use`, so a consumer resolving a core below the release that
  introduced the module fails to compile this package; it is not a
  first-mount-only risk.
- `mix.lock` pins `phoenix_kit 1.7.232`, above the new floor, so no build in
  this repo moves. The PR corrects the declared contract, exactly as its message
  says.

This is worth distinguishing from the house rule against proactively tightening
dependency constraints. That rule is about *speculative* narrowing — pinning to
whatever happens to be locked, and forcing consumers into upgrades the code does
not require. This is the opposite: a floor that was factually below the code's
own requirement, raised to the release that satisfies it. The `~>` operator
still leaves the whole 1.7.x line open above it.

The inline comment naming the module and the reason is the part that keeps this
from regressing — the next person to bump the floor can see what it is anchored
to.

## Related

- The PR that created the requirement: [#49](/dev_docs/pull_requests/2026/49-url-state-search)
- Companion: [#50](/dev_docs/pull_requests/2026/50-pro100-sync-key)
