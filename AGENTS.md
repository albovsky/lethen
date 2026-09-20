# Lethen project rules

`CONTRIBUTING.md` is authoritative. Keep patches small and reviewable; discuss
major features, dependencies, CI, release, and distribution changes first.

- Analysis changes need focused regression tests for declarations that must be
  reported and declarations that must be retained. Retention heuristics also
  need a used-but-not-compared control.
- Preserve existing configuration and comment syntax, library names,
  attribution, and supported paths unless a change is explicitly justified.
- Preserve incremental SwiftPM behavior: clean only for `--clean-build`; use
  `swift build --show-bin-path` with matching build arguments; keep explicit
  index-store paths authoritative; never use stale or alternate stores silently.
- Never weaken assertions, add broad exclusions, regenerate baselines, or treat
  compilation alone as correctness evidence.
- Validate affected tests and the full suite; record the exact toolchain, commit,
  and build configuration behind compatibility claims.
- Keep inherited release automation disabled. Do not use upstream credentials or
  publish to upstream registries. Tags through 3.8.0 are upstream history, not
  lethen releases.

For reviews, report `Standards` and `Spec` separately. Cite documented
standards, distinguish hard violations from judgment-call smells, and flag
missing requirements, scope creep, and implementations that look wrong.
