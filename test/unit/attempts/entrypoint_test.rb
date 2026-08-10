require "test_helper"
require "hive/attempts/entrypoint"

class AttemptsEntrypointTest < Minitest::Test
  include HiveTestHelper

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
    client.define_singleton_method(:attach) do |id|
      Hive::Attempts::ClientResult.new(
        status: :terminal, exit_status: 0, outcome: "succeeded",
        receipt: {}, attempt_id: id
      )
    end
    config = Hive::Config.merge_defaults({})

    value = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, client: client,
      config_loader: ->(_root) { config }
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

  def test_foreground_dispatch_runs_due_maintenance_before_admission
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    attempt = Struct.new(:attempt_id).new("attempt-1")
    result = Hive::Attempts::DispatchResult.new(
      status: :existing_live, attempt: attempt, receipt: nil,
      attach_descriptor: nil, reason: nil
    )
    order = []
    maintenance = Object.new
    maintenance.define_singleton_method(:run_if_due) { |now:| order << [ :maintenance, now ] }
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) do |**_kwargs|
      order << :dispatch
      result
    end

    Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, maintenance: maintenance,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    ).dispatch(
      task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ],
      interactive: false, now: Time.utc(2026, 8, 10, 12, 0, 0)
    )

    assert_equal [ [ :maintenance, Time.utc(2026, 8, 10, 12, 0, 0) ], :dispatch ], order
  end

  def test_foreground_dispatch_continues_when_opportunistic_maintenance_fails
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    result = Hive::Attempts::DispatchResult.new(
      status: :existing_live, attempt: Struct.new(:attempt_id).new("attempt-1"),
      receipt: nil, attach_descriptor: nil, reason: nil
    )
    maintenance = Object.new
    maintenance.define_singleton_method(:run_if_due) do |now:|
      raise Hive::Attempts::StoreError, "maintenance failed at #{now}"
    end
    dispatched = false
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) do |**_kwargs|
      dispatched = true
      result
    end

    value = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, maintenance: maintenance,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    ).dispatch(
      task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ],
      interactive: false, now: Time.utc(2026, 8, 10, 12, 0, 0)
    )

    assert dispatched
    assert_same result, value
  end

  def test_default_store_builds_runtime_maintenance_before_dispatch
    task = FakeTask.new(slug: "task", project_root: "/tmp/project", project_name: "demo")
    result = Hive::Attempts::DispatchResult.new(
      status: :existing_live, attempt: Struct.new(:attempt_id).new("attempt-1"),
      receipt: nil, attach_descriptor: nil, reason: nil
    )
    store = Object.new
    events = []
    maintenance = Object.new
    maintenance.define_singleton_method(:run_if_due) do |now:|
      events << [ :maintenance, now ]
    end
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) do |**_kwargs|
      events << :dispatch
      result
    end
    now = Time.utc(2026, 8, 10, 12, 0, 0)

    with_replaced_singleton_method(Hive::Attempts::Store, :new, -> { store }) do
      with_replaced_singleton_method(
        Hive::Attempts::FinalizationMaintenance, :runtime,
        lambda { |store:|
          events << [ :runtime, store ]
          maintenance
        }
      ) do
        value = Hive::Attempts::Entrypoint.new(
          dispatcher: dispatcher,
          config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
        ).dispatch(
          task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ],
          interactive: false, now: now
        )

        assert_same result, value
      end
    end

    assert_equal [ [ :runtime, store ], [ :maintenance, now ], :dispatch ], events
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
      store: Object.new, dispatcher: dispatcher, client: client,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    )

    result = entrypoint.dispatch(
      task: task, intended_stage: "4-execute", argv: [ "hive", "run", "task" ]
    )

    assert_equal :lost, result.status
    assert_equal "attempt-1", result.attempt_id
    assert_equal Hive::ExitCodes::TEMPFAIL, result.exit_status
  end

  def test_default_dispatcher_uses_attempt_timers_and_daemon_limits
    config = Hive::Config.merge_defaults({})
    daemon = Hive::Config::DEFAULTS.fetch("daemon").merge(
      "child_timeout_sec" => 90,
      "child_verb_timeouts" => { "review" => 720 },
      "child_kill_grace_sec" => 12
    )
    launcher = Object.new
    launcher_options = nil
    captured = nil
    dispatcher = Object.new
    with_replaced_singleton_method(Hive::Attempts::DetachedLauncher, :new, lambda { |**kwargs|
      launcher_options = kwargs
      launcher
    }) do
      with_replaced_singleton_method(Hive::Attempts::Dispatcher, :new, lambda { |**kwargs|
        captured = kwargs
        dispatcher
      }) do
        entrypoint = Hive::Attempts::Entrypoint.new
        assert_same dispatcher,
                    entrypoint.send(
                      :build_dispatcher, Object.new, config, daemon, %w[hive review task]
                    )
      end
    end
    assert_equal config.fetch("attempt_heartbeat_sec"), launcher_options.fetch(:heartbeat_sec)
    assert_equal 720, launcher_options.fetch(:timeout_sec)
    assert_equal 12, launcher_options.fetch(:kill_grace_sec)
    assert_same launcher, captured.fetch(:launcher)
    assert_equal daemon.fetch("max_concurrent_runs"), captured.dig(:limits, :max_global)
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
      store: Object.new, dispatcher: dispatcher,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    )

    with_replaced_singleton_method(
      Hive::Config, :registered_projects,
      -> { [ { "name" => "registered", "path" => "/tmp/registered" } ] }
    ) do
      entrypoint.dispatch(
        task: task, intended_stage: "4-execute", argv: [ "hive", "develop", "task" ],
        interactive: false
      )
    end

    assert_equal "registered", captured.fetch(:project)
  end
end
