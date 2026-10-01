#!/usr/bin/env bash
# Checks that the Release workflow runs release binaries only in unprivileged jobs.
#
# It is a tripwire against a privileged job starting to run the binary by accident, so it
# errs toward flagging: any use of the binary's path that is not known to be harmless fails.
# A shell script can always hide a command from a static check, so changes to the release
# workflow still need review; the check makes the ordinary ways of running the binary fail.
#
# The `smoke-test` job of release.yml runs the signed binary, directly and through
# `brew test`, so it must have no environment (whose secrets it could read), no reference
# to secrets, and no write permission, whether granted to the job or inherited from the
# workflow. No job that has an environment, secrets, or a write permission may run the
# binary in any of the ways the workflow does: the binary itself, release-smoke-test.sh, `brew install`,
# `brew reinstall` or `brew test`, or `release-homebrew.sh test`, which runs those brew
# commands. So none of them can move back into a privileged job. `mise run lint-ci` runs
# this check.
#
# Usage: check-release-isolation.sh [workflow-file] [scripts-directory]
# check-release-isolation-test.sh runs it against mutated copies of the workflow.
set -euo pipefail

workflow="${1:-.github/workflows/release.yml}"
scripts="${2:-$(dirname "$0")}"

ruby -ryaml - "$workflow" "$scripts" <<'RUBY'
path = ARGV.fetch(0)
scripts = ARGV.fetch(1)
workflow = YAML.safe_load(File.read(path), aliases: true)
jobs = workflow.fetch("jobs", {}) || {}
problems = []

# `permissions` is a scope map, `read-all`, `write-all`, or absent (inherited).
def write_scopes(permissions)
  case permissions
  when nil then []
  when String then permissions == "read-all" ? [] : [permissions]
  when Hash then permissions.select { |_, access| access.to_s != "read" && access.to_s != "none" }.keys
  else [permissions.inspect]
  end
end

# Every key and value in a job, so an expression is found wherever it appears.
def text(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + text(value) }
  when Array then node.flat_map { |value| text(value) }
  else [node.to_s]
  end
end

# A Method needle is a check of the whole job, given the job.
def mentions?(job, needle)
  return needle.call(job) if needle.is_a?(Method)

  text(job).any? { |value| needle.is_a?(Regexp) ? value.match?(needle) : value.include?(needle) }
end

# Any use of the `secrets` context in an expression: `secrets.NAME`, `secrets['NAME']`,
# `toJSON(secrets)`, and so on. Anything after `${{` in the same value counts, so a brace inside
# a string literal in the expression cannot end the search early.
SECRETS = /\$\{\{.*\bsecrets\b/m

# A path to the lethen binary, or a bare `lethen`, as one word: `build/lethen`,
# `"$PWD/released/lethen"`, `./lethen`. `dist/lethen-<tag>.zip` is not one.
LETHEN_WORD = %r{(?<![\w./-])["']?(?:[^\s"';&|()`<>]*/)?lethen["']?(?![\w.-])}

# Commands that take the binary's path as an argument without running it or making a copy
# under another name. Copying or renaming it (`cp`, `mv`, `ditto`, `ln`) is not exempt,
# because the copy could then run without naming lethen.
PATH_ONLY_COMMANDS = %w[chmod codesign file ls rm shasum spctl stat].freeze

# Repository scripts that take the binary's path and only sign, inspect or package it. Each is
# checked below never to run its `binary` argument; any other script given the path is flagged.
PATH_ONLY_SCRIPTS = %w[release-relocate-rpaths.sh release-sign-macos.sh].freeze

# The exact paths a job may run them by: the release jobs check the tooling out under `tools`,
# the build job uses its own checkout. A script elsewhere with the same name is not exempt.
PATH_ONLY_SCRIPT_PATHS = PATH_ONLY_SCRIPTS.flat_map { |script| ["tools/.github/scripts/#{script}", ".github/scripts/#{script}"] }.freeze

# The commands those scripts may hand `$binary` to. Any other use of it, however it is
# reached (`if "$binary" ...`, `env "$binary"`, a new function), fails the check. `rpaths`
# is release-relocate-rpaths.sh's own function, which runs `otool -l` on its argument.
HELPER_PATH_COMMANDS = %w[codesign cp install_name_tool lipo otool rpaths spctl].freeze

# The simple commands of a shell script: lines joined across `\` continuations, then split at
# `;`, `&`, `|`, `$(`, `<(`, `>(`, backticks and `)`.
def simple_commands(script)
  script.to_s.gsub(/\\\n/, " ").split(/\n|;|&|\||\$\(|<\(|>\(|`|\)/)
end

# The words of a simple command from the command name on: leading control-flow keywords (`if`,
# `then`, `!`, ...) and variable assignments are dropped, and quotes are removed.
def command_words(segment)
  words = segment.strip.split(/\s+/).map { |word| word.delete("\"'") }
  words.shift while %w[if then elif else while until do ! { time].include?(words.first) || words.first&.match?(/\A\w+=/)
  words
end

# Whether `script` uses the lethen binary anywhere except as an argument to a command known
# not to run it, so a new wrapper (`command`, `env`, `sudo`, `arch`, `open`, ...) or a direct
# call is caught without being listed. Only the scripts in PATH_ONLY_SCRIPTS may take the path.
def runs_lethen?(script)
  simple_commands(script).any? do |segment|
    next false unless segment.match?(LETHEN_WORD)

    words = command_words(segment)
    command = words.first.to_s
    next false if PATH_ONLY_COMMANDS.include?(command)
    next false if command == "swift" && words[1] == "build"
    next false if command == "bash" && PATH_ONLY_SCRIPT_PATHS.include?(words[1].to_s)

    true
  end
end

# Whether a job runs the binary from a `run` script, or hands its path to a step through `env`
# or `with`, where a script could run it as `"$BINARY"` without naming it. Step names and other
# text are not checked.
def uses_lethen?(job)
  passes_path = ->(node) { text(node).any? { |value| value.match?(LETHEN_WORD) } }
  passes_path.call(job.slice("env", "defaults")) || Array(job["steps"]).any? do |step|
    step.is_a?(Hash) && (runs_lethen?(step["run"]) || passes_path.call(step.slice("env", "with")))
  end
end

# Commands that run the release binary.
BINARY_RUNNERS = {
  "the lethen binary" => method(:uses_lethen?),
  "release-smoke-test.sh" => "release-smoke-test.sh",
  "brew install, reinstall or test" => /\bbrew\s+(install|reinstall|test)\b/,
  "release-homebrew.sh test" => /release-homebrew\.sh\s+test\b/,
}.freeze

def effective_permissions(workflow, job)
  job.key?("permissions") ? job["permissions"] : workflow["permissions"]
end

# Workflow-level `env` and `defaults` reach every job, the smoke test included.
problems << "references secrets at the workflow level, which every job inherits" if mentions?(workflow.slice("env", "defaults"), SECRETS)
problems << "passes the lethen binary's path at the workflow level, which every job inherits" if mentions?(workflow.slice("env", "defaults"), LETHEN_WORD)

smoke = jobs["smoke-test"]
if smoke.nil?
  problems << "has no smoke-test job"
else
  problems << "gives the smoke-test job an environment" if smoke.key?("environment")
  problems << "gives the smoke-test job secrets" if smoke.key?("secrets")
  problems << "references secrets in the smoke-test job" if mentions?(smoke, SECRETS)
  if workflow.key?("permissions") || smoke.key?("permissions")
    scopes = write_scopes(effective_permissions(workflow, smoke))
    problems << "gives the smoke-test job write permissions: #{scopes.join(', ')}" unless scopes.empty?
  else
    problems << "leaves the smoke-test job with the repository's default token permissions"
  end
end

jobs.each do |name, job|
  BINARY_RUNNERS.each do |command, pattern|
    next unless mentions?(job, pattern)

    problems << "runs #{command} in #{name}, which has an environment" if job.key?("environment")
    problems << "runs #{command} in #{name}, which has secrets" if job.key?("secrets") || mentions?(job, SECRETS)
    permissions = effective_permissions(workflow, job)
    scopes = permissions.nil? ? ["the repository's default token permissions"] : write_scopes(permissions)
    problems << "runs #{command} in #{name}, which can write: #{scopes.join(', ')}" unless scopes.empty?
  end
end

# The exempt scripts must keep their promise: none runs its `binary` argument as a command.
PATH_ONLY_SCRIPTS.each do |script|
  source = File.join(scripts, script)
  next problems << "exempts #{script}, which does not exist" unless File.exist?(source)

  runs_binary = simple_commands(File.read(source)).any? do |segment|
    next false unless segment.match?(/\$\{?binary\b/)

    command = command_words(segment).first
    !command.nil? && !HELPER_PATH_COMMANDS.include?(command)
  end
  problems << "exempts #{script}, which runs its binary argument" if runs_binary
end

if problems.empty?
  puts "#{path}: release binaries run only in unprivileged jobs"
else
  problems.each { |problem| warn "::error file=#{path}::#{path} #{problem}" }
  exit 1
end
RUBY
