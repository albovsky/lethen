# Pett scan correctness audit

Audit date: 2026-09-19. This is a bounded manual sample, not a claim that every result is correct or every unused declaration is found.

## Scan identity and scope

The audit uses a temporary copy of tracked Pett revision `84edfbb84c5715720be014befcfcd5c0e6067a54`. The original checkout and its untracked files were not changed. Its existing configuration has SHA-256 `8b1fcd179ca21e9563e74a21363f297e0d291126d183d8235a8a20bf7027f0a2`: project/scheme Pett, SwiftUI previews and Codable properties retained, no added exclusions. Raw JSON, source-review notes, exact local paths, and temporary test harnesses remain outside this public repository.

Toolchain: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), Xcode 27.0 (`27A266a`), arm64 macOS 27.0 (`26A428`). Builds use the generic iOS Simulator destination and iOS Simulator 27 SDK. Mutation tests use an available iPhone 18 Pro simulator running iOS 27.

The baseline CLI was built from `6096738`; the corrected analysis is in `414cd82`. Absolute CLI paths are resolved using `swift build --show-bin-path`, and the private manifest records binary hashes. Scan invocation, with local paths replaced by placeholders:

```bash
"$lethen_bin" scan --project-root "$audit_root" --config "$audit_root/.periphery.yml" \
  --disable-update-check --clean-build --format json --relative-results --quiet \
  -- -destination 'generic/platform=iOS Simulator'
```

The warm run omits `--clean-build`. Canonical comparisons retain location, kind, name, hints, and symbol IDs; they normalize ordering and checkout roots only. The analyzed plan contains 1,431 source files and includes Pett, PettTests, PettUITests, the local values package, the screenshot widget extension, and indexed dependencies. Inclusion was asserted before interpreting findings. The local values package's standalone tests are outside the app scheme, an important boundary for its public APIs.

## Selection and results

The original clean and warm scans agree on 240 findings: 127 unused, 86 assign-only, and 27 redundant-public findings.

Selection is deterministic: sort by normalized source path, declaration name, source line, and hints; take the first five findings in each emitted hint category, then the first two additional findings in each available application, feature, UI-component, test, model, and repository domain; include attributed ObjC/dynamic findings if available; fill to 30 from the same stable sort. There were no application-entry or ObjC/dynamic attributed findings to sample. Runtime entry coverage is checked separately below.

References were checked against indexed declarations, Swift source, overload signatures, protocol/conformance behavior, and relevant runtime or tooling consumers. Source-search absence alone was not used as evidence for runtime-visible code. Public identifiers below are anonymized; stable audit IDs map to the private sample.

| ID | Declaration and hint | Classification and evidence |
| --- | --- | --- |
| F01 | Font face resource-path field; assign-only | Correct Swift assign-only advisory. A Ruby typography guardrail consumes the initializer metadata. Keep it; this is not removal evidence. |
| F02 | Migration-result count field; assign-only | False positive, fixed. Synthesized equality reads the field in a result-comparison test. |
| F03 | Authentication request confirmation field; assign-only | False positive, fixed. Request equality is asserted in tests; no explicit getter read is indexed. |
| F04 | Stored current-user callback; assign-only | True positive within the indexed code. Initializers store weak-capture callbacks, but the stored callback is never invoked. |
| F05 | Mock service's last-provider field; assign-only | True positive. Tests consume call counts rather than this field. Removal plus relevant authentication tests passed. |
| F06 | Schema alias A; redundant public | True positive for access level. Alias consumers are internal or use `@testable`; do not delete or alter the persistence schema. |
| F07 | Schema alias B; redundant public | Same access-level evidence as F06. |
| F08 | Schema alias C; redundant public | Same access-level evidence as F06. |
| F09 | Schema alias D; redundant public | Same access-level evidence as F06. |
| F10 | Schema alias E; redundant public | Same access-level evidence as F06. |
| F11 | Local values-package calendar type; unused | True positive within the app scheme. Its standalone package consumers/tests are outside this scan; not a universal API-removal recommendation. |
| F12 | Local values-package integer wrapper; unused | Same build-boundary evidence as F11. |
| F13 | Local values-package error alias; unused | Same build-boundary evidence as F11. |
| F14 | Local values-package calendar error case; unused | Reached only from code unused by this app scheme. Same limitation as F11. |
| F15 | Local values-package calendar-identifier error case; unused | Same reachability and build-boundary evidence as F14. |
| F16 | Login password-visibility state; unused | False positive, fixed. A reachable SwiftUI view passes the generated projection as a binding. |
| F17 | Registration password-visibility state; unused | False positive, fixed. Same indexed projection gap as F16. |
| F18 | Fallback presentation-window field; assign-only | Correct assign-only advisory with intentional ownership. The strong field keeps the window alive while another anchor is weak. Keep it. |
| F19 | Nested preview selection state; unused | False positive, fixed. A retained preview consumes its generated binding. |
| F20 | Transaction snapshot relationship field; assign-only | False positive, fixed. Synthesized snapshot equality verifies rollback state. |
| F21 | Transaction snapshot date field; assign-only | False positive, fixed. Same equality evidence as F20. |
| F22 | Legacy source-artifact restore method; unused | True positive. No runtime attribute or dispatch requirement; callers use the current persistence path. Temporary removal and document tests passed. |
| F23 | Legacy source-artifact update overload; unused | True positive. The referenced overload takes a validated artifact, not these arguments. Temporary removal and document tests passed. |
| F24 | Repository actor access level; redundant public | True positive. App-internal and `@testable` consumers do not require public access. |
| F25 | Repository query access level; redundant public | Same access-level evidence as F24. |
| F26 | Local values-package currency-scale error case; unused | True positive within the app scheme; same package boundary as F14. |
| F27 | Local values-package interval error case; unused | Same reachability and build-boundary evidence as F14. |
| F28 | Local values-package recurrence error case; unused | Same reachability and build-boundary evidence as F14. |
| F29 | Local values-package scale error case; unused | Same reachability and build-boundary evidence as F14. |
| F30 | Local values-package time-zone error case; unused | Same reachability and build-boundary evidence as F14. |

Of the original 30 findings, seven were false positives reproduced and fixed, and 23 remain valid diagnostics within the scan contract. Two of those 23 explicitly describe intentional/tooling-related storage and must not be treated as safe deletions. The fixes retain all seven affected sampled declarations without enabling extra configuration flags. No sampled correctness question remains unresolved; conclusions about unused package APIs are limited to the stated build boundary.

## Regression and retention checks

The public regression fixtures are synthetic; they contain no private implementation. Two tests initially failed four assertions. The fixes connect source-level projected-property uses back to their source declaration and model possible synthesized equality reads from callers of a value type. They preserve existing option assertions and negative controls for unused projections, unreachable callers, and explicit equality implemented in members, extensions, protocol defaults, or global operators. Equality modeling is conservative: a value passed to generic/external code may be compared even when the index omits the synthesized body. This can retain fields without proving an equality call executes at runtime.

Eleven independently selected known-used declarations were asserted present and referenced: the app entry point, root composition view, UIKit notification delegate, versioned persistence schema, two nested persistent models, the user model, a repository protocol and dispatched method, and a Swift Testing suite and test method. The temporary harness also asserted app/unit-test/UI-test module coverage. It passed and was removed from the repository.

Temporary removal of F05, F22, and F23 changed only two files in the isolated copy, preserving persisted fields and schema definitions. `xcodebuild test` selected the relevant document source-artifact, transaction, and authentication suites: 16 XCTest tests and 44 Swift Testing tests passed. Sources were restored afterward. Compilation supports these findings together with the reference review; it does not establish general runtime safety.

A new helper was reported as unused. Adding a call from the reachable app initializer retained it, with every other finding identity unchanged. The helper and call were removed; all 1,143 tracked files were byte-compared against the frozen revision before the final scans.

The final restored clean and warm scans agree on **154 findings**: 120 unused, seven assign-only, and 27 redundant-public. The change from 240 comprises seven projected-state findings and 79 synthesized-equality assign-only findings. Only the declared sample was manually adjudicated; the other changed findings are not counted as independently verified. The private verification manifest checks the sample identities, both canonical sets, helper transition, retained-control evidence, mutation test success, and restoration.

| Artifact | SHA-256 |
| --- | --- |
| Original clean JSON | `94250b751e73f1ce0ff3595d86f6b66097fd9a0de947fc909b7a952f3385879c` |
| Original warm JSON | `b29fa3de1a35b0e22bbc78ef53c474908b42fed17ec5a28fc71611c3d8ddc79b` |
| Final clean JSON | `0dba95aab2c08bf62f45d9f080a7ae34ec41d5f2d270fef24158d4d1a93e6df4` |
| Final warm JSON | `e71c863816476ab608a7cbe6c969951d8e6f8211fcfb7e98e61e5ddbb670757e` |
| Final canonical set, both runs | `d6a6094fb400b15d9ebead2ed352359cff147c355ac4ba01c825c3138d52a95f` |

Raw JSON hashes differ because ordering is not stable. The canonical sets are identical, including all declaration categories. Release installation and hosted CI remain separately documented in the [toolchain report](swift-6.4-xcode-27.md).
