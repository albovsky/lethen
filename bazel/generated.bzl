"""
    Public generated repo extension.
"""

def _generated_repo_impl(repository_ctx):
    # `lethen scan --bazel` writes the generated package to a directory private to the user and workspace, and
    # passes it with `--repo_env`.
    generated_dir = repository_ctx.getenv("LETHEN_BAZEL_GENERATED_DIR")
    if not generated_dir:
        fail(
            "LETHEN_BAZEL_GENERATED_DIR is not set. 'lethen scan --bazel' sets it when it runs the generated " +
            "scan, so if lethen ran this, the lethen binary is a different version than the 'periphery' Bazel " +
            "module. They must be the same version: install the lethen version that the 'periphery' override " +
            "in MODULE.bazel points at, or change the override to the installed version " +
            "('lethen scan --setup' prints it).",
        )

    repository_ctx.file(
        "visibility/BUILD.bazel",
        """package_group(
    name = "package_group",
    packages = ["//..."],
)
""",
    )
    repository_ctx.symlink(
        generated_dir + "/BUILD.bazel",
        "BUILD.bazel",
    )

generated_repo = repository_rule(
    implementation = _generated_repo_impl,
)

generated = module_extension(implementation = lambda _: generated_repo(name = "periphery_generated"))
