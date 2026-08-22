# Review — PR #77: Declare rustler explicitly so mdex_native force-builds

**Author:** Tymofii Shapovalov (@timujinne)
**Reviewed:** 2026-08-22
**Status:** Merged as `0465569` (`0c964ad` on `upstream-fixes/rustler-declare`)
**Verdict:** SHIP. No post-merge fix.

Reviewed against elixir-thinking. Two files, one declaration, same shape
core `phoenix_kit` already ships.

---

## What landed

```elixir
{:rustler, ">= 0.0.0", optional: true}
```

`mdex_native` (via `phoenix_kit` → `mdex`) builds from source when
`MDEX_NATIVE_BUILD=1`. That path needs `rustler`, not just
`rustler_precompiled`. OTP 28 has no precompiled NIF, so a clean checkout
of this library failed to compile without the declaration. `mix.lock` pins
`rustler` 0.38.0 (the same version `ex_pdfium` already required optionally).

---

## Findings

None. The constraint is deliberately `>= 0.0.0` (identical to core) so Mix
resolves whatever `mdex_native` / `ex_pdfium` ask for. `optional: true`
keeps the Hex package free of a forced native toolchain for hosts that use
the precompiled artefact.

Not a process, not a GenServer, not a scope leak.

---

## Verified as correct

- Core `phoenix_kit` 2.13.x lock already lists
  `{:rustler, ">= 0.0.0", optional: true}` — this is a mirror, not a new
  policy.
- `ex_pdfium` and `mdex_native` both already depend on `rustler` optionally;
  the lock entry is not an unused dep.
- Follow-up `lib upgraded` commit (`87ca1dc`) only retouched `mix.lock` and
  does not revert this.
