require "test_helper"
require_relative "../support/coverage"
require_relative "../support/coverage_config_sandbox"

class HiveTestCoverageTest < Minitest::Test
  include HiveTestHelper
  include HiveCoverageConfigSandbox::TestHelpers

  # A test that repoints the coverage root and never restores it sends this
  # process's own at_exit dump into a scratch directory, so every line the
  # shard ran afterwards goes unmeasured while the shard still exits zero.
  # The shard is green and the merged gate is thousands of lines short.
  def test_coverage_config_sandbox_restores_every_state_ivar
    original = HiveCoverageConfigSandbox.capture

    with_tmp_dir do |dir|
      with_coverage_config(root: dir) do
        assert_equal File.join(dir, "lib"), HiveTestCoverage.instance_variable_get(:@lib_dir)
      end
    end

    assert_equal original, HiveCoverageConfigSandbox.capture
  end

  def test_coverage_config_sandbox_restores_after_a_mid_test_repoint
    original = HiveCoverageConfigSandbox.capture

    with_tmp_dir do |first|
      with_tmp_dir do |second|
        configure_coverage_root!(first)
        configure_coverage_root!(second)
      end
    end
    restore_coverage_config!

    assert_equal original, HiveCoverageConfigSandbox.capture
  end

  # Lint, not style: `configure!` mutates module state that the running
  # process's own coverage dump reads, and forgetting to put it back fails
  # silently. Any test that calls it must also restore it - through
  # HiveCoverageConfigSandbox::TestHelpers, or its own snapshot/restore pair.
  def test_every_test_that_repoints_coverage_config_also_restores_it
    repo_root = File.expand_path("../..", __dir__)
    restorers = [ "HiveCoverageConfigSandbox", "remove_instance_variable" ]

    offenders = Dir.glob(File.join(repo_root, "test/**/*_test.rb")).sort.select do |path|
      # This file names the call in its own assertion message.
      next false if path == File.expand_path(__FILE__)

      source = File.read(path)
      source.include?("HiveTestCoverage.configure!") &&
        restorers.none? { |marker| source.include?(marker) }
    end

    assert_empty offenders.map { |path| path.delete_prefix("#{repo_root}/") },
                 "these tests repoint HiveTestCoverage without restoring it; include " \
                 "HiveCoverageConfigSandbox::TestHelpers and use " \
                 "with_coverage_config / configure_coverage_root! instead"
  end

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

  def test_focused_report_keeps_unloaded_selected_sources_without_scanning_unrelated_files
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      selected = File.join(dir, "lib", "selected.rb")
      unrelated = File.join(dir, "lib", "unrelated.rb")
      File.write(selected, "SELECTED = 1\n")
      File.write(unrelated, "UNRELATED = 2\n")

      with_coverage_config(root: dir) do
        report = HiveTestCoverage.build_report({}, sources: [ "lib/selected.rb" ])
        assert_equal [ "lib/selected.rb" ], report.fetch(:files).map { |file| file.fetch(:file) }
        assert_equal [ "lib/selected.rb" ], report.fetch(:unloaded_files)
        refute report.fetch(:ok)
        assert_equal 2, HiveTestCoverage.build_report({}).fetch(:files).length,
                     "a focused report must not change the global CI source catalog"
      end
    end
  end

  def test_focused_report_refuses_missing_or_outside_sources
    with_tmp_dir do |dir|
      with_coverage_config(root: dir) do
        [ "lib/missing.rb", "../outside.rb" ].each do |source|
          assert_raises(ArgumentError) { HiveTestCoverage.build_report({}, sources: [ source ]) }
        end
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

  # Regression: a pre-`exit!` sparse flush used to call Coverage.result with
  # its default stop: true, ending measurement for the rest of that process.
  # A fork parent (or a stubbed `exit!` that never reaches Kernel#exit!) keeps
  # running tests afterwards, so every line it executed later vanished — and
  # the "not enabled" rescue swallowed the second dump, so the shard still
  # reported green while thousands of lines silently went uncovered.
  def test_sparse_flush_keeps_measuring_lines_executed_afterwards
    with_tmp_dir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      File.write(File.join(lib, "before_flush.rb"), "module BeforeFlushProbe; VALUE = 1; end\n")
      File.write(File.join(lib, "after_flush.rb"), "module AfterFlushProbe; VALUE = 2; end\n")
      support = File.expand_path("../support/coverage.rb", __dir__)
      script = File.join(dir, "probe.rb")
      File.write(script, <<~PROBE)
        require #{support.dump}
        HiveTestCoverage.start!(root: #{dir.dump})
        $LOAD_PATH.unshift(#{lib.dump})
        require "before_flush"
        HiveTestCoverage.dump_process_result!(sparse: true)
        require "after_flush"
        HiveTestCoverage.dump_process_result!
        keys = Dir.glob(File.join(#{dir.dump}, "coverage", ".resultset", "**", "*.marshal"))
          .flat_map { |file| Marshal.load(File.binread(file)).keys }
        probes = keys.select { |key| key.end_with?("_flush.rb") }
        puts probes.map { |key| File.basename(key) }.uniq.sort.join(",")
      PROBE

      output = IO.popen(
        { "HIVE_COVERAGE_RUN_ID" => "flush-probe" },
        [ RbConfig.ruby, script ],
        err: File::NULL,
        &:read
      )

      assert_predicate $?, :success?, "coverage probe subprocess failed"
      assert_equal "after_flush.rb,before_flush.rb", output.strip,
        "code executed after a sparse flush must still be measured"
    end
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
          report = HiveTestCoverage.build_report(merged)

          assert_equal 2, paths.length
          assert_equal [ 1, 1 ], merged.fetch(source).fetch(:lines)
          assert_equal 2, report.fetch(:process_results)
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
end
