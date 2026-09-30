#!/usr/bin/env bash
# Checks that the Release workflow runs release binaries only in unprivileged jobs.
#
# The `smoke-test` job of release.yml runs the signed binary, so it must have no
# environment (whose secrets it could read), no reference to secrets, and no write
# permission, whether granted to the job or inherited from the workflow. No job that has
# an environment or a write permission may run release-smoke-test.sh either, so the smoke
# test cannot move back into a privileged job. `mise run lint-ci` runs this check.
#
# Usage: check-release-isolation.sh [workflow-file]
set -euo pipefail

workflow="${1:-.github/workflows/release.yml}"

ruby -ryaml - "$workflow" <<'RUBY'
path = ARGV.fetch(0)
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

def mentions?(job, needle)
  text(job).any? { |value| value.include?(needle) }
end

def effective_permissions(workflow, job)
  job.key?("permissions") ? job["permissions"] : workflow["permissions"]
end

smoke = jobs["smoke-test"]
if smoke.nil?
  problems << "has no smoke-test job"
else
  problems << "gives the smoke-test job an environment" if smoke.key?("environment")
  problems << "gives the smoke-test job secrets" if smoke.key?("secrets")
  problems << "references secrets in the smoke-test job" if mentions?(smoke, "secrets.")
  if workflow.key?("permissions") || smoke.key?("permissions")
    scopes = write_scopes(effective_permissions(workflow, smoke))
    problems << "gives the smoke-test job write permissions: #{scopes.join(', ')}" unless scopes.empty?
  else
    problems << "leaves the smoke-test job with the repository's default token permissions"
  end
end

jobs.each do |name, job|
  next unless mentions?(job, "release-smoke-test.sh")
  problems << "runs release-smoke-test.sh in #{name}, which has an environment" if job.key?("environment")
  problems << "runs release-smoke-test.sh in #{name}, which references secrets" if mentions?(job, "secrets.")
  scopes = write_scopes(effective_permissions(workflow, job))
  problems << "runs release-smoke-test.sh in #{name}, which can write: #{scopes.join(', ')}" unless scopes.empty?
end

if problems.empty?
  puts "#{path}: release binaries run only in unprivileged jobs"
else
  problems.each { |problem| warn "::error file=#{path}::#{path} #{problem}" }
  exit 1
end
RUBY
