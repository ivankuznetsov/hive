require "test_helper"
require "hive/attempts/entrypoint"
require "hive/attempts/finalization_maintenance"

class AttemptsEntrypointTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:id, :slug, :stage_name, :project_root, :project_name, keyword_init: true)

  def test_operator_dispatch_still_defers_on_non_loss_reasons
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    deferred = Hive::Attempts::DispatchResult.new(
      status: :deferred, attempt: nil, receipt: nil,
      attach_descriptor: nil, reason: "capacity"
    )
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) { |**_kwargs| deferred }
    error = assert_raises(Hive::ConcurrentRunError) do
      Hive::Attempts::Entrypoint.new(
        store: Object.new, dispatcher: dispatcher
      ).dispatch(
        task: task, intended_stage: "4-execute", argv: [ "hive", "run", "/tmp/task" ],
        request_id: "request-1"
      )
    end

    assert_includes error.message, "capacity"
  end

  def test_state_home_falls_back_when_an_injected_store_has_no_root
    entrypoint = Hive::Attempts::Entrypoint.new(store: Object.new)

    assert_equal Hive::Paths.state_home, entrypoint.send(:state_home_for, Object.new)
  end

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
    client.define_singleton_method(:attach) do |id|
      Hive::Attempts::ClientResult.new(
        status: :terminal, exit_status: 0, outcome: "succeeded",
        receipt: {}, attempt_id: id
      )
    end
    value = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, client: client
    ).dispatch(
      task: task, intended_stage: "4-execute", argv: [ "hive", "run", "/tmp/task" ],
      request_id: "request-1"
    )

    assert_equal :terminal, value.status
    assert_equal "attempt-1", value.attempt_id
    assert_equal 1, calls.length
    assert_equal "demo", calls.first.fetch(:project)
    assert_equal "4-execute", calls.first.fetch(:intended_stage)
    assert_equal true, calls.first.fetch(:interactive)
    assert_nil calls.first.fetch(:provider)
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
      store: Object.new, dispatcher: dispatcher, client: Object.new
    ).dispatch(task: task, intended_stage: "4-execute", argv: [ "hive", "develop", "task" ],
               interactive: false)

    assert_same result, value
  end

  def test_foreground_dispatch_never_constructs_or_runs_periodic_maintenance
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    attempt = Struct.new(:attempt_id).new("attempt-1")
    result = Hive::Attempts::DispatchResult.new(
      status: :existing_live, attempt: attempt, receipt: nil,
      attach_descriptor: nil, reason: nil
    )
    dispatched = false
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) do |**_kwargs|
      dispatched = true
      result
    end

    with_replaced_singleton_method(
      Hive::Attempts::FinalizationMaintenance, :runtime,
      ->(**) { flunk "foreground dispatch must not construct periodic maintenance" }
    ) do
      value = Hive::Attempts::Entrypoint.new(
        store: Object.new, dispatcher: dispatcher
      ).dispatch(
        task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ],
        interactive: false, now: Time.utc(2026, 8, 10, 12, 0, 0)
      )

      assert_same result, value
    end

    assert dispatched
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
      store: Object.new, dispatcher: dispatcher
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      entrypoint.dispatch(task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ])
    end
    assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
  end

  def test_initial_no_route_is_admitted_to_markerless_recovery_before_returning
    task = FakeTask.new(
      id: 1, slug: "task", stage_name: "4-execute",
      project_root: "/tmp/project", project_name: "demo"
    )
    decision = Object.new
    result = Hive::Attempts::DispatchResult.new(
      status: :no_route, attempt: nil, receipt: nil,
      attach_descriptor: nil, reason: "no_eligible_provider_route", decision: decision
    )
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) { |**_kwargs| result }
    calls = []
    receipt = Struct.new(:human_summary).new("Retry available later")
    coordinator = Object.new
    coordinator.define_singleton_method(:request_admission_failure) do |**kwargs|
      calls << kwargs
      receipt
    end
    entrypoint = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher,
      recovery_coordinator: coordinator
    )

    assert_same result, entrypoint.dispatch(
      task: task, intended_stage: "4-execute", argv: %w[hive run task],
      request_id: "request-no-route", interactive: false, now: Time.utc(2026, 8, 11)
    )
    assert_equal decision, calls.fetch(0).fetch(:decision)
    assert_equal "request-no-route", calls.fetch(0).fetch(:request).request_id

    error = assert_raises(Hive::ConcurrentRunError) do
      entrypoint.dispatch(
        task: task, intended_stage: "4-execute", argv: %w[hive run task],
        request_id: "request-no-route", interactive: true, now: Time.utc(2026, 8, 11)
      )
    end
    assert_includes error.message, "Retry available later"
  end

  def test_lost_attachment_preserves_output_metadata_for_the_command_boundary
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    attempt = Struct.new(:attempt_id).new("attempt-1")
    dispatch_result = Hive::Attempts::DispatchResult.new(
      status: :accepted, attempt: attempt, receipt: nil,
      attach_descriptor: { "attempt_id" => "attempt-1" }, reason: nil
    )
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) { |**_kwargs| dispatch_result }
    client = Object.new
    client.define_singleton_method(:attach) do |id|
      Hive::Attempts::ClientResult.new(
        status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL,
        outcome: "lost", receipt: nil, attempt_id: id
      )
    end
    entrypoint = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, client: client
    )

    result = entrypoint.dispatch(
      task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ]
    )

    assert_equal :lost, result.status
    assert_equal "attempt-1", result.attempt_id
    assert_equal Hive::ExitCodes::TEMPFAIL, result.exit_status
  end

  def test_dispatch_uses_registered_project_name_for_matching_root
    task = FakeTask.new(slug: "task", project_root: "/tmp/registered", project_name: "fallback")
    result = Hive::Attempts::DispatchResult.new(
      status: :existing_live, attempt: Struct.new(:attempt_id).new("attempt-1"), receipt: nil,
      attach_descriptor: nil, reason: nil
    )
    dispatcher = Object.new
    captured = nil
    dispatcher.define_singleton_method(:dispatch) { |**kwargs| captured = kwargs; result }
    entrypoint = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher
    )
    resolved_paths = []

    with_replaced_singleton_method(
      Hive::Config, :project_for_path,
      lambda { |path|
        resolved_paths << path
        { "name" => "registered", "path" => path }
      }
    ) do
      entrypoint.dispatch(
        task: task, intended_stage: "4-execute", argv: [ "hive", "develop", "task" ],
        interactive: false
      )
    end

    assert_equal "registered", captured.fetch(:project)
    assert_equal [ "/tmp/registered" ], resolved_paths
  end
end
