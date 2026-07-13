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
      assert_includes File.read(stage.instruction), "<!-- bench-stage-script -->"
      assert_equal :state_file_marker, stage.status_mode
    end
  end

  def test_descriptor_carries_transition_verbs_after_inbox
    assert_equal [ nil, "extract", "generate", "judge", "publish", nil ],
                 descriptor.stages.map { |stage| stage.advance_verb&.name }
  end
end
