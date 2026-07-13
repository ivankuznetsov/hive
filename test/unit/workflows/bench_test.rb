require "test_helper"
require "hive/workflow_selection"
require "hive/workflows/bench"
require "hive/workflows/registry"

class WorkflowsBenchTest < Minitest::Test
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

  def test_agent_stages_use_low_cost_codex_control_plane_with_campaign_sized_timeouts
    expected_timeouts = {
      "extract" => 3600,
      "generate" => 604_800,
      "judge" => 604_800,
      "publish" => 3600
    }

    expected_timeouts.each do |name, timeout_sec|
      stage = stages_by_name.fetch(name)

      assert_equal "codex", stage.agent
      assert_equal "low", stage.effort
      assert_equal timeout_sec, stage.timeout_sec
    end
  end

  def test_packaged_runtime_contains_campaign_driver_and_runner_image
    runtime = Hive::Workflows::Bench::RUNTIME_DIR

    assert_path_exists File.join(runtime, "harness", "hive_run.rb")
    assert_path_exists File.join(runtime, "campaign.yml.example")
    assert_path_exists File.join(runtime, "Dockerfile.runner")
  end

  def test_generate_selects_the_sol_runner_for_stage_specific_5_6_models
    instruction = File.read(stages_by_name.fetch("generate").instruction)

    assert_includes instruction, 'profile.codex_models'
    assert_includes instruction, 'start_with?("gpt-5.6-")'
    assert_includes instruction, 'HB_RUNNER_IMAGE=hive-bench-runner:sol'
  end

  def test_descriptor_carries_transition_verbs_after_inbox
    assert_equal [ nil, "extract", "generate", "judge", "publish", nil ],
                 descriptor.stages.map { |stage| stage.advance_verb&.name }
  end
end
