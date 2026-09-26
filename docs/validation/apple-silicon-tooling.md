# Apple silicon tooling validation

Validated on 2026-09-25 (America/Vancouver) against commit
`7ec0e71491cd3ca49769f3a2e26c133868459a1e`, with the working-tree change removing
explicit cross-module optimization from the mise build task. The earlier edits
were committed by another process during validation; no Swift sources or package
resolution changed between the initial `96be1ef8dd997f609771c68a02627d778aef8c69`
checkout and this commit.

## Environment

- arm64 macOS 27.0, build 26A428.
- Xcode 27.0, build 27A266a.
- Apple Swift 6.4, swiftlang-6.4.0.34.1, clang-2100.3.34.1.
- mise 2026.9.14 and hyperfine 1.20.0.
- Build configuration: `swift build --product lethen --configuration release
  --disable-sandbox --scratch-path .build --arch arm64`; the executable directory
  is queried with the same arguments plus `--show-bin-path`.

## Results

- `bash .github/scripts/verify-swift-6.4.sh` passed: all 353 tests passed,
  clean/warm/native fixture findings matched, and the strict self-scan reported
  no unused code. The suite and scans used the script's debug configuration;
  fixture comparisons covered the default and native build engines. Raw logs are
  in the local, ignored `.validation/` directory.

- `mise r build --arch arm64` passed. Stdout contained only the resolved executable
  path; the executable reported `3.8.1` and `lipo -archs` reported only `arm64`.
- `mise r build --arch release` passed. The stripped `.release/lethen` copy reported
  `3.8.1` and contained only `arm64`.
- `mise r benchmark` passed using the build task's returned executable path. Ten
  runs, following three warmups, averaged 1.984 seconds (standard deviation 0.053
  seconds). This used the existing local index with `--skip-build`; it is a task
  execution check, not evidence of index freshness or a performance comparison.
- A temporary command-stub harness checked that invalid and Intel architecture
  requests fail before invoking Swift, both build modes emit a single path, build
  and path-query arguments match, and the benchmark preserves paths with spaces.
- Shell syntax, whitespace, and local documentation-link checks passed.
- The published 3.8.1 zip matched `SHA256SUMS`, extracted using the documented
  `ditto` command, reported `3.8.1`, and contained only `arm64`. Its signature passed
  `codesign --verify --strict` outside the sandbox. The live Homebrew formula
  referenced that same zip and checksum and required arm64 and macOS 15 or later.

The original `-Xswiftc -cross-module-optimization` option failed to link
ArgumentParser symbols on this Xcode toolchain. Removing the explicit option,
matching the release workflow's normal release optimization, made the build pass.
The Xcode 27.0 libIndexStore itself was inspected with `lipo -archs` and contains
only `arm64`. Intel source builds were not tested.

## PR isolation

The patch was subsequently applied to `3dcb673` (current `master`) for the focused
PR. Documentation conflicts were resolved to retain the newer Linux release
instructions and existing signing evidence. The mise scripts are identical to the
validated versions above; shell checks and the temporary command-stub harness
were rerun on the isolated branch. The full Swift baseline was not repeated for
this documentation-only integration; its exact tested commit is recorded above.

## Rebase onto the Swift 6.3 minimum

The branch was then rebased onto `f8afaff` (`master` after the Swift 6.3 minimum,
the Bazel image entrypoint, the formatter tests, and the Lethen identifier rename).
Only `CHANGELOG.md`, `CONTRIBUTING.md`, and `README.md` conflicted; the resolution
keeps both Breaking entries, the current CI profile text, one copy of the
toolchain-policy sentence, and states that Intel source builds need Xcode 26.4 or a
later Xcode 26 release. On the rebased commit, with the same host and toolchain as
above, `bash .github/scripts/verify-swift-6.4.sh` passed (379 tests, empty
clean/warm and default/native fixture diffs, no unused code in the strict
self-scan), `mise r build --arch release` produced an arm64-only binary reporting
`3.8.1`, and `mise r build --arch x86_64` exited 1 before building.
