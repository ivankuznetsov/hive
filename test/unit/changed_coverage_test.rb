require "test_helper"
require_relative "../support/changed_coverage"

module TestChangedCoverage
  class MappingTest < Minitest::Test
    def test_mirrored_convention_maps_source_to_its_test_files
      files = HiveChangedCoverage.test_files_for("lib/hive/commands/run.rb")

      assert_equal [ "test/unit/commands/run_test.rb" ], files
    end

    def test_basename_only_match_is_rejected_as_ambiguous
      source = nil
      # Find a real lib source whose mirrored test path does not exist but
      # whose basename matches some test file somewhere in the suite.
      Dir.glob("lib/**/*.rb").each do |path|
        stem = path.delete_prefix("lib/").delete_suffix(".rb")
        stems = [ stem, stem.delete_prefix("hive/") ].uniq
        next if HiveChangedCoverage::TEST_ROOTS.product(stems).any? do |root, candidate|
          File.exist?(File.join(root, "#{candidate}_test.rb"))
        end

        basename = File.basename(stem)
        fallbacks = Dir.glob("test/{unit,integration,babysitter}/**/#{basename}_test.rb")
        next if fallbacks.empty?

        source = path
        break
      end

      skip "no basename-fallback case currently exists in the tree" unless source

      error = assert_raises(HiveChangedCoverage::MappingError) do
        HiveChangedCoverage.test_files_for(source)
      end
      assert_includes error.message, source
      assert_includes error.message, "explicit override"
    end

    def test_explicit_override_can_require_only_the_coverage_bootstrap
      files = HiveChangedCoverage.test_files_for_sources([ "lib/hive/version.rb" ])

      assert_empty files
    end

    def test_override_table_takes_precedence_over_conventions
      HiveChangedCoverage::SOURCE_TEST_OVERRIDES.each_key do |source|
        expected = HiveChangedCoverage::SOURCE_TEST_OVERRIDES.fetch(source)

        assert_equal expected.sort, HiveChangedCoverage.test_files_for(source).sort,
                     "override must be authoritative for #{source}"
      end
    end

    def test_deduplicates_shared_test_files_across_sources
      files = HiveChangedCoverage.test_files_for_sources(
        [ "lib/hive/commands/run.rb", "lib/hive/commands/run.rb" ]
      )

      assert_equal files.uniq.sort, files
    end
  end

  class EnforcementTest < Minitest::Test
    def test_exact_coverage_holds_when_all_changed_lines_covered
      report = {
        "files" => [
          { "file" => "lib/hive/a.rb", "line_total" => 5, "line_covered" => 5, "uncovered_lines" => [] },
          { "file" => "lib/hive/b.rb", "line_total" => 9, "line_covered" => 7, "uncovered_lines" => [ 3, 4 ] }
        ]
      }

      failures = HiveChangedCoverage.enforce(report, sources: [ "lib/hive/a.rb" ])

      assert_empty failures
    end

    def test_uncovered_lines_fail_with_line_numbers
      report = {
        "files" => [
          { "file" => "lib/hive/b.rb", "uncovered_lines" => [ 3, 4 ] }
        ]
      }

      failures = HiveChangedCoverage.enforce(report, sources: [ "lib/hive/b.rb" ])

      assert_equal [ "lib/hive/b.rb: uncovered lines 3, 4" ], failures
    end

    def test_never_loaded_source_is_a_failure_even_if_tests_passed
      report = { "files" => [] }

      failures = HiveChangedCoverage.enforce(report, sources: [ "lib/hive/never_required.rb" ])

      assert_equal [ "lib/hive/never_required.rb: never loaded by the focused run" ], failures
    end
  end
end
