# Frozen_string_literal: true

require "shellwords"

# Local fast-loop machinery behind `rake coverage:changed`: map git-diff
# touched lib sources to their focused test files, and enforce the exact
# line-coverage contract on the changed sources only. The global 100% gate
# stays CI's job. Mapping is intentionally conservative: a touched source
# needs a mirrored test path or an explicit override.
module HiveChangedCoverage
  SOURCE_PATTERN = %r{\Alib/.*\.rb\z}
  TEST_ROOTS = %w[test/unit test/integration test/babysitter].freeze
  MappingError = Class.new(StandardError)

  # Deliberate source-to-test exceptions where naming conventions do not hold.
  # Values are repo-relative test files or empty arrays (no focused test).
  SOURCE_TEST_OVERRIDES = {
    "lib/hive/version.rb" => [],
    "lib/hive/errors.rb" => [],
    "lib/hive/stages/review.rb" => [
      "test/integration/run_review_test.rb",
      "test/unit/stages/review/ci_gates_test.rb",
      "test/unit/stages/review/run_reviewers_test.rb"
    ]
  }.freeze

  module_function

  # Repo-relative changed source paths (tracked files only) versus the merge
  # base. Untracked files are out of scope by design: they are new work the
  # developer has not staged.
  def changed_sources(base:)
    diff = `git diff --name-only #{Shellwords.escape(base)}`
    raise "git diff failed: #{$?.exitstatus}" unless $?.success?

    diff.split("\n").select { |path| path.match?(SOURCE_PATTERN) && File.exist?(path) }.sort
  end

  def test_files_for(source)
    return SOURCE_TEST_OVERRIDES.fetch(source, []).dup if SOURCE_TEST_OVERRIDES.key?(source)

    stem = source.delete_prefix("lib/").delete_suffix(".rb")
    stems = [ stem, stem.delete_prefix("hive/") ].uniq

    direct = TEST_ROOTS.product(stems).map { |root, candidate| File.join(root, "#{candidate}_test.rb") }
      .select { |path| File.exist?(path) }
    return direct.sort unless direct.empty?

    basename = File.basename(stem)
    matches = Dir.glob("test/{unit,integration,babysitter}/**/#{basename}_test.rb").sort
    detail = matches.empty? ? "no basename matches exist" : "basename matches are ambiguous: #{matches.join(', ')}"
    raise MappingError,
          "coverage:changed: no mirrored test file for #{source}; add an explicit override (#{detail})"
  end

  def test_files_for_sources(sources)
    sources.flat_map { |source| test_files_for(source) }.uniq.sort
  end

  # Exact-coverage contract on the changed sources only: every executable
  # line covered, and the source actually loaded by the focused run.
  def enforce(report, sources:)
    files_by_path = Array(report[:files] || report["files"])
      .each_with_object({}) do |file, hash|
        hash[value(file, :file)] = file
      end

    failures = []
    sources.each do |source|
      entry = files_by_path[source]
      if entry.nil?
        failures << "#{source}: never loaded by the focused run"
        next
      end

      uncovered = Array(value(entry, :uncovered_lines))
      failures << "#{source}: uncovered lines #{compact(uncovered)}" unless uncovered.empty?
    end
    failures
  end

  def value(hash, key)
    hash[key] || hash[key.to_s]
  end

  def compact(lines)
    text = lines.first(40).join(", ")
    lines.length > 40 ? "#{text}, ..." : text
  end
end
