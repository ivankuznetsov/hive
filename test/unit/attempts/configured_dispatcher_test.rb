require "test_helper"
require "hive/attempts/configured_dispatcher"

class AttemptsConfiguredDispatcherTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:slug, :project_root, keyword_init: true)
  FakeRequest = Struct.new(:slug, :project, :argv, keyword_init: true)

  def test_dispatch_request_uses_the_resolved_projects_attempt_timers
    task = FakeTask.new(slug: "task", project_root: "/projects/demo")
    resolver = Struct.new(:task) { def resolve = task }.new(task)
    launcher_options = nil
    dispatcher_options = nil
    downstream = Object.new
    downstream.define_singleton_method(:dispatch_request) do |_request, interactive:, now:|
      [ interactive, now ]
    end
    launcher_class = Class.new
    launcher_class.define_singleton_method(:new) do |**options|
      launcher_options = options
      :launcher
    end
    dispatcher_class = Class.new
    dispatcher_class.define_singleton_method(:new) do |**options|
      dispatcher_options = options
      downstream
    end
    cfg = Hive::Config.merge_defaults(
      "attempt_heartbeat_sec" => 7,
      "attempt_stale_sec" => 41,
      "attempt_launch_timeout_sec" => 13,
      "attempt_first_heartbeat_timeout_sec" => 17
    )
    daemon = Hive::Config::DEFAULTS.fetch("daemon").merge(
      "child_timeout_sec" => 90,
      "child_verb_timeouts" => { "review" => 600 },
      "child_kill_grace_sec" => 8
    )
    adapter = Hive::Attempts::ConfiguredDispatcher.new(
      store: :store,
      config_loader: ->(root) {
        assert_equal task.project_root, root
        cfg
      },
      daemon_config_loader: -> { daemon },
      launcher_class: launcher_class,
      dispatcher_class: dispatcher_class
    )

    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }) do
      assert_equal [ false, Time.at(0) ],
                   adapter.dispatch_request(
                     FakeRequest.new(slug: "task", project: "demo", argv: %w[hive review task]),
                     now: Time.at(0)
                   )
    end

    assert_equal 7, launcher_options.fetch(:heartbeat_sec)
    assert_equal 41, launcher_options.fetch(:stale_sec)
    assert_equal 17, launcher_options.fetch(:first_heartbeat_timeout_sec)
    assert_equal 600, launcher_options.fetch(:timeout_sec)
    assert_equal 8, launcher_options.fetch(:kill_grace_sec)
    assert_equal 13, dispatcher_options.fetch(:launch_timeout_sec)
    assert_equal daemon.fetch("max_concurrent_runs"),
                 dispatcher_options.dig(:limits, :max_global)
    assert_equal :launcher, dispatcher_options.fetch(:launcher)
    assert_same task, dispatcher_options.fetch(:task_resolver).call(nil)
  end

  def test_successor_uses_the_same_per_project_configuration
    task = FakeTask.new(slug: "task", project_root: "/projects/demo")
    downstream = Object.new
    call = nil
    downstream.define_singleton_method(:dispatch_successor) do |**attributes|
      call = attributes
      :accepted
    end
    dispatcher_class = Class.new
    dispatcher_class.define_singleton_method(:new) { |**_options| downstream }
    launcher_class = Class.new
    launcher_class.define_singleton_method(:new) { |**_options| :launcher }
    adapter = Hive::Attempts::ConfiguredDispatcher.new(
      store: :store, config_loader: ->(_root) { Hive::Config.merge_defaults({}) },
      daemon_config_loader: -> { Hive::Config::DEFAULTS.fetch("daemon") },
      launcher_class: launcher_class, dispatcher_class: dispatcher_class
    )

    assert_equal :accepted,
                 adapter.dispatch_successor(
                   task: task, predecessor: :lost, argv: %w[hive develop task]
                 )
    assert_equal task, call.fetch(:task)
    assert_equal :lost, call.fetch(:predecessor)
  end

  def test_fresh_launch_uses_reloaded_timeouts_and_capacity_limits
    task = FakeTask.new(slug: "task", project_root: "/projects/demo")
    daemon_configs = [
      Hive::Config::DEFAULTS.fetch("daemon").merge(
        "max_concurrent_runs" => 1,
        "max_concurrent_per_project" => 1,
        "max_runs_per_day_per_project" => 2,
        "child_timeout_sec" => 10,
        "child_verb_timeouts" => { "develop" => 20 },
        "child_kill_grace_sec" => 3
      ),
      Hive::Config::DEFAULTS.fetch("daemon").merge(
        "max_concurrent_runs" => 4,
        "max_concurrent_per_project" => 3,
        "max_runs_per_day_per_project" => 8,
        "child_timeout_sec" => 30,
        "child_verb_timeouts" => { "develop" => 40 },
        "child_kill_grace_sec" => 6
      )
    ]
    launcher_options = []
    dispatcher_options = []
    launcher_class = Class.new
    launcher_class.define_singleton_method(:new) do |**options|
      launcher_options << options
      :launcher
    end
    downstream = Object.new
    downstream.define_singleton_method(:dispatch_successor) { |**_attributes| :accepted }
    dispatcher_class = Class.new
    dispatcher_class.define_singleton_method(:new) do |**options|
      dispatcher_options << options
      downstream
    end
    adapter = Hive::Attempts::ConfiguredDispatcher.new(
      store: :store, config_loader: ->(_root) { Hive::Config.merge_defaults({}) },
      daemon_config_loader: -> { daemon_configs.shift },
      launcher_class: launcher_class, dispatcher_class: dispatcher_class
    )

    2.times do
      assert_equal :accepted,
                   adapter.dispatch_successor(
                     task: task, predecessor: :lost, argv: %w[hive develop task]
                   )
    end

    assert_equal [ 20, 40 ], launcher_options.map { |options| options.fetch(:timeout_sec) }
    assert_equal [ 3, 6 ], launcher_options.map { |options| options.fetch(:kill_grace_sec) }
    assert_equal [ 1, 4 ], dispatcher_options.map { |options| options.dig(:limits, :max_global) }
    assert_equal [ 1, 3 ], dispatcher_options.map { |options| options.dig(:limits, :max_per_project) }
    assert_equal [ 2, 8 ], dispatcher_options.map { |options| options.dig(:limits, :max_daily) }
  end

  def test_module_hook_uses_the_project_dispatcher_without_a_task_resolver
    call = nil
    downstream = Object.new
    downstream.define_singleton_method(:dispatch_module_hook) do |argv:, **attributes|
      call = attributes.merge(argv: argv)
      :accepted
    end
    launcher_class = Class.new
    launcher_class.define_singleton_method(:new) { |**_options| :launcher }
    dispatcher_class = Class.new
    dispatcher_class.define_singleton_method(:new) { |**_options| downstream }
    adapter = Hive::Attempts::ConfiguredDispatcher.new(
      store: :store, config_loader: ->(_root) { Hive::Config.merge_defaults({}) },
      daemon_config_loader: -> { Hive::Config::DEFAULTS.fetch("daemon") },
      launcher_class: launcher_class, dispatcher_class: dispatcher_class
    )

    assert_equal :accepted,
                 adapter.dispatch_module_hook(
                   project_root: "/projects/demo", argv: %w[hive module-hook],
                   subject: { "kind" => "module_hook" }, request_id: "request-1"
                 )
    assert_equal %w[hive module-hook], call.fetch(:argv)
    assert_equal "request-1", call.fetch(:request_id)
  end
end
