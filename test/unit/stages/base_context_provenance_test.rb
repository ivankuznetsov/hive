require "test_helper"
require "hive/stages/base"
require "hive/claude_launcher"

class StagesBaseContextProvenanceTest < Minitest::Test
  include HiveTestHelper

  TaskStub = Struct.new(
    :id, :slug, :folder, :project_root, :project_name, :stage_index,
    :stage_name, :log_dir, keyword_init: true
  )

  def test_provider_neutral_spawn_decorates_prompt_and_promotes_after_result
    with_tmp_dir do |root|
      task = task_stub(root)
      context = context_stub(task)
      observation = successful_observation
      calls = []
      decorator = lambda do |task:, prompt:, context:|
        calls << [ :decorate, task.slug, context.attempt_id ]
        "#{prompt}\nreceipt appendix"
      end
      promoter = lambda do |task:, context:|
        calls << [ :promote, task.slug, context.attempt_id ]
      end
      fake_agent_new = lambda do |**kwargs|
        calls << [ :launch, kwargs.fetch(:prompt) ]
        Object.new.tap do |agent|
          agent.define_singleton_method(:run!) { { status: :ok } }
        end
      end

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::ContextProvenance, :decorate_prompt, decorator) do
          with_replaced_singleton_method(Hive::ContextProvenance, :promote_agent_receipt, promoter) do
            with_replaced_singleton_method(Hive::AgentRuntime, :prepare!, ->(*) { true }) do
              with_replaced_singleton_method(
                Hive::Stages::Base, :session_observation, ->(**) { observation }
              ) do
                with_replaced_singleton_method(Hive::Agent, :new, fake_agent_new) do
                  result = Hive::Stages::Base.spawn_agent(
                    task, prompt: "stage contract", max_budget_usd: nil,
                    timeout_sec: 30, cli_flags: []
                  )
                  assert_equal :ok, result.fetch(:status)
                end
              end
            end
          end
        end
      end

      assert_equal [
        [ :decorate, task.slug, "attempt-1" ],
        [ :launch, "stage contract\nreceipt appendix" ],
        [ :promote, task.slug, "attempt-1" ]
      ], calls
    end
  end

  def test_claude_spawn_decorates_prompt_and_promotes_after_launcher_returns
    with_tmp_dir do |root|
      task = task_stub(root)
      context = context_stub(task)
      observation = successful_observation
      calls = []
      decorator = lambda do |task:, prompt:, context:|
        calls << [ :decorate, task.slug, context.attempt_id ]
        "#{prompt}\nreceipt appendix"
      end
      promoter = lambda do |task:, context:|
        calls << [ :promote, task.slug, context.attempt_id ]
      end
      launcher = lambda do |**kwargs|
        calls << [ :launch, kwargs.fetch(:prompt) ]
        { status: :ok }
      end

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::ContextProvenance, :decorate_prompt, decorator) do
          with_replaced_singleton_method(Hive::ContextProvenance, :promote_agent_receipt, promoter) do
            with_replaced_singleton_method(
              Hive::Stages::Base, :session_observation, ->(**) { observation }
            ) do
              with_replaced_singleton_method(Hive::ClaudeLauncher, :launch!, launcher) do
                result = Hive::Stages::Base.spawn_claude!(
                  task, {}, prompt: "stage contract", max_budget_usd: nil,
                  timeout_sec: 30, session_name: "test-session"
                )
                assert_equal :ok, result.fetch(:status)
              end
            end
          end
        end
      end

      assert_equal [
        [ :decorate, task.slug, "attempt-1" ],
        [ :launch, "stage contract\nreceipt appendix" ],
        [ :promote, task.slug, "attempt-1" ]
      ], calls
    end
  end

  def test_provider_neutral_spawn_stops_before_provider_when_session_start_is_not_durable
    with_tmp_dir do |root|
      task = task_stub(root)
      context = context_stub(task)
      observation = failed_start_observation
      launched = false
      fake_agent_new = lambda do |**|
        launched = true
        raise "provider must not be constructed"
      end

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::AgentRuntime, :prepare!, ->(*) { true }) do
          with_replaced_singleton_method(Hive::Stages::Base, :session_observation, ->(**) { observation }) do
            with_replaced_singleton_method(Hive::Agent, :new, fake_agent_new) do
              error = assert_raises(Hive::AgentError) do
                Hive::Stages::Base.spawn_agent(
                  task, prompt: "stage contract", max_budget_usd: nil,
                  timeout_sec: 30, cli_flags: []
                )
              end
              assert_includes error.message, "durable agent session start"
            end
          end
        end
      end
      refute launched
    end
  end

  def test_claude_spawn_stops_before_provider_when_session_start_is_not_durable
    with_tmp_dir do |root|
      task = task_stub(root)
      context = context_stub(task)
      observation = failed_start_observation
      launched = false
      launcher = lambda do |**|
        launched = true
        raise "provider must not launch"
      end

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::Stages::Base, :session_observation, ->(**) { observation }) do
          with_replaced_singleton_method(Hive::ClaudeLauncher, :launch!, launcher) do
            error = assert_raises(Hive::AgentError) do
              Hive::Stages::Base.spawn_claude!(
                task, {}, prompt: "stage contract", max_budget_usd: nil,
                timeout_sec: 30, session_name: "test-session"
              )
            end
            assert_includes error.message, "durable agent session start"
          end
        end
      end
      refute launched
    end
  end

  private

  def task_stub(root)
    TaskStub.new(
      id: 7, slug: "task-260812-abcd", folder: root, project_root: root,
      project_name: "demo", stage_index: 4, stage_name: "execute",
      log_dir: File.join(root, "logs")
    )
  end

  def context_stub(task)
    Hive::Attempts::Context.send(
      :new, attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-3", project: task.project_name,
      task_slug: task.slug, intended_stage: "4-execute"
    )
  end

  def failed_start_observation
    Object.new.tap do |observation|
      observation.define_singleton_method(:available?) { true }
      observation.define_singleton_method(:start!) { false }
      observation.define_singleton_method(:session_id) { "session-start-failed" }
    end
  end

  def successful_observation
    Object.new.tap do |observation|
      observation.define_singleton_method(:available?) { true }
      observation.define_singleton_method(:start!) { true }
      observation.define_singleton_method(:finish!) { |*args, **kwargs| [ args, kwargs ] }
      observation.define_singleton_method(:session_id) { "session-success" }
    end
  end
end
