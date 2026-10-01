"""
    Public generated repo extension.
"""

_VERSION_MISMATCH = (
    "LETHEN_BAZEL_GENERATED_DIR is not set. 'lethen scan --bazel' sets it when it runs the generated " +
    "scan, so if lethen ran this, the lethen binary is a different version than the 'periphery' Bazel " +
    "module. They must be the same version: install the lethen version that the 'periphery' override " +
    "in MODULE.bazel points at, or change the override to the installed version " +
    "('lethen scan --setup' prints it)."
)

def _generated_repo_impl(repository_ctx):
    repository_ctx.file(
        "visibility/BUILD.bazel",
        """package_group(
    name = "package_group",
    packages = ["//..."],
)
""",
    )

    # lethen queries this target before it runs the scan, to tell this module from an older one that reads the
    # scan package from /var/tmp. Loading it never loads the scan package.
    repository_ctx.file(
        "lethen_scratch/BUILD.bazel",
        """filegroup(
    name = "v1",
    visibility = ["//visibility:public"],
)
""",
    )

    # `lethen scan --bazel` writes the scan package to a directory private to the user and workspace, and passes
    # it with `--repo_env`.
    generated_dir = repository_ctx.getenv("LETHEN_BAZEL_GENERATED_DIR")
    if generated_dir:
        repository_ctx.symlink(
            generated_dir + "/BUILD.bazel",
            "BUILD.bazel",
        )
    else:
        # Fetching still succeeds, so `bazel fetch --all` and `bazel vendor` work; only loading the scan package
        # fails.
        repository_ctx.file(
            "version_mismatch.bzl",
            """def version_mismatch():
    fail({message})
""".format(message = repr(_VERSION_MISMATCH)),
        )
        repository_ctx.file(
            "BUILD.bazel",
            """load(":version_mismatch.bzl", "version_mismatch")

version_mismatch()
""",
        )

generated_repo = repository_rule(
    implementation = _generated_repo_impl,
    # Declared as well as read through `getenv`, so a fetch without the variable is never reused by a scan with it.
    environ = ["LETHEN_BAZEL_GENERATED_DIR"],
)

generated = module_extension(implementation = lambda _: generated_repo(name = "periphery_generated"))
