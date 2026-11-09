# Shared by the installer and both lint tasks. Keg-only tools leave the user's PATH alone.
lint_tap=albovsky/lethen-tools
format_formula=swiftformat@0.58.7
lint_formula=swiftlint@0.63.0

require_lint_tools() {
    local prefix
    prefix="$(brew --prefix)"
    swiftformat="$prefix/opt/$format_formula/bin/swiftformat"
    swiftlint="$prefix/opt/$lint_formula/bin/swiftlint"
    if [[ ! -x "$swiftformat" || ! -x "$swiftlint" ]]; then
        echo "Install Lethen's pinned tools with dev/install-lint-tools." >&2
        return 1
    fi
}
