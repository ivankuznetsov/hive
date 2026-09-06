# Frozen_string_literal: true

require "open3"

# Local fast-loop machinery behind `rake coverage:changed`: map git-diff
# touched lib sources to their focused test files, and enforce the exact
# line-coverage contract on the changed sources only. The global 100% gate
# stays CI's job. Mapping is intentionally conservative: a touched source
# uses mirrored tests, exact require references, owning facades, or explicit overrides.
module HiveChangedCoverage
  SOURCE_PATTERN = %r{\Alib/.*\.rb\z}
  TEST_ROOTS = %w[test/unit test/integration test/babysitter].freeze
  CI_GATE_FILES = %w[
    test/integration/web_packaged_bootstrap_test.rb
    test/integration/tui_reactivity_perf_test.rb
    test/integration/setup_agents_test.rb
    test/unit/babysitter/dry_run_security_matrix_test.rb
  ].freeze
  MappingError = Class.new(StandardError)

  # Deliberate source-to-test exceptions where naming conventions do not hold.
  # Values are repo-relative test files or empty arrays (no focused test).
  SOURCE_TEST_OVERRIDES = {
    "lib/hive/version.rb" => [],
    "lib/hive/errors.rb" => [],
    "lib/hive/commands/migrate.rb" => [ "test/integration/migrate_test.rb" ],
    "lib/hive/commands/setup.rb" => [ "test/unit/commands/setup/orchestrator_test.rb" ],
    "lib/hive/user_service.rb" => [ "test/unit/user_service/user_service_test.rb" ],
    "lib/hive/user_service/plan.rb" => [ "test/unit/user_service/user_service_test.rb" ],
    "lib/hive/stages/review.rb" => [
      "test/integration/run_review_test.rb",
      "test/unit/stages/review/ci_gates_test.rb",
      "test/unit/stages/review/run_reviewers_test.rb"
    ]
  }.freeze

  module_function

  # Include committed branch work, staged/unstaged edits, deletions and new files.
  def changed_paths(base:)
    merge_base = git_output("merge-base", "HEAD", base).strip
    (git_output("diff", "--name-only", "-z", "--no-renames", merge_base).split("\0") +
      git_output("ls-files", "--others", "--exclude-standard", "-z").split("\0")).uniq.sort
  end

  def git_output(*arguments)
    output, error, status = Open3.capture3("git", *arguments)
    raise "git #{arguments.first} failed: #{error.strip}" unless status.success?

    output
  end

  def changed_sources(base:)
    changed_paths(base: base).select { |path| path.match?(SOURCE_PATTERN) && File.file?(path) }
  end

  def test_files_for(source, reference_index: nil)
    return SOURCE_TEST_OVERRIDES.fetch(source).dup if SOURCE_TEST_OVERRIDES.key?(source)

    stem = source.delete_prefix("lib/").delete_suffix(".rb")
    stems = [ stem, stem.delete_prefix("hive/") ].uniq
    direct = TEST_ROOTS.product(stems).flat_map do |root, candidate|
      [ File.join(root, "#{candidate}_test.rb"), *Dir.glob(File.join(root, candidate, "**/*_test.rb")) ]
    end.select { |path| File.file?(path) && !CI_GATE_FILES.include?(path) }
    return direct.uniq.sort unless direct.empty?

    # Exact require paths are evidence of ownership; basename matches are not.
    index = reference_index ? reference_index.call : require_index
    references = (index.fetch(stem, []) + index.fetch(File.expand_path(source), [])).uniq.sort
    return references unless references.empty?

    # A nested implementation can be covered by the nearest owning facade.
    parents = stems.map { |candidate| File.dirname(candidate) }.reject { |candidate| candidate == "." }
    until parents.empty?
      owned = TEST_ROOTS.product(parents).flat_map do |root, candidate|
        [ File.join(root, "#{candidate}_test.rb"), *Dir.glob(File.join(root, candidate, "**/*_test.rb")) ]
      end.select { |path| File.file?(path) && !CI_GATE_FILES.include?(path) }
      return owned.uniq.sort unless owned.empty?

      parents = parents.map { |candidate| File.dirname(candidate) }.reject { |candidate| candidate == "." || candidate == "hive" }.uniq
    end
    raise MappingError, "coverage:changed: no owner test for #{source}; add an explicit override"
  end

  def require_index
    root_tests.each_with_object({}) do |test, index|
      File.read(test).scan(/require(?:_relative)?\s*[ (]\s*["']([^"']+)["']/).flatten.each do |required|
        stem = required.delete_suffix(".rb")
        [ stem, File.expand_path(stem + ".rb", File.dirname(test)) ].each do |key|
          (index[key] ||= []) << test
        end
      end
    end
  end

  def root_tests
    Dir.glob("test/{unit,integration,babysitter}/**/*_test.rb").sort - CI_GATE_FILES
  end

  def selection(paths:)
    index = nil
    reference_index = -> { index ||= require_index }
    selected = { root: [], components: {}, web: [], reasons: [], ignored: [] }
    root_expanded = false
    all_expanded = false
    expand_root = lambda do
      unless root_expanded
        selected[:root].concat(root_tests)
        root_expanded = true
      end
    end
    all = lambda do |reason|
      selected[:reasons] << reason
      unless all_expanded
        expand_root.call
        Dir.glob("components/*/test").each do |dir|
          selected[:components][File.dirname(dir)] = Dir.glob("#{dir}/**/*_test.rb").sort
        end
        selected[:web].concat(Dir.glob("web/test/**/*_test.rb"))
        all_expanded = true
      end
    end
    paths.each do |path|
      case path
      when %r{\A(?:docs/|wiki/|raw/|[^/]+\.md\z)}
        selected[:ignored] << path
      when %r{\Atest/(?:unit|integration|babysitter)/.*_test\.rb\z}
        if File.file?(path)
          selected[:root] << path
        else
          selected[:reasons] << "#{path}: deleted test; running root suite"
          expand_root.call
        end
      when SOURCE_PATTERN
        begin
          tests = test_files_for(path, reference_index: reference_index)
          raise MappingError, "bootstrap source" if tests.empty?
          selected[:root].concat(tests)
        rescue MappingError
          selected[:reasons] << "#{path}: no focused owner; running root suite"
          expand_root.call
        end
      when %r{\Acomponents/([^/]+)/}
        component = "components/#{$1}"
        files = path.match?(%r{/test/.*_test\.rb\z}) && File.file?(path) ? [ path ] : Dir.glob("#{component}/test/**/*_test.rb")
        selected[:components][component] ||= []
        selected[:components][component].concat(files)
        selected[:reasons] << "#{path}: component suite" unless files == [ path ]
        # Hive consumes component behavior too.
        expand_root.call unless path.include?("/test/") && File.file?(path)
      when %r{\Aweb/}
        files = path.match?(%r{\Aweb/test/.*_test\.rb\z}) && File.file?(path) ? [ path ] : Dir.glob("web/test/**/*_test.rb")
        selected[:web].concat(files)
        unless files == [ path ]
          selected[:root].concat(root_tests.select { |test| test.match?(%r{\Atest/(?:unit/web(?:/|_)|integration/web_)}) })
        end
        selected[:reasons] << "#{path}: Rails suite" unless files == [ path ]
      else
        all.call("#{path}: shared or unclassified change; running offline suites")
      end
    end
    selected[:root] = selected[:root].uniq.sort
    selected[:web] = selected[:web].uniq.sort
    selected[:components].transform_values! { |files| files.uniq.sort }
    selected
  end

  def test_files_for_sources(sources)
    index = nil
    reference_index = -> { index ||= require_index }
    sources.flat_map { |source| test_files_for(source, reference_index: reference_index) }.uniq.sort
  end

  # Exact-coverage contract on the changed sources only: every executable
  # line covered, and the source actually loaded by the focused run.
  def enforce(report, sources:)
    files_by_path = Array(report[:files] || report["files"])
      .each_with_object({}) do |file, hash|
        hash[value(file, :file)] = file
      end

    failures = Array(report[:result_errors] || report["result_errors"]).map { |error| "coverage result: #{error}" }
    sources.each do |source|
      entry = files_by_path[source]
      if entry.nil? || entry[:loaded] == false || entry["loaded"] == false
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
