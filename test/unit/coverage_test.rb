require "test_helper"
require_relative "../support/coverage"

class HiveTestCoverageTest < Minitest::Test
  include HiveTestHelper

  COVERAGE_STATE_IVARS = %i[
    @root
    @lib_dir
    @coverage_dir
    @resultset_dir
    @result_errors
    @startup_errors
    @verified_marshal_paths
  ].freeze

  def test_unloaded_source_file_counts_executable_lines_as_uncovered
    with_tmp_dir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "demo.rb"), <<~RUBY)
        module DemoCoverageProbe
          VALUE = 1
        end
      RUBY

      with_coverage_config(root: dir) do
        report = HiveTestCoverage.build_report({})
        file = report.fetch(:files).fetch(0)

        assert_equal "lib/demo.rb", file.fetch(:file)
        assert_equal false, file.fetch(:loaded)
        assert_operator file.fetch(:line_total), :>, 0
        assert_equal 0, file.fetch(:line_covered)
        assert_equal 0.0, file.fetch(:line_percent)
        assert_equal file.fetch(:line_total), file.fetch(:uncovered_lines).size
        assert_includes report.fetch(:unloaded_files), "lib/demo.rb"
        refute report.fetch(:ok)
      end
    end
  end

  def test_unreadable_result_files_fail_the_gate
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))

      with_coverage_config(root: dir) do
        resultset_dir = HiveTestCoverage.instance_variable_get(:@resultset_dir)
        FileUtils.mkdir_p(resultset_dir)
        File.write(File.join(resultset_dir, "bad.marshal"), "not marshal")

        result = HiveTestCoverage.merged_results
        report = HiveTestCoverage.build_report(
          result,
          result_errors: HiveTestCoverage.instance_variable_get(:@result_errors)
        )

        refute HiveTestCoverage.coverage_ok?(report)
        assert_equal 1, report.fetch(:result_errors).size
        assert_includes HiveTestCoverage.failure_message(report), "unreadable subprocess coverage results"
      end
    end
  end

  def test_config_mismatch_surfaces_specific_error_not_unloaded_file_avalanche
    # Simulates a subprocess that wrote a valid marshal whose entries
    # point at a *different* source tree than @lib_dir. The harness should
    # fail with a clear configuration error rather than reporting every
    # file as unloaded.
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "lib", "demo.rb"), "module Demo; end\n")

      with_coverage_config(root: dir) do
        resultset_dir = HiveTestCoverage.instance_variable_get(:@resultset_dir)
        FileUtils.mkdir_p(resultset_dir)
        # Marshal contains a path that doesn't live under dir/lib/ at all.
        File.binwrite(
          File.join(resultset_dir, "wrong-tree.marshal"),
          Marshal.dump({ "/elsewhere/some_other_lib/file.rb" => { lines: [ 1, 1 ], branches: {} } })
        )

        HiveTestCoverage.merged_results
        errors = HiveTestCoverage.instance_variable_get(:@result_errors)

        assert_equal 1, errors.size
        assert_equal "ConfigurationError", errors.first.fetch(:error_class)
        assert_includes errors.first.fetch(:message), "no entries matched"
      end
    end
  end

  def test_sparse_process_results_keep_only_files_with_observed_hits
    result = {
      "/zero.rb" => {
        lines: [ nil, 0 ],
        branches: { [ :if, 0, 1, 0, 1, 1 ] => { [ :then, 1, 1, 0, 1, 1 ] => 0 } }
      },
      "/line.rb" => { lines: [ nil, 1 ], branches: {} },
      "/branch.rb" => {
        lines: [ nil, 0 ],
        branches: { [ :if, 0, 1, 0, 1, 1 ] => { [ :then, 1, 1, 0, 1, 1 ] => 1 } }
      }
    }

    sparse = HiveTestCoverage.sparse_process_result(result)

    assert_equal [ "/branch.rb", "/line.rb" ], sparse.keys.sort
    assert_same result.fetch("/line.rb"), sparse.fetch("/line.rb")
    assert_same result.fetch("/branch.rb"), sparse.fetch("/branch.rb")
  end

  def test_reload_preloaded_entrypoint_filters_constant_redefinition_warnings_only
    with_tmp_dir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      path = File.join(lib, "hive.rb")
      File.write(path, <<~RUBY)
        module CoverageReloadProbe
          VALUE = 1
        end
        warn "real reload warning"
      RUBY

      _out, _err = capture_io { load path }
      $LOADED_FEATURES << path
      with_coverage_config(root: dir) do
        _out, err = capture_io { HiveTestCoverage.send(:reload_preloaded_entrypoint!) }

        assert_includes err, "real reload warning"
        refute_includes err, "already initialized constant"
        refute_includes err, "previous definition of VALUE"
      end
    ensure
      $LOADED_FEATURES.delete(path) if path
      Object.send(:remove_const, :CoverageReloadProbe) if Object.const_defined?(:CoverageReloadProbe)
    end
  end

  def test_coverage_gate_accepts_string_keyed_json_report
    report = {
      "line_total" => 3,
      "line_covered" => 3,
      "unloaded_files" => [],
      "result_errors" => []
    }

    assert HiveTestCoverage.coverage_ok?(report)
  end

  def test_collect_only_mode_is_explicit_and_does_not_change_the_percentage_threshold
    with_env("HIVE_COVERAGE_COLLECT_ONLY" => "1") do
      assert HiveTestCoverage.collect_only?
      assert_equal 100.0, HiveTestCoverage.minimum_line_percent
    end

    with_env("HIVE_COVERAGE_COLLECT_ONLY" => nil) do
      refute HiveTestCoverage.collect_only?
    end
  end

  def test_shard_manifest_merge_preserves_identical_result_basenames
    with_tmp_dir do |dir|
      source = File.join(dir, "lib", "demo.rb")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "VALUE = 1\nOTHER = 2\n")

      with_env("HIVE_COVERAGE_RUN_ID" => "merged") do
        with_coverage_config(root: dir) do
          write_shard_bundle(
            root: dir,
            index: 0,
            test_files: [ "test/a_test.rb" ],
            result: { source => { lines: [ 1, 0 ], branches: {} } }
          )
          write_shard_bundle(
            root: dir,
            index: 1,
            test_files: [ "test/b_test.rb" ],
            result: { source => { lines: [ 0, 1 ], branches: {} } }
          )

          paths = HiveTestCoverage.verify_shard_manifests!(
            expected_shards: 2,
            revision: "reviewed-head",
            workflow_run_id: "1234",
            test_files_by_shard: [ [ "test/a_test.rb" ], [ "test/b_test.rb" ] ]
          )
          merged = HiveTestCoverage.merged_results

          assert_equal 2, paths.length
          assert_equal [ 1, 1 ], merged.fetch(source).fetch(:lines)
        end
      end
    end
  end

  def test_shard_manifest_gate_rejects_missing_foreign_empty_and_unlisted_inputs
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))

      with_env("HIVE_COVERAGE_RUN_ID" => "merged") do
        with_coverage_config(root: dir) do
          write_shard_bundle(root: dir, index: 0, test_files: [ "test/a_test.rb" ])
          error = assert_raises(HiveTestCoverage::ShardManifestError) do
            HiveTestCoverage.verify_shard_manifests!(
              expected_shards: 2,
              revision: "reviewed-head",
              workflow_run_id: "1234",
              test_files_by_shard: [ [ "test/a_test.rb" ], [ "test/b_test.rb" ] ]
            )
          end
          assert_includes error.message, "expected 2 coverage shard manifests"

          manifest = shard_manifest_path(dir, 0)
          payload = JSON.parse(File.read(manifest))
          File.write(
            manifest,
            JSON.pretty_generate(payload.merge("revision" => "foreign-head", "shard_count" => 1))
          )
          error = assert_raises(HiveTestCoverage::ShardManifestError) do
            HiveTestCoverage.verify_shard_manifests!(
              expected_shards: 1,
              revision: "reviewed-head",
              workflow_run_id: "1234",
              test_files_by_shard: [ [ "test/a_test.rb" ] ]
            )
          end
          assert_includes error.message, "revision"

          File.write(
            manifest,
            JSON.pretty_generate(payload.merge("shard_count" => 1, "process_results" => []))
          )
          error = assert_raises(HiveTestCoverage::ShardManifestError) do
            HiveTestCoverage.verify_shard_manifests!(
              expected_shards: 1,
              revision: "reviewed-head",
              workflow_run_id: "1234",
              test_files_by_shard: [ [ "test/a_test.rb" ] ]
            )
          end
          assert_includes error.message, "invalid process result names"

          File.write(manifest, JSON.pretty_generate(payload.merge("shard_count" => 1)))
          File.binwrite(File.join(File.dirname(manifest), "unlisted.marshal"), Marshal.dump({}))
          error = assert_raises(HiveTestCoverage::ShardManifestError) do
            HiveTestCoverage.verify_shard_manifests!(
              expected_shards: 1,
              revision: "reviewed-head",
              workflow_run_id: "1234",
              test_files_by_shard: [ [ "test/a_test.rb" ] ]
            )
          end
          assert_includes error.message, "does not match its process results"
        end
      end
    end
  end

  def test_shard_manifest_gate_rejects_duplicate_and_corrupt_manifests
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))

      with_env("HIVE_COVERAGE_RUN_ID" => "merged") do
        with_coverage_config(root: dir) do
          write_shard_bundle(root: dir, index: 0, test_files: [ "test/a_test.rb" ])
          write_shard_bundle(root: dir, index: 1, test_files: [ "test/b_test.rb" ])
          second = shard_manifest_path(dir, 1)
          payload = JSON.parse(File.read(second)).merge(
            "shard_index" => 0,
            "run_id" => "shard-0"
          )
          File.write(second, JSON.pretty_generate(payload))

          error = assert_raises(HiveTestCoverage::ShardManifestError) do
            HiveTestCoverage.verify_shard_manifests!(
              expected_shards: 2,
              revision: "reviewed-head",
              workflow_run_id: "1234",
              test_files_by_shard: [ [ "test/a_test.rb" ], [ "test/b_test.rb" ] ]
            )
          end
          assert_includes error.message, "must be stored under coverage-shard-0"

          File.write(second, "not-json")
          error = assert_raises(HiveTestCoverage::ShardManifestError) do
            HiveTestCoverage.verify_shard_manifests!(
              expected_shards: 2,
              revision: "reviewed-head",
              workflow_run_id: "1234",
              test_files_by_shard: [ [ "test/a_test.rb" ], [ "test/b_test.rb" ] ]
            )
          end
          assert_includes error.message, "unreadable coverage shard manifest"
        end
      end
    end
  end

  def test_collect_only_catalog_load_persists_startup_errors_for_the_merge_process
    with_tmp_dir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "broken.rb"), "raise 'catalog boom'\n")
      $LOAD_PATH.unshift(lib)

      with_env(
        "HIVE_COVERAGE_COLLECT_ONLY" => "1",
        "HIVE_COVERAGE_RUN_ID" => "shard-0"
      ) do
        with_coverage_config(root: dir) do
          _out, err = capture_io { HiveTestCoverage.load_all_sources! }
          markers = Dir.glob(File.join(dir, "coverage", ".resultset", "shard-0", "*.error.json"))
          payload = JSON.parse(File.read(markers.fetch(0)))

          assert_equal 1, markers.length
          assert_equal "lib/broken.rb", payload.fetch("file")
          assert_equal "RuntimeError", payload.fetch("error_class")
          assert_includes payload.fetch("message"), "catalog boom"
          assert_includes err, "failed to require broken"
        end
      end
    ensure
      $LOAD_PATH.delete(lib) if lib
    end
  end

  def test_coverage_gate_keeps_non_percentage_failures_at_full_line_coverage
    report = {
      "line_total" => 3,
      "line_covered" => 3,
      "unloaded_files" => [],
      "result_errors" => []
    }

    refute HiveTestCoverage.coverage_ok?(report.merge("unloaded_files" => [ "lib/demo.rb" ]))
    refute HiveTestCoverage.coverage_ok?(report.merge("result_errors" => [ { "file" => "bad.marshal" } ]))
  end

  def test_coverage_gate_defaults_to_full_line_coverage
    report = {
      "line_total" => 4,
      "line_covered" => 3,
      "line_percent" => 75.0,
      "unloaded_files" => [],
      "result_errors" => []
    }

    refute HiveTestCoverage.coverage_ok?(report)
    assert_includes HiveTestCoverage.failure_message(report), "below minimum 100.00%"
  end

  def test_coverage_gate_rejects_near_full_line_coverage_that_rounds_to_100_percent
    report = {
      "line_total" => 54_790,
      "line_covered" => 54_789,
      "line_percent" => 100.0,
      "unloaded_files" => [],
      "result_errors" => []
    }

    refute HiveTestCoverage.coverage_ok?(report)
    message = HiveTestCoverage.failure_message(report)
    assert_includes message, "100.00% (54789/54790)"
    assert_includes message, "below minimum 100.00%"
  end

  def test_coverage_gate_honors_min_line_threshold_env
    failing_report = {
      "line_total" => 4,
      "line_covered" => 2,
      "line_percent" => 50.0,
      "unloaded_files" => [],
      "result_errors" => []
    }
    passing_report = failing_report.merge(
      "line_covered" => 3,
      "line_percent" => 75.0
    )

    with_env("HIVE_COVERAGE_MIN_LINE" => "75") do
      refute HiveTestCoverage.coverage_ok?(failing_report)
      assert_includes HiveTestCoverage.failure_message(failing_report), "below minimum 75.00%"
      assert HiveTestCoverage.coverage_ok?(passing_report)
    end
  end

  private

  def write_shard_bundle(root:, index:, test_files:, result: {})
    directory = File.join(
      root,
      "coverage",
      ".resultset",
      "merged",
      "coverage-shard-#{index}"
    )
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, "123-8.marshal"), Marshal.dump(result))
    payload = {
      schema: HiveTestCoverage::SHARD_MANIFEST_SCHEMA,
      revision: "reviewed-head",
      workflow_run_id: "1234",
      ruby_version: RUBY_VERSION,
      shard_index: index,
      shard_count: 2,
      run_id: "shard-#{index}",
      test_files: test_files,
      process_results: [ "123-8.marshal" ]
    }
    File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(payload))
  end

  def shard_manifest_path(root, index)
    File.join(
      root,
      "coverage",
      ".resultset",
      "merged",
      "coverage-shard-#{index}",
      "manifest.json"
    )
  end

  def with_coverage_config(root:)
    sentinel = Object.new
    old = COVERAGE_STATE_IVARS.to_h do |ivar|
      value = if HiveTestCoverage.instance_variable_defined?(ivar)
        HiveTestCoverage.instance_variable_get(ivar)
      else
        sentinel
      end
      [ ivar, value ]
    end

    HiveTestCoverage.configure!(root: root)
    yield
  ensure
    old&.each do |ivar, value|
      if value.equal?(sentinel)
        HiveTestCoverage.remove_instance_variable(ivar) if HiveTestCoverage.instance_variable_defined?(ivar)
      else
        HiveTestCoverage.instance_variable_set(ivar, value)
      end
    end
  end
end
