# Contributing to lethen

Lethen continues the MIT-licensed Periphery codebase. Contributions are accepted under the repository's MIT license; retain existing copyright and license notices.

Start with `swift build --product lethen` and `swift test`. Xcode integration tests need full Xcode and the fixture SDKs. Include your OS, Swift and Xcode versions in bug reports, together with the command, relevant configuration, and a minimal reproducible project. Remove secrets and proprietary code before sharing fixtures.

Analysis changes should include a regression test demonstrating both declarations that must be reported and declarations that must be retained where applicable. Discuss major features and dependency or distribution changes in an issue first. Prefer small, reviewable patches; generated or AI-assisted changes need the same evidence as any other contribution.

Initial scope is compatibility and correctness maintenance. Support is best-effort. Existing Periphery configuration and comment syntax remain compatible. Do not mass-rename internal modules or fixtures as part of branding changes.

The inherited release automation is disabled until independent signing, packaging, and distribution are configured. Do not use upstream credentials or publish into upstream registries. No lethen release is implied by the inherited Git tags.
