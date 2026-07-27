require "test_helper"
require "hive/modules/adapters/patrol"
require "hive/module_package/validator"

class ModulesAdaptersPatrolTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 22, 15, 0, 0)
  Configuration = Data.define(:settings, :grants, :digest)

  class FakeCommand
    def initialize(result = { "ok" => true }) = @result = result
    def call = @result
  end

  class FakeScheduler
    def initialize(candidate) = @candidate = candidate
    def candidates(now:) = @candidate ? [ @candidate.merge(now: now) ] : []
  end

  def test_first_party_package_is_strictly_validated
    result = Hive::ModulePackage::Validator.validate!(
      File.expand_path("../../../../modules/patrol", __dir__), catalog_commit: "f" * 40
    )

    assert_equal "patrol", result.descriptor.name
    assert_equal %w[setup scheduled-scan task-completed], result.descriptor.hooks.map { |hook| hook.fetch("id") }
    assert_equal %w[project.registered], result.descriptor.hooks.first.fetch("events")
    assert_equal [ "task.completed" ], result.descriptor.hooks.last.fetch("events")
    assert result.descriptor.permissions.fetch("repository_write")
  end

  def test_shadow_schedule_records_due_decision_without_invoking_engine
    with_project do |project|
      calls = []
      shadow = []
      adapter = Hive::Modules::Adapters::Patrol.new(
        command_factory: ->(*args) { calls << args; FakeCommand.new },
        scheduler_factory: ->(**) { FakeScheduler.new(project: project.fetch("name")) },
        shadow_sink: ->(row) { shadow << row }
      )

      result = adapter.call(
        project: project, hook_id: "scheduled-scan", event: schedule_event,
        configuration: configuration(shadow: true)
      )

      assert_equal 0, result
      assert_empty calls
      assert_equal "due", shadow.fetch(0).fetch("rationale")
      refute File.exist?(File.join(project.fetch("path"), ".hive-state", "patrol", "state.json"))

      assert_equal 0, adapter.call(
        project: project, hook_id: "task-completed",
        event: task_event("coding"), configuration: configuration(shadow: true)
      )
      assert_equal "matched", shadow.fetch(1).fetch("rationale")
    end
  end

  def test_matching_task_uses_existing_engine_with_effective_config_and_unmatched_task_is_noop
    with_project(owner: "module") do |project|
      calls = []
      adapter = Hive::Modules::Adapters::Patrol.new(
        command_factory: lambda do |name, options|
          calls << [ name, options ]
          FakeCommand.new
        end
      )
      config = configuration(shadow: false, workflows: "coding")

      assert_equal 0, adapter.call(
        project: project, hook_id: "task-completed",
        event: task_event("research"), configuration: config
      )
      assert_empty calls

      assert_equal 0, adapter.call(
        project: project, hook_id: "task-completed",
        event: task_event("coding"), configuration: config
      )
      name, options = calls.fetch(0)
      assert_equal project.fetch("name"), name
      assert_equal project, options.fetch(:project_entry)
      assert_instance_of Hive::Modules::CapabilityContext, options.fetch(:capability_context)
      effective = options.fetch(:config_loader).call(project.fetch("path"))
      assert_equal "timer", effective.dig("patrol", "trigger")
      assert_equal 14_400, effective.dig("patrol", "poll_interval_sec")
    end
  end

  def test_permission_denial_happens_before_mutating_engine
    with_project(owner: "module") do |project|
      calls = []
      denied = configuration(shadow: false)
      denied.grants["repository_write"] = false
      adapter = Hive::Modules::Adapters::Patrol.new(
        command_factory: ->(*args) { calls << args; FakeCommand.new }
      )

      assert_raises(Hive::Modules::CapabilityDenied) do
        adapter.call(
          project: project, hook_id: "task-completed",
          event: task_event("coding"), configuration: denied
        )
      end
      assert_empty calls
    end
  end

  def test_setup_adopts_the_existing_state_store_and_default_factories_are_constructible
    with_project(owner: "module") do |project|
      defaulted = Hive::Modules::Adapters::Patrol.new
      assert_equal 0, defaulted.call(
        project: project, hook_id: "setup", event: event("project.registered"),
        configuration: configuration(shadow: false)
      )
      assert File.directory?(File.join(project.fetch("path"), ".hive-state", "patrol"))
    end
  end

  def test_mutator_schedule_runs_only_due_candidates_and_propagates_engine_failure
    with_project(owner: "module") do |project|
      calls = []
      due = Hive::Modules::Adapters::Patrol.new(
        command_factory: ->(*args) { calls << args; FakeCommand.new("ok" => false) },
        scheduler_factory: lambda do |**options|
          assert_equal [ project ], options.fetch(:registry).call
          assert_equal true, options.fetch(:config_loader).call(project.fetch("path")).dig("patrol", "enabled")
          FakeScheduler.new(project: project.fetch("name"))
        end
      )
      assert_equal 1, due.call(
        project: project, hook_id: "scheduled-scan", event: schedule_event,
        configuration: configuration(shadow: false)
      )
      assert_equal 1, calls.size

      not_due = Hive::Modules::Adapters::Patrol.new(
        command_factory: ->(*args) { calls << args; FakeCommand.new },
        scheduler_factory: ->(**) { FakeScheduler.new(nil) }
      )
      assert_equal 0, not_due.call(
        project: project, hook_id: "scheduled-scan", event: schedule_event,
        configuration: configuration(shadow: false)
      )
      assert_equal 1, calls.size
    end
  end

  def test_default_shadow_journal_and_hook_event_validation_fail_closed
    with_project do |project|
      adapter = Hive::Modules::Adapters::Patrol.new(
        scheduler_factory: ->(**) { FakeScheduler.new(nil) }
      )
      assert_equal 0, adapter.call(
        project: project, hook_id: "scheduled-scan", event: schedule_event,
        configuration: configuration(shadow: true)
      )
      shadow_files = Dir.glob(File.join(
        project.fetch("hive_state_path"), "module-runtime", "migration", "shadow", "**", "*.json"
      ))
      refute_empty shadow_files
      record = JSON.parse(File.binread(shadow_files.fetch(0)))
      refute record.fetch("comparable")
      assert_nil record.fetch("evidence_source")
      assert_empty record.fetch("legacy")

      assert_raises(Hive::ConfigError) do
        adapter.call(
          project: project, hook_id: "unknown", event: schedule_event,
          configuration: configuration(shadow: true)
        )
      end
      assert_raises(Hive::ConfigError) do
        adapter.call(
          project: project, hook_id: "setup", event: schedule_event,
          configuration: configuration(shadow: true)
        )
      end
    end
  end

  def test_default_command_factory_forwards_to_the_legacy_command
    with_project(owner: "module") do |project|
      calls = []
      original = Hive::Commands::Patrol.method(:new)
      Hive::Commands::Patrol.define_singleton_method(:new) do |name, **options|
        calls << [ name, options ]
        FakeCommand.new
      end
      begin
        adapter = Hive::Modules::Adapters::Patrol.new(
          scheduler_factory: ->(**) { FakeScheduler.new(project: project.fetch("name")) }
        )
        assert_equal 0, adapter.call(
          project: project, hook_id: "scheduled-scan", event: schedule_event,
          configuration: configuration(shadow: false)
        )
      ensure
        Hive::Commands::Patrol.define_singleton_method(:new, original)
      end
      assert_equal "demo", calls.fetch(0).fetch(0)
    end
  end

  private

  def with_project(owner: "legacy")
    with_tmp_dir do |root|
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(
        File.join(state, "config.yml"),
        {
          "hive_state_path" => ".hive-state",
          "patrol" => { "enabled" => true },
          "refactor_patrol" => { "enabled" => true }
        }.to_yaml
      )
      project = { "name" => "demo", "path" => root, "hive_state_path" => state }
      write_migration_state(project, owner)
      yield(project)
    end
  end

  def write_migration_state(project, owner)
    cfg = Hive::Config.load(project.fetch("path"))
    timestamp = NOW.iso8601(6)
    state = {
      "schema" => "hive-module-migration", "schema_version" => 1,
      "project" => project.fetch("name"), "project_root" => project.fetch("path"),
      "epoch" => 1, "status" => owner == "module" ? "module" : "shadowing",
      "owners" => Hive::Modules::Migration::Patrols::MODULES.to_h { |name| [ name, owner ] },
      "admissions" => Hive::Modules::Migration::Patrols::MODULES.to_h { |name| [ name, true ] },
      "bindings" => Hive::Modules::Migration::Patrols::MODULES.to_h do |name|
        [ name, {
          "reviewed_config" => cfg,
          "reviewed_config_digest" => Digest::SHA256.hexdigest(
            Hive::Modules::Migration::Patrols.canonical(cfg)
          )
        } ]
      end,
      "blockers" => {}, "cutover_selections" => {}, "watermarks" => {},
      "shadow_started_at" => timestamp, "cutover_at" => nil, "rollback_at" => nil,
      "updated_at" => timestamp
    }
    path = Hive::Modules::Migration::Patrols.state_file(
      project.fetch("path"), hive_state_path: project.fetch("hive_state_path")
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, Hive::Modules::Migration::Patrols.canonical(state))
  end

  def configuration(shadow:, workflows: "*")
    Configuration.new(
      settings: {
        "shadow_mode" => shadow, "trigger" => "timer", "poll_interval_sec" => 14_400,
        "task_completed_workflows" => workflows, "dry_run" => false
      },
      grants: {
        "repository_write" => true, "github_mutations" => [ "pull_requests" ],
        "external_commands" => %w[gh git], "network_hosts" => [ "api.github.com" ],
        "filesystem_read" => [ "repository" ], "filesystem_write" => [ ".hive-state/patrol/**" ],
        "secrets" => []
      }, digest: "d" * 64
    )
  end

  def schedule_event
    event("schedule", "payload" => { "schedule" => "*/10 * * * *" })
  end

  def task_event(workflow)
    event("task.completed", "payload" => { "workflow" => workflow, "task_id" => 1 })
  end

  def event(name, overrides = {})
    {
      "event_id" => "evt-#{'a' * 64}", "event_name" => name,
      "occurred_at" => NOW.iso8601(6), "payload" => {}
    }.merge(overrides)
  end
end
