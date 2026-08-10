require "test_helper"
require "hive/commands/module"

class ModuleCommandTest < Minitest::Test
  include HiveTestHelper

  def test_rejects_missing_unknown_and_extra_arguments
    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new(nil, nil, project_root: Dir.pwd).call!
    end
    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new("unknown", nil, project_root: Dir.pwd).call!
    end
    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new("list", "extra", project_root: Dir.pwd).call!
    end
  end

  def test_top_level_router_dispatches_special_and_subject_commands
    fake = Object.new
    fake.define_singleton_method(:call) { :called }
    constructors = {}

    require "hive/commands/module/list"
    with_replaced_singleton_method(
      Hive::Commands::Module::List, :new,
      ->(*args, **options) { constructors[:list] = [ args, options ]; fake }
    ) do
      assert_equal :called, Hive::Commands::Module.new("list", nil, project_root: "/project").call!
    end
    assert_empty constructors.dig(:list, 0)

    require "hive/commands/module/status"
    with_replaced_singleton_method(
      Hive::Commands::Module::Status, :new,
      ->(*args, **options) { constructors[:status] = [ args, options ]; fake }
    ) do
      assert_equal :called, Hive::Commands::Module.new("status", nil, project_root: "/project").call!
    end
    assert_equal [ "" ], constructors.dig(:status, 0)

    require "hive/commands/module/migration"
    with_replaced_singleton_method(
      Hive::Commands::Module::Migration, :new,
      ->(*args, **options) { constructors[:migration] = [ args, options ]; fake }
    ) do
      assert_equal :called,
                   Hive::Commands::Module.new(
                     "migration", "status", project_root: "/project", reviewer: "reviewer"
                   ).call!
    end
    assert_equal [ "status" ], constructors.dig(:migration, 0)
    assert_equal "reviewer", constructors.dig(:migration, 1, :reviewer)

    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new("migration", nil, project_root: "/project").call!
    end
    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new("inspect", nil, project_root: "/project").call!
    end
  end

  def test_command_builder_forwards_lifecycle_dry_run_and_state_options
    require "hive/commands/module/install"
    require "hive/commands/module/update"
    require "hive/commands/module/enable"
    fake = Object.new
    calls = {}
    {
      "install" => Hive::Commands::Module::Install,
      "update" => Hive::Commands::Module::Update,
      "enable" => Hive::Commands::Module::Enable
    }.each do |verb, klass|
      with_replaced_singleton_method(
        klass, :new, ->(*args, **options) { calls[verb] = [ args, options ]; fake }
      ) do
        built = Hive::Commands::Module.new(
          verb, "demo", project_root: "/project", yes: true, dry_run: true,
          receipt: "receipt", settings: [ "mode=safe" ], hooks: [ "hook=true" ],
          grants: [ "repository_write=true" ]
        ).send(:command)
        assert_same fake, built
      end
    end
    assert_equal [ "mode=safe" ], calls.dig("install", 1, :settings)
    assert_equal [ "hook=true" ], calls.dig("update", 1, :hooks)
    refute calls.dig("enable", 1).key?(:settings)

    assert_raises(Hive::Commands::Module::UsageError) do
      Hive::Commands::Module.new("dry-run", "demo", project_root: "/project").send(:command)
    end
    require "hive/commands/module/dry_run"
    with_replaced_singleton_method(
      Hive::Commands::Module::DryRun, :new,
      ->(*args, **options) { calls[:dry_run] = [ args, options ]; fake }
    ) do
      built = Hive::Commands::Module.new(
        "dry-run", "demo", project_root: "/project", event_name: "task.completed",
        schedule: "0 * * * *", occurred_at: "2026-07-22T00:00:00Z", hooks: [ "task" ]
      ).send(:command)
      assert_same fake, built
    end
    assert_equal "task.completed", calls.dig(:dry_run, 1, :event_name)
    assert_equal "task", calls.dig(:dry_run, 1, :hook_id)

    routed = Hive::Commands::Module.new("enable", "demo", project_root: "/project")
    routed.define_singleton_method(:command) { fake }
    fake.define_singleton_method(:call) { :routed }
    assert_equal :routed, routed.call!
  end

  def test_error_schema_mapping_and_human_usage_failure
    mappings = {
      [ "list", nil ] => "hive-module-list",
      [ "inspect", "demo" ] => "hive-module-status",
      [ "status", "demo" ] => "hive-module-status",
      [ "doctor", "demo" ] => "hive-module-doctor",
      [ "dry-run", "demo" ] => "hive-module-dry-run",
      [ "migration", "status" ] => "hive-module-migration",
      [ "migration", "report" ] => "hive-module-migration-report",
      [ "migration", "deterministic-qualification" ] => "hive-module-migration-report"
    }
    mappings.each do |(verb, subject), schema|
      command = Hive::Commands::Module.new(verb, subject, project_root: "/project")
      assert_equal schema, command.send(:schema_for_subcommand)
    end

    _out, err = capture_io do
      error = assert_raises(SystemExit) do
        Hive::Commands::Module.new("unknown", nil, project_root: "/project").call
      end
      assert_equal Hive::ExitCodes::USAGE, error.status
    end
    assert_includes err, "hive module: unknown module subcommand"
  end
end
