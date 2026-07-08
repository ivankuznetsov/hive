require "test_helper"
require "open3"
require "hive/commands/run"
require "hive/stages/resolver"
require "hive/workflow"
require "hive/workflows/coding"

class StagesResolverTest < Minitest::Test
  TaskStub = Struct.new(:stage_name, :workflow, keyword_init: true)

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

  def task(stage_name, workflow: Hive::Workflows::Registry.default)
    TaskStub.new(stage_name: stage_name, workflow: workflow)
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

  def test_run_pick_runner_uses_task_workflow_for_agent_stage
    command = Hive::Commands::Run.new("demo")

    runner = command.send(:pick_runner, task("gather", workflow: research_workflow))

    assert_equal Hive::Stages::Agent.method(:run!), runner
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

  def test_non_coding_council_stage_resolves_to_council_runner
    descriptor = Hive::Workflow.new(
      id: :synthetic,
      stages: [
        Hive::Workflow::Stage.new(
          name: "review",
          index: 1,
          state_file: "review.md",
          kind: :council,
          reviewers: [ Hive::Workflow::Reviewer.new(name: "one", prompt: "Review.") ],
          council: Hive::Workflow::Council.new(quorum: 1)
        )
      ]
    )

    runner = Hive::Stages::Resolver.resolve(task("review", workflow: descriptor), descriptor: descriptor)

    assert_equal Hive::Stages::Council.method(:run!), runner
  end

  def test_non_coding_stage_name_collision_resolves_by_descriptor_kind
    descriptor = Hive::Workflow.new(
      id: :synthetic,
      stages: [
        Hive::Workflow::Stage.new(
          name: "plan",
          index: 1,
          state_file: "plan.md",
          kind: :agent
        )
      ]
    )

    runner = Hive::Stages::Resolver.resolve(task("plan", workflow: descriptor), descriptor: descriptor)

    assert_equal Hive::Stages::Agent.method(:run!), runner
  end

  def test_present_non_agent_stage_raises_stage_error
    descriptor = Hive::Workflow.new(
      id: :synthetic,
      stages: [
        Hive::Workflow::Stage.new(
          name: "research",
          index: 1,
          state_file: "research.md"
        )
      ]
    )

    error = assert_raises(Hive::StageError) do
      Hive::Stages::Resolver.resolve(task("research"), descriptor: descriptor)
    end

    assert_equal "no runner for stage research", error.message
  end

  def test_unknown_stage_raises_same_stage_error_message
    error = assert_raises(Hive::StageError) do
      Hive::Stages::Resolver.resolve(task("mystery"), descriptor: empty_descriptor)
    end

    assert_equal "no runner for stage mystery", error.message
  end

  def test_coding_runner_keys_are_a_subset_of_descriptor_stage_names
    descriptor_names = Hive::Workflows::Coding::DESCRIPTOR.stages.map(&:name)
    drifted = Hive::Stages::Resolver::CODING_RUNNERS.keys - descriptor_names

    assert_empty drifted,
                 "every CODING_RUNNERS key must name a stage in Coding::DESCRIPTOR; drifted: #{drifted.inspect}"
  end

  def test_resolving_one_bespoke_stage_does_not_eager_load_other_runners
    # Must run in a clean subprocess: under the gated suite execute.rb is already
    # in $LOADED_FEATURES (the coverage gate's load_all_sources! and the integration
    # prompt_injection_test both require it), so an in-process $LOADED_FEATURES delta
    # can never witness an eager-load regression and the guard would pass vacuously.
    # A fresh interpreter resolves `inbox` and reports which sibling runner constants
    # came into existence: a resolver that eagerly required every runner at load time
    # would define Execute and fail this assertion.
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "hive/stages/resolver"
      task = Struct.new(:stage_name).new("inbox")
      Hive::Stages::Resolver.resolve(task)
      inbox = Hive::Stages.const_defined?(:Inbox, false)
      execute = Hive::Stages.const_defined?(:Execute, false)
      print "inbox=\#{inbox} execute=\#{execute}"
    RUBY

    out, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)

    assert status.success?, "resolver subprocess exited non-zero: #{out}"
    assert_equal "inbox=true execute=false", out,
                 "resolving inbox must load its own runner but never eager-load the execute runner"
  end

  def test_every_coding_descriptor_stage_resolves_to_a_runner
    # Round-trip companion to the subset guard above: every stage declared in
    # Coding::DESCRIPTOR must resolve to a callable runner. A bespoke-less coding
    # stage would otherwise raise at dispatch instead of failing here.
    Hive::Workflows::Coding::DESCRIPTOR.stages.each do |stage|
      runner = Hive::Stages::Resolver.resolve(task(stage.name))
      assert_respond_to runner, :call,
                        "coding stage #{stage.name} must resolve to a callable runner"
    end
  end

  private

  # A minimal valid descriptor whose single stage does NOT match the queried
  # "mystery" stage, so Resolver.resolve still raises "no runner for stage
  # mystery". (Hive::Workflow now rejects an empty stage list at construction,
  # so this can no longer be literally empty.)
  def empty_descriptor
    Hive::Workflow.new(
      id: :empty,
      stages: [
        Hive::Workflow::Stage.new(name: "intake", index: 1, state_file: "intake.md", kind: :inert)
      ]
    )
  end
end
