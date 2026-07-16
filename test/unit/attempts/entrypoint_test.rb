require "test_helper"
require "hive/attempts/entrypoint"

class AttemptsEntrypointTest < Minitest::Test
  FakeTask = Struct.new(:slug, :project_root, :project_name, keyword_init: true)

  def test_dispatch_attaches_to_resolved_attempt
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    attempt = Struct.new(:attempt_id).new("attempt-1")
    result = Hive::Attempts::DispatchResult.new(
      status: :accepted, attempt: attempt, receipt: nil,
      attach_descriptor: { "attempt_id" => "attempt-1" }, reason: nil
    )
    dispatcher = Object.new
    calls = []
    dispatcher.define_singleton_method(:dispatch) { |**kwargs| calls << kwargs; result }
    client = Object.new
    client.define_singleton_method(:attach) { |id| [ :attached, id ] }
    config = Hive::Config.merge_defaults({})

    value = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, client: client,
      config_loader: ->(_root) { config }
    ).dispatch(
      task: task, intended_stage: "4-execute", argv: [ "hive", "run", "/tmp/task" ],
      request_id: "request-1"
    )

    assert_equal [ :attached, "attempt-1" ], value
    assert_equal 1, calls.length
    assert_equal "demo", calls.first.fetch(:project)
    assert_equal "4-execute", calls.first.fetch(:intended_stage)
    assert_equal true, calls.first.fetch(:interactive)
  end

  def test_noninteractive_dispatch_returns_attempt_reference_without_attaching
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    attempt = Struct.new(:attempt_id).new("attempt-1")
    result = Hive::Attempts::DispatchResult.new(
      status: :existing_live, attempt: attempt, receipt: nil,
      attach_descriptor: nil, reason: nil
    )
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) { |**_kwargs| result }

    value = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, client: Object.new,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    ).dispatch(task: task, intended_stage: "4-execute", argv: [ "hive", "develop", "task" ],
               interactive: false)

    assert_same result, value
  end

  def test_deferred_admission_is_a_retryable_error
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    result = Hive::Attempts::DispatchResult.new(
      status: :deferred, attempt: nil, receipt: nil,
      attach_descriptor: nil, reason: "capacity"
    )
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) { |**_kwargs| result }
    entrypoint = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      entrypoint.dispatch(task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ])
    end
    assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
  end
end
