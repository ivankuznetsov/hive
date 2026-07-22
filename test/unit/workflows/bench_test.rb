require "test_helper"
require "json"
require "open3"
require "hive/workflow_selection"
require "hive/workflows/bench"
require "hive/workflows/registry"

class WorkflowsBenchTest < Minitest::Test
  include HiveTestHelper

  def descriptor
    Hive::Workflows::Registry.fetch(:bench)
  end

  def stages_by_name
    descriptor.stages.to_h { |stage| [ stage.name, stage ] }
  end

  def test_registry_exposes_bench_as_a_builtin_workflow
    assert_same Hive::Workflows::Bench::DESCRIPTOR, descriptor
    assert_includes Hive::Workflows::Registry.ids, :bench
    assert_includes Hive::WorkflowSelection.valid_names, "bench"
  end

  def test_descriptor_matches_the_native_benchmark_pipeline
    assert_equal :bench, descriptor.id
    assert_equal %w[inbox extract generate judge publish done], descriptor.stage_names
    assert_equal %w[1-inbox 2-extract 3-generate 4-judge 5-publish 6-done], descriptor.stage_dirs
    assert_equal [ :inert, :agent, :agent, :agent, :agent, :inert ],
                 descriptor.stages.map(&:kind)
    assert_equal [ "task.md", "extract.md", "generate.md", "judge.md", "publish.md", "task.md" ],
                 descriptor.stages.map(&:state_file)
  end

  def test_agent_stages_use_packaged_benchmark_instructions
    %w[extract generate judge publish].each do |name|
      stage = stages_by_name.fetch(name)

      assert_equal File.join(Hive::Workflows::Bench::INSTRUCTIONS_DIR, "#{name}.md"), stage.instruction
      assert_path_exists stage.instruction
      instruction = File.read(stage.instruction)
      assert_includes instruction, "<!-- bench-stage-script -->"
      assert_includes instruction, ".hive-state/bench-runtime"
      refute_includes instruction, "\$REPO_ROOT/harness/"
      assert_equal :state_file_marker, stage.status_mode
    end
  end

  def test_agent_stages_use_codex_control_plane_with_campaign_sized_timeouts
    expected_timeouts = {
      "extract" => 3600,
      "generate" => 604_800,
      "judge" => 604_800,
      "publish" => 3600
    }

    expected_timeouts.each do |name, timeout_sec|
      stage = stages_by_name.fetch(name)

      assert_equal "codex", stage.agent
      assert_nil stage.effort
      assert_equal timeout_sec, stage.timeout_sec
    end
  end

  def test_packaged_runtime_contains_campaign_driver_and_runner_image
    runtime = Hive::Workflows::Bench::RUNTIME_DIR

    assert_path_exists File.join(runtime, "harness", "hive_run.rb")
    assert_path_exists File.join(runtime, "campaign.yml.example")
    assert_path_exists File.join(runtime, "Dockerfile.runner")
  end

  def test_failed_rollback_warns_without_masking_the_original_install_error
    ops = Object.new
    ops.define_singleton_method(:hive_state_path) { "/unused/hive-state" }
    ops.define_singleton_method(:run_git!) { |*| raise "index reset failed" }

    _out, err = capture_io do
      Hive::Workflows::Bench.rollback_failed_install!(
        ops,
        destination: "/unused/bench-runtime",
        backup: "/unused/bench-runtime.previous",
        migration_pathspecs: [],
        pathspecs: [ "bench-runtime" ],
        runtime_backed_up: false,
        runtime_installed: false
      )
    end

    assert_includes err, "failed to fully roll back bench runtime installation"
    assert_includes err, "RuntimeError: index reset failed"
  end

  def test_failed_runtime_removal_retains_backup_instead_of_nesting_it
    Dir.mktmpdir("hive-bench-rollback") do |hive_state|
      destination = File.join(hive_state, "bench-runtime")
      backup = File.join(hive_state, "bench-runtime.previous")
      FileUtils.mkdir_p(destination)
      FileUtils.mkdir_p(backup)
      File.write(File.join(destination, "new.txt"), "new runtime\n")
      File.write(File.join(backup, "old.txt"), "old runtime\n")
      events = []
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }
      ops.define_singleton_method(:run_git!) { |*| events << :reset }
      original_rm_r = FileUtils.method(:rm_r)
      failing_rm_r = lambda do |path, *args, **kwargs|
        events << :remove
        raise Errno::EACCES, path if path == destination

        original_rm_r.call(path, *args, **kwargs)
      end

      _out, err = capture_io do
        with_replaced_singleton_method(FileUtils, :rm_r, failing_rm_r) do
          Hive::Workflows::Bench.rollback_failed_install!(
            ops,
            destination: destination,
            backup: backup,
            migration_pathspecs: [],
            pathspecs: [ "bench-runtime" ],
            runtime_backed_up: true,
            runtime_installed: true
          )
        end
      end

      assert_equal :reset, events.first
      assert_equal "new runtime\n", File.read(File.join(destination, "new.txt"))
      assert_equal "old runtime\n", File.read(File.join(backup, "old.txt"))
      refute_path_exists File.join(destination, File.basename(backup))
      assert_includes err, "previous bench runtime retained at #{backup}"
      assert_includes err, "Errno::EACCES"
    end
  end

  def test_nonlegacy_descriptor_is_left_in_place_and_releases_directory_pin
    Dir.mktmpdir("hive-bench-custom") do |hive_state|
      workflows = File.join(hive_state, "workflows")
      FileUtils.mkdir_p(File.join(workflows, "bench"))
      descriptor = File.join(workflows, "bench.yml")
      File.write(descriptor, <<~YAML)
        id: bench
        stages:
          - name: inbox
            kind: terminal
            state_file: task.md
      YAML
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }

      migration = Hive::Workflows::Bench.archive_legacy_project_workflow!(ops)

      assert_empty migration.fetch(:pathspecs)
      assert_nil migration.fetch(:handle)
      assert_path_exists descriptor
    end
  end

  def test_failed_rollback_reports_a_missing_previous_runtime_backup
    Dir.mktmpdir("hive-bench-missing-backup") do |hive_state|
      destination = File.join(hive_state, "bench-runtime")
      backup = File.join(hive_state, "bench-runtime.previous")
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }
      ops.define_singleton_method(:run_git!) { |*| "" }

      _out, err = capture_io do
        Hive::Workflows::Bench.rollback_failed_install!(
          ops,
          destination: destination,
          backup: backup,
          migration_pathspecs: [],
          pathspecs: [ "bench-runtime" ],
          runtime_backed_up: true,
          runtime_installed: false
        )
      end

      assert_includes err, "previous bench runtime backup is missing at #{backup}"
    end
  end

  def test_directory_pin_rejects_a_different_opened_inode_and_closes_on_error
    Dir.mktmpdir("hive-bench-pin") do |hive_state|
      workflows = File.join(hive_state, "workflows")
      FileUtils.mkdir_p(workflows)
      Dir.mktmpdir("hive-bench-other") do |other|
        replacement = ->(_handle) { other }

        error = with_replaced_singleton_method(
          Hive::Workflows::Bench, :pinned_directory_path, replacement
        ) do
          assert_raises(Hive::ConfigError) do
            Hive::Workflows::Bench.pin_workflows_directory!(hive_state, workflows)
          end
        end

        assert_includes error.message, "workflows directory changed"
      end
    end
  end

  def test_close_directory_handle_tolerates_an_already_closed_handle
    handle = Object.new
    handle.define_singleton_method(:close) { raise IOError, "closed directory" }

    assert_nil Hive::Workflows::Bench.close_directory_handle(handle)
  end

  def test_pinned_directory_path_fails_closed_without_a_supported_fd_path
    handle = Object.new
    handle.define_singleton_method(:fileno) { 99_999 }
    original_directory = File.method(:directory?)
    unavailable = lambda do |path|
      if path == "/proc/self/fd/99999" || path == "/dev/fd/99999"
        false
      else
        original_directory.call(path)
      end
    end

    error = with_replaced_singleton_method(File, :directory?, unavailable) do
      assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.pinned_directory_path(handle)
      end
    end

    assert_includes error.message, "cannot safely pin"
  end

  def test_parent_validation_rejects_a_reappeared_descriptor_and_missing_parent
    Dir.mktmpdir("hive-bench-parent") do |hive_state|
      workflows = File.join(hive_state, "workflows")
      FileUtils.mkdir_p(workflows)
      handle = Dir.open(workflows)
      stat = File.stat(workflows)
      migration = {
        handle: handle,
        root: Hive::Workflows::Bench.pinned_directory_path(handle),
        dev: stat.dev,
        ino: stat.ino
      }
      ops = Object.new
      ops.define_singleton_method(:hive_state_path) { hive_state }

      File.write(File.join(workflows, "bench.yml"), "custom\n")
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_parent!(ops, migration)
      end
      assert_includes error.message, "descriptor path reappeared before commit"

      FileUtils.mv(workflows, "#{workflows}.moved")
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_parent!(ops, migration)
      end
      assert_includes error.message, "cannot validate legacy bench workflows directory"
    ensure
      Hive::Workflows::Bench.close_directory_handle(handle)
    end
  end

  def test_commit_detection_preserves_files_when_head_cannot_be_read
    ops = Object.new
    ops.define_singleton_method(:hive_state_path) { "/unused/hive-state" }
    ops.define_singleton_method(:run_git!) { |*| raise Hive::GitError, "head unavailable" }

    _out, err = capture_io do
      assert Hive::Workflows::Bench.commit_landed?(ops, "before")
    end

    assert_includes err, "could not determine whether bench migration committed"
    assert_includes err, "head unavailable"
  end

  def test_descriptor_snapshot_errors_are_normalized_as_config_errors
    missing = File.join(Dir.tmpdir, "missing-bench-descriptor-#{Process.pid}")
    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::Bench.read_descriptor_snapshot!(missing)
    end
    assert_includes error.message, "cannot read legacy bench descriptor safely"

    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::Bench.parse_descriptor_snapshot!({ content: "[" }, missing)
    end
    assert_includes error.message, "is not valid YAML"
  end

  def test_instruction_archive_cleanup_runs_after_an_unexpected_publish_error
    Dir.mktmpdir("hive-bench-publish") do |root|
      source = File.join(root, "staged")
      destination = File.join(root, "archive")
      FileUtils.mkdir_p(source)
      original_rename = File.method(:rename)
      failing_rename = lambda do |from, to|
        result = original_rename.call(from, to)
        raise "publish interrupted after rename" if from == source && to == destination

        result
      end

      error = with_replaced_singleton_method(File, :rename, failing_rename) do
        assert_raises(RuntimeError) do
          Hive::Workflows::Bench.publish_instruction_archive!(source, destination)
        end
      end

      assert_includes error.message, "publish interrupted after rename"
      refute_path_exists destination
    end
  end

  def test_migration_path_validation_rejects_wrong_type_escape_and_missing_path
    Dir.mktmpdir("hive-bench-paths") do |hive_state|
      directory = File.join(hive_state, "directory")
      FileUtils.mkdir_p(directory)
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_path!(hive_state, directory, expected: :file)
      end
      assert_includes error.message, "expected file"

      Dir.mktmpdir("hive-bench-external") do |external|
        outside = File.join(external, "bench.yml")
        File.write(outside, "external\n")
        error = assert_raises(Hive::ConfigError) do
          Hive::Workflows::Bench.validate_migration_path!(hive_state, outside, expected: :file)
        end
        assert_includes error.message, "outside hive state"
      end

      missing = File.join(hive_state, "missing.yml")
      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::Bench.validate_migration_path!(hive_state, missing, expected: :file)
      end
      assert_includes error.message, "cannot validate legacy bench migration path"
    end
  end

  def test_generate_selects_the_sol_runner_for_stage_specific_5_6_models
    instruction = File.read(stages_by_name.fetch("generate").instruction)

    assert_includes instruction, "profile.codex_models"
    assert_includes instruction, 'start_with?("gpt-5.6-")'
    assert_includes instruction, "HB_RUNNER_IMAGE=hive-bench-runner:sol"
  end

  def test_generate_surfaces_provider_only_pending_cells_as_daemon_retryable_limits
    instruction = File.read(stages_by_name.fetch("generate").instruction)

    assert_includes instruction, "write_limits_reached()"
    assert_includes instruction, "exit(quota_only ? 75 : 2)"
    assert_includes instruction, 'if [ "$outcome_status" -eq 75 ]'
    assert_includes instruction, "<!-- ERROR reason=limits_reached"
    assert_includes instruction, 'retry_after="%s"'
  end

  def test_judge_validation_rejects_a_missing_round_two_verdict
    instruction = File.read(stages_by_name.fetch("judge").instruction)
    skip_filter = instruction.match(
      /ruby -ryaml -rjson -e '\n(?<code>.*?)\n' "\$REPO_ROOT\/\$DELIB" "\$DELIB_SKIP"/m
    )
    refute_nil skip_filter, "judge instruction must classify retryable deliberations"
    validator_start = instruction.rindex("ruby -ryaml -rjson -e '\n")
    refute_nil validator_start, "judge instruction must expose its final artifact validator"
    validator = instruction[validator_start..].match(
      /ruby -ryaml -rjson -e '\n(?<code>.*?)\n' "\$REPO_ROOT\/\$RESULTS" "\$REPO_ROOT\/\$DELIB"/m
    )
    refute_nil validator, "judge instruction must expose its final artifact validator"

    Dir.mktmpdir("hive-bench-judge-validator") do |root|
      campaign = {
        "campaign_id" => "validator-test",
        "source" => "unused",
        "seeds" => 1,
        "tasks" => [ "task-one" ],
        "candidates" => [ "candidate-one" ],
        "exclusions" => [],
        "judges" => {
          "claude" => { "model" => "claude-fable-5" },
          "codex" => { "model" => "gpt-5.6-sol", "reasoning_effort" => "ultra" }
        }
      }
      results = {
        "cells" => [ {
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "run_status" => "generated",
          "judges" => {
            "fable-5" => { "sample_count" => 1, "reasoning_effort" => "unspecified" },
            "gpt-5.6-sol" => { "sample_count" => 1, "reasoning_effort" => "ultra" }
          }
        } ]
      }
      verdict = lambda do |effort|
        {
          "initial" => 7.0,
          "initial_reason" => "initial reason",
          "final" => 7.0,
          "final_reason" => "final reason",
          "discussion" => "checked the other referee's claims",
          "reasoning_effort" => effort
        }
      end
      deliberation = {
        "cells" => [ {
          "task_id" => "task-one",
          "agent_id" => "candidate-one",
          "judges" => {
            "fable-5" => verdict.call("unspecified"),
            "gpt-5.6-sol" => verdict.call("ultra")
          }
        } ]
      }
      campaign_path = File.join(root, "campaign.yml")
      results_path = File.join(root, "results.json")
      deliberation_path = File.join(root, "deliberation.json")
      File.write(campaign_path, campaign.to_yaml)
      File.write(results_path, JSON.generate(results))
      File.write(deliberation_path, JSON.generate(deliberation))

      skip_path = File.join(root, "skip.json")
      _out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", skip_filter[:code], deliberation_path, skip_path,
        chdir: root
      )
      assert status.success?, err
      assert_equal 1, JSON.parse(File.read(skip_path)).fetch("cells").size
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", validator[:code], results_path, deliberation_path,
        chdir: root
      )
      assert status.success?, "complete deliberation should validate: #{out}#{err}"

      deliberation.dig("cells", 0, "judges", "gpt-5.6-sol")["final"] = nil
      File.write(deliberation_path, JSON.generate(deliberation))
      _out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", skip_filter[:code], deliberation_path, skip_path,
        chdir: root
      )
      assert status.success?, err
      assert_empty JSON.parse(File.read(skip_path)).fetch("cells"),
                   "the incomplete cell must remain eligible for a deliberation retry"

      out, err, status = Open3.capture3(
        RbConfig.ruby, "-ryaml", "-rjson", "-e", validator[:code], results_path, deliberation_path,
        chdir: root
      )

      refute status.success?, "a null final verdict must keep the judge stage incomplete"
      assert_empty err
      assert_includes out, "INCOMPLETE_DELIBERATION candidate-one task-one gpt-5.6-sol"
      assert_includes out, "final"
    end
  end

  def test_descriptor_carries_transition_verbs_after_inbox
    assert_equal [ nil, "extract", "generate", "judge", "publish", nil ],
                 descriptor.stages.map { |stage| stage.advance_verb&.name }
  end
end
