require "test_helper"
require "hive/attempts/configured_dispatcher"

class AttemptsConfiguredDispatcherTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:slug, :project_root, keyword_init: true)
  FakeRequest = Struct.new(:slug, :project, keyword_init: true)

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
    adapter = Hive::Attempts::ConfiguredDispatcher.new(
      store: :store,
      limits: { max_global: 2, max_per_project: 1, max_daily: 9 },
      config_loader: ->(root) {
        assert_equal task.project_root, root
        cfg
      },
      launcher_class: launcher_class,
      dispatcher_class: dispatcher_class
    )

    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }) do
      assert_equal [ false, Time.at(0) ],
                   adapter.dispatch_request(FakeRequest.new(slug: "task", project: "demo"), now: Time.at(0))
    end

    assert_equal 7, launcher_options.fetch(:heartbeat_sec)
    assert_equal 41, launcher_options.fetch(:stale_sec)
    assert_equal 17, launcher_options.fetch(:first_heartbeat_timeout_sec)
    assert_equal 13, dispatcher_options.fetch(:launch_timeout_sec)
    assert_equal :launcher, dispatcher_options.fetch(:launcher)
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
      store: :store, limits: {}, config_loader: ->(_root) { Hive::Config.merge_defaults({}) },
      launcher_class: launcher_class, dispatcher_class: dispatcher_class
    )

    assert_equal :accepted, adapter.dispatch_successor(task: task, predecessor: :lost)
    assert_equal task, call.fetch(:task)
    assert_equal :lost, call.fetch(:predecessor)
  end
end
