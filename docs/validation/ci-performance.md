# CI performance report

This report records why the `Test` workflow was slow, what changed in three phases,
and what the runs measured before and after. Numbers come from the GitHub Actions API
(`created_at`, `started_at`, `completed_at` of every job); queue time is the gap between a
job being created and starting, run time the gap between starting and completing.

## Summary

| | Before | After Phase 1 and 2 |
|---|---|---|
| Pull request run, wall clock | 41 to 85 min (five runs) | 10 min with a quiet queue (run 36103730405), 24 min while three other runs were live (run 36101658621) |
| macOS jobs scheduled per pull request | 8 | 3 |
| macOS queue wait, average | 34 min | 0 min quiet, 13 min while three other runs were live |
| Linux queue wait, average | 0.5 min | 0 min |
| Longest job on a pull request | macOS main-snapshot, 15 to 20 min, failing | macOS 6.3, 7 to 10 min (Swift 6.4 / Xcode 27 is 6.6 min with warm caches) |
| macOS 6.3 job | 13.7 min | 7.3 to 9.8 min |
| macOS 6.3 test step, wall | 494 s for 71 s of test code | 265 to 315 s for 52 to 65 s of test code |
| Push to master, wall clock | 41 to 43 min (two runs) | 16 min (run 36152028610, `master` profile, 14 jobs) |

The jobs were never the main problem. Hosted macOS runs at most five jobs at once for the
whole account, every run scheduled eight of them, and pushes to several branches within a
few minutes queued 30 to 40 macOS jobs against those five slots. Linux never waited.

## Baseline

Five consecutive runs on 2026-09-25 before any change (run ids 36086015670, 36086112386,
36087362785, 36089424750, 36091260073):

| Runner label | Jobs | Avg queue | Max queue | Avg run |
|---|---|---|---|---|
| ubuntu-latest | 31 | 0.5 min | 5 min | 6.6 min |
| macos-26 | 30 | 34.0 min | 83 min | 8.3 min |
| macos-15 | 5 | 19.6 min | 30 min | 11.3 min |
| xcode-27 | 5 | 13.2 min | 19 min | 10.2 min |

Wall clock per run: 43, 70, 85, 55 and 41 minutes. No job took longer than 20 minutes.

Inside the jobs, three things dominated:

- Every SwiftPM job compiled the tree three times: `swift build`, then the scan's
  `--clean-build` wiped `.build` and rebuilt with the index store, then `swift test`
  rebuilt again because its flags differ. The restored `.build` cache was discarded by
  the clean on every run.
- Test wall time was fixture rebuilds, not tests. On macOS 6.3, 324 tests ran in 71 s of
  test code but 494 s of wall time. Six test classes share `Tests/Fixtures`, and a managed
  build cleans and rebuilds a package whenever its products exist, so each class rebuilt
  the whole package in its class setup: 22 to 43 s per class on a three-core runner.
- The macOS main-snapshot job failed in four of the last five runs after 15 to 20 minutes
  of macOS time and gave no signal, since it is `continue-on-error`. The Bazel 8.x jobs
  intermittently ran with zero disk-cache hits (6 to 9.5 min instead of 1 to 3).

## Phase 1: fewer macOS jobs per run (#9)

- A `Plan` job runs `.github/scripts/plan-ci.sh` and picks a profile. Pull requests run
  `pr`: Swift 6.4 / Xcode 27, macOS 6.3, Linux 6.1 to 6.3, Bazel 9.x on both platforms.
  Pushes to `master` run `master`, which adds macOS 6.2, 6.1 and Bazel 8.x. The nightly
  schedule (03:00 UTC) and manual dispatch run `nightly`, which adds both main-snapshot
  toolchains. Snapshot toolchains are informational and never run on pushes or pull
  requests.
- Documentation-only changes (`*.md`, `docs/`) skip the build jobs. The diff runs from the
  previous push tip or the pull request base to HEAD without rename detection, so a
  rewritten push or a source file renamed into `docs/` still builds.
- Lint runs on Ubuntu. The generated Bazel rules check moved into the macOS 6.3 job
  because the generator reads the macOS package manifest.
- `Required checks` is the single required status check. It verifies that every job has
  exactly the result its profile expects: success when it was meant to run, skipped when
  it was not. The swiftly `TOOLCHAINS` fix from #8 is included.

Results:

- Pull request run 36097898611 (`pr` profile): 52 min wall clock, because it shared the
  queue with the `master` push from the #6 merge (14 jobs), a nightly dispatch (16 jobs)
  and two other pull request runs. Its own jobs: Lint 0.6 min on Ubuntu, macOS 6.3
  10.6 min, Bazel 9.x macOS 0.9 min, Linux 5.1 to 7.9 min, Swift 6.4 16.2 min after a
  35 min queue wait.
- Nightly dispatch 36097834781 (`nightly` profile, 16 jobs): every job passed, including
  macOS main-snapshot (23.6 min) for the first time in five runs. Bazel 8.x jobs ran in
  1.0 to 1.1 min with full disk-cache hits (87 on macOS, 69 on Linux, zero compiles).

The first push to `master` after #9 merged (run 36152028610, `master` profile: every
stable toolchain, Bazel 8.x and 9.x, no snapshots) passed all 14 jobs and the gate in
16 minutes wall clock, against 41 and 43 minutes for the two baseline pushes. No job
waited more than 2 minutes for a runner.

## Phase 2: less time inside each job (#10)

- `SPMSourceGraphTestCase` keeps the index plan of every package it built with default
  build settings and hands it to later classes in the same process. Builds with custom
  build arguments, `--clean-build`, `--skip-build` or an explicit index store are never
  shared. Locally the six sharing classes dropped from 90 s to 18 s.
- Test runs before Scan on macOS and Linux, so `swift test` extends the cached incremental
  build instead of recompiling after the managed clean. The `--clean-build` scan is
  unchanged.
- The Xcode fixture builds under `~/Library/Caches/com.github.peripheryapp` are cached
  under an exact key over `Tests/XcodeTests/**`, `Sources/XcodeSupport/**`, the Xcode
  version and the Swift version. No fallback key.
- The Swift 6.4 baseline job gets the same dependency and fixture caches, also with exact
  keys only. Its strict self-scan still performs its own managed clean build.
- Matrix jobs have static names so skipped entries display readably.

Results from pull request run 36101658621 (before the baseline-job caches), measured
while the nightly dispatch's snapshot job and another run still held macOS slots:

| Job | Phase 1 run | Phase 2 run |
|---|---|---|
| macOS 6.3: Build / Test / Scan | 0.9 / 6.9 / 2.2 min | 0.7 / 4.8 / 1.3 min |
| macOS 6.3 total | 10.6 min | 7.3 min |
| Linux 6.3: Test | 4.5 min | 2.1 min |
| Linux 6.2: Test | 2.4 min | 1.5 min |
| Linux 6.1: Test | 2.6 min | 2.3 min |
| Wall clock | 52 min | 24 min |

The macOS 6.3 test step went from 494 s of wall time originally to 265 s, while the
suite grew from 324 to 331 tests. The Xcode fixture cache missed on this first run and
was saved for the next.

Local validation of the Phase 2 branch at commit `5b52710` (the #10 head after the
rebase onto the #9 merge): `swift build --product lethen` followed by `swift test`,
default debug configuration, on arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple
Swift 6.4 (swiftlang-6.4.0.34.1). 336 tests passed with 0 failures and 0 skips: 22
XcodeTests, 14 SPMTests, 259 PeripheryTests, 41 AccessibilityTests. The count is five
higher than on the earlier hosted runs because #5 added BazelModuleOverrideTest to
master in between. Hosted evidence for the same changes is in the runs cited above and
in the `swift-6.4-evidence` artifact each Swift 6.4 job uploads.

## Phase 3: self-hosted macOS runner

Implemented as an opt-in in the workflow; the machine itself is the maintainer's to
provide. The `Plan` job exposes a `macos_runner` output taken from the repository
variable `LETHEN_MACOS_RUNNER`, and every macOS job (`Swift 6.4 / Xcode 27`, the macOS
matrix, the macOS Bazel entries and the macOS nightly job) uses that label when it is
set. Pull requests from forks never use it and stay on hosted runners, so untrusted code
never reaches the machine. With the variable empty, which is the current state, the
workflow is unchanged and runs on hosted runners; run 36155445043 and the runs after it
exercise exactly that path. The self-hosted path is untested until a runner exists.

The data after Phase 1 and 2 does not require it yet: a lone pull request with a quiet
queue finishes in 10 to 12 minutes, bounded by the macOS 6.3 job, and macOS waits only
appear when several runs overlap. If overlapping runs become the norm, registering a Mac
and setting the variable removes the five-slot ceiling without further workflow changes.
Larger GitHub-hosted macOS runners are not available on a personal account. The runner
requirements are listed in CONTRIBUTING.md.

## Re-evaluation

After Phase 1 and 2 the pull request critical path is the Swift 6.4 baseline job. Its
13 minutes on run 36101658621 broke down as: 0.6 min checkout and toolchain checks,
2 min resolving and building dependencies from nothing, 7 min `swift test` (SPMTests
3.5 min, of which SPMProjectTest 115 s builds the macro fixture and its swift-syntax
dependency; XcodeTests 102 s; PeripheryTests 59 s; AccessibilityTests 42 s), and 3.5 min
for the three fixture scans and the strict self-scan.

Taken now:

- Dependency and Xcode fixture caches on the baseline job (this pull request). On run
  36103730405 both caches missed, as they must on the first run, and the job still took
  8.6 min against 13.1 min on the run before, with a quiet queue; the whole run took 10
  min wall clock with zero queue wait on every job. The caches were saved for the next
  run, where the 2 min of dependency compilation and the 100 s of Xcode fixture builds
  come from cache. With the caches warm (runs 36152121800 and 36153987628) the job took
  6.6 and 6.8 min, so the pull request critical path is now the macOS 6.3 job at 7 to
  10 min, and the final #10 run (36153987628) took 12 min wall clock with zero queue
  wait. Hosted macOS runners vary noticeably between runs: macOS 6.3 took 7.3 min on
  one run and 10.1 min on another with identical steps.

Recommended, not taken, because each changes a documented policy:

- Run only the `pr` profile on `master` pushes and leave 6.2, 6.1 and Bazel 8.x to the
  nightly schedule. A merge currently queues six macOS jobs behind which the next pull
  request waits. A regression on an older toolchain would then surface the next morning
  instead of at merge time, and release validation can dispatch the `nightly` profile on
  the candidate commit.
- A partial managed clean for SwiftPM: remove only the package's own target products and
  keep compiled dependencies. This would cut roughly two minutes from every managed clean
  build (the strict self-scan, the fixture scans, SPMProjectTest), but it depends on the
  build-system layout and AGENTS.md deliberately trades incremental builds for a
  guaranteed fresh index. It needs its own design and regression tests around
  `SPMIndexStoreIntegrationTest`.
- Move Bazel 9.x macOS off the `pr` profile. It saves a slot, not time (1.3 min), and
  drops the only macOS coverage of the Bazel driver on pull requests.

Not worth changing:

- The Linux teardown regression check (15 sequential scans, about 1 min per Linux job)
  stays on every Linux job. Linux is never on the critical path and the check is the
  documented evidence for the fix.
- Bazel 8.x zero-hit runs coincided with a changed disk-cache key restoring an older
  fallback cache. With an exact key present the cache hits fully. Since 8.x no longer
  runs on pull requests, no further work is planned.

## Method

`gh api repos/albovsky/lethen/actions/runs/<id>/jobs` provides per-job timestamps. For
each job, queue is `started_at - created_at` and run is `completed_at - started_at`;
wall clock is `updated_at - created_at` of the run. Step timings come from the same
endpoint's `steps` array; per-suite test timings from the job logs' `Executed N tests ...
in X (Y) seconds` lines, where X is test code and Y wall time.
