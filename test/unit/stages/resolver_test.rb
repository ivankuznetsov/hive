require "test_helper"
require "hive/commands/run"
require "hive/stages/resolver"
require "hive/workflow"

class StagesResolverTest < Minitest::Test
  TaskStub = Struct.new(:stage_name, keyword_init: true)

  CODING_EXPECTATIONS = {
    "inbox" => [ "hive/stages/inbox", Hive::Stages, :Inbox ],
    "brainstorm" => [ "hive/stages/brainstorm", Hive::Stages, :Brainstorm ],
    "plan" => [ "hive/stages/plan", Hive::Stages, :Plan ],
    "execute" => [ "hive/stages/execute", Hive::Stages, :Execute ],
    "open-pr" => [ "hive/stages/open_pr", Hive::Stages, :OpenPr ],
    "review" => [ "hive/stages/review", Hive::Stages, :Review ],
    "artifacts" => [ "hive/stages/artifacts", Hive::Stages, :Artifacts ],
    "finalize" => [ "hive/stages/finalize", Hive::Stages, :Finalize ],
    "done" => [ "hive/stages/done", Hive::Stages, :Done ]
  }.freeze

  def task(stage_name)
    TaskStub.new(stage_name: stage_name)
  end

  def expected_runner(require_path, namespace, const_name)
    require require_path
    namespace.const_get(const_name).method(:run!)
  end

  def test_coding_stage_names_resolve_to_bespoke_runners
    CODING_EXPECTATIONS.each do |stage_name, (require_path, namespace, const_name)|
      assert_equal expected_runner(require_path, namespace, const_name),
                   Hive::Stages::Resolver.resolve(task(stage_name))
    end
  end

  def test_run_pick_runner_delegates_to_same_coding_runners
    command = Hive::Commands::Run.new("demo")

    CODING_EXPECTATIONS.each do |stage_name, (require_path, namespace, const_name)|
      assert_equal expected_runner(require_path, namespace, const_name),
                   command.send(:pick_runner, task(stage_name))
    end
  end

  def test_non_coding_agent_stage_resolves_to_generic_agent_runner
    descriptor = Hive::Workflow.new(
      id: :synthetic,
      stages: [
        Hive::Workflow::Stage.new(
          name: "research",
          index: 1,
          state_file: "research.md",
          kind: :agent
        )
      ]
    )

    runner = Hive::Stages::Resolver.resolve(task("research"), descriptor: descriptor)

    assert_equal Hive::Stages::Agent.method(:run!), runner
  end

  def test_unknown_stage_raises_same_stage_error_message
    error = assert_raises(Hive::StageError) do
      Hive::Stages::Resolver.resolve(task("mystery"), descriptor: empty_descriptor)
    end

    assert_equal "no runner for stage mystery", error.message
  end

  def test_resolving_one_bespoke_stage_does_not_load_other_bespoke_files
    before = $LOADED_FEATURES.dup

    Hive::Stages::Resolver.resolve(task("inbox"))

    newly_loaded = $LOADED_FEATURES - before
    refute newly_loaded.any? { |feature| feature.end_with?("/hive/stages/execute.rb") },
           "resolving inbox should not require execute runner"
  end

  private

  def empty_descriptor
    Hive::Workflow.new(id: :empty, stages: [])
  end
end
