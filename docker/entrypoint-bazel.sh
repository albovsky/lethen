#!/bin/bash
# Entry point for the Bazel image: runs the lethen scanner built by `bazel build //:periphery`
# with whatever arguments `docker run` passes, e.g. `scan --bazel --baseline baselines/linux-bazel.json`.
set -euo pipefail
cd /workspace
exec bazel run //:periphery -- "$@"
