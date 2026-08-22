# PR #77: Declare rustler explicitly so mdex_native force-builds

**Author**: @timujinne
**Reviewer**: Grok
**Status**: Merged
**Commit**: `0465569` (`0c964ad` on `timujinne/upstream-fixes/rustler-declare`)
**Date**: 2026-08-22

## Goal

A clean checkout on OTP 28 failed to compile: `MDEX_NATIVE_BUILD=1` forces
`mdex_native` (transitive through `phoenix_kit`'s `mdex`) to build its NIF
from source, which requires `rustler` itself, not just
`rustler_precompiled`. Declare the same optional dep `phoenix_kit`'s own
`mix.exs` already carries.

## What Was Changed

| File | Change |
|------|--------|
| `mix.exs` | `{:rustler, ">= 0.0.0", optional: true}` next to the `phoenix_kit` dep |
| `mix.lock` | Pins `rustler` 0.38.0 |

## Testing

- [x] Matches core `phoenix_kit`'s declaration
- [x] `optional: true` so Hex consumers without `MDEX_NATIVE_BUILD` do not
      pull a native toolchain
- [x] `mix deps.unlock --check-unused` still passes (the lock entry is
      reachable through the optional dep)

## Related

- Review: [GROK_REVIEW.md](GROK_REVIEW.md)
- Sibling: [#76](/dev_docs/pull_requests/2026/76-item-selector-and-browse-components)
