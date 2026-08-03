require "test_helper"
require "hive/commands/migrate_all"

class MigrateAllCommandTest < Minitest::Test
  include HiveTestHelper

  Command = Struct.new(:callable) do
    def call
      callable.call
    end
  end

  def test_migrates_every_registered_project_with_visible_progress
    output = StringIO.new
    error_output = StringIO.new
    calls = []
    projects = [
      { "name" => "alpha", "path" => "/tmp/alpha" },
      { "name" => "beta", "path" => "/tmp/beta" }
    ]

    result = Hive::Commands::MigrateAll.new(
      projects: projects,
      output: output,
      error_output: error_output,
      global_migration: -> { },
      binary: "hive",
      command_factory: lambda { |path|
        Command.new(-> { calls << path })
      }
    ).call

    assert_equal 0, result
    assert_equal %w[/tmp/alpha /tmp/beta], calls
    assert_includes output.string, "hive: migration: checking 2 registered projects"
    assert_includes output.string, "hive: migration: [1/2] alpha (/tmp/alpha)"
    assert_includes output.string, "hive: migration: [2/2] beta (/tmp/beta)"
    assert_includes output.string, "hive: migration: complete (2 projects migrated, 0 failed)"
    assert_empty error_output.string
  end

  def test_continues_after_failure_and_prints_human_readable_recovery
    output = StringIO.new
    error_output = StringIO.new
    calls = []
    projects = [
      { "name" => "broken project", "path" => "/tmp/broken project" },
      { "name" => "healthy", "path" => "/tmp/healthy" }
    ]

    error = assert_raises(Hive::Error) do
      Hive::Commands::MigrateAll.new(
        projects: projects,
        output: output,
        error_output: error_output,
        global_migration: -> { },
        binary: "hive",
        command_factory: lambda { |path|
          Command.new(lambda {
            calls << path
            raise Hive::ConfigError, "selected profile is unavailable\nrestore it first" if path.include?("broken")
          })
        }
      ).call
    end

    assert_equal [ "/tmp/broken project", "/tmp/healthy" ], calls
    assert_includes error_output.string,
                    "hive: migration: failed for broken project: selected profile is unavailable restore it first"
    assert_includes error_output.string,
                    "hive: migration: recovery: hive migrate /tmp/broken\\ project"
    assert_includes error_output.string, "hive: migration: incomplete (1 project migrated, 1 project failed)"
    assert_match(/1 of 2 registered projects failed/, error.message)
    assert_match(/fix the errors above and run `hive migrate --all`/, error.message)
  end

  def test_no_registered_projects_still_checks_global_migration
    output = StringIO.new
    global_calls = 0

    result = Hive::Commands::MigrateAll.new(
      projects: [],
      output: output,
      binary: "hive",
      global_migration: -> { global_calls += 1 }
    ).call

    assert_equal 0, result
    assert_equal 1, global_calls
    assert_includes output.string, "hive: migration: no registered projects; global state is current"
  end

  def test_global_migration_failure_is_human_readable
    output = StringIO.new
    error_output = StringIO.new

    error = assert_raises(Hive::Error) do
      Hive::Commands::MigrateAll.new(
        projects: [],
        output: output,
        error_output: error_output,
        binary: "hive",
        global_migration: -> { raise Hive::ConfigError, "attempt store is locked\nretry after task 42" }
      ).call
    end

    assert_includes output.string, "hive: migration: checking global state"
    assert_includes error_output.string,
                    "hive: migration: global state failed: attempt store is locked retry after task 42"
    assert_includes error_output.string, "hive: migration: recovery: hive migrate --all"
    assert_match(/global migration failed: attempt store is locked retry after task 42/, error.message)
  end

  def test_default_project_migration_does_not_repeat_the_global_migration
    projects = [ { "name" => "alpha", "path" => "/tmp/alpha" } ]
    global_calls = 0
    child_global_migrations = []

    replacement = lambda { |_path, global_migration:, daemon_restarter:|
      child_global_migrations << global_migration
      Command.new(-> { global_migration.call })
    }
    with_replaced_singleton_method(Hive::Commands::Migrate, :new, replacement) do
      Hive::Commands::MigrateAll.new(
        projects: projects,
        output: StringIO.new,
        binary: "hive",
        global_migration: -> { global_calls += 1 }
      ).call
    end

    assert_equal 1, global_calls
    assert_equal [ Hive::Commands::MigrateAll::SKIP_GLOBAL_MIGRATION ], child_global_migrations
  end

  def test_default_project_migrations_coalesce_daemon_restarts
    projects = [
      { "name" => "alpha", "path" => "/tmp/alpha" },
      { "name" => "beta", "path" => "/tmp/beta" }
    ]
    restart_calls = 0

    replacement = lambda { |_path, global_migration:, daemon_restarter:|
      Command.new(lambda {
        global_migration.call
        daemon_restarter.call
      })
    }
    with_replaced_singleton_method(Hive::Commands::Migrate, :new, replacement) do
      Hive::Commands::MigrateAll.new(
        projects: projects,
        output: StringIO.new,
        binary: "hive",
        global_migration: -> { },
        daemon_restarter: -> { restart_calls += 1 }
      ).call
    end

    assert_equal 1, restart_calls
  end

  def test_missing_registered_project_prints_restore_and_registry_cleanup_commands
    output = StringIO.new
    error_output = StringIO.new
    project = { "name" => "missing project", "path" => "/tmp/missing project" }

    error = assert_raises(Hive::Error) do
      Hive::Commands::MigrateAll.new(
        projects: [ project ],
        output: output,
        error_output: error_output,
        binary: "hv",
        global_migration: -> { },
        command_factory: lambda { |_path|
          Command.new(-> { raise Hive::InvalidTaskPath, "not a hive project" })
        }
      ).call
    end

    assert_includes error_output.string,
                    "registered path is missing or no longer contains a Hive project (/tmp/missing project)"
    assert_includes error_output.string,
                    "restore /tmp/missing project, then run hv migrate /tmp/missing\\ project"
    assert_includes error_output.string,
                    "remove the stale registration with hv forget missing\\ project"
    assert_includes error_output.string, "remove all stale registrations with hv prune"
    assert_match(/run `hv migrate --all`/, error.message)
  end

  def test_hv_binary_is_used_in_project_failure_recovery
    error_output = StringIO.new

    assert_raises(Hive::Error) do
      Hive::Commands::MigrateAll.new(
        projects: [ { "name" => "alpha", "path" => "/tmp/alpha" } ],
        output: StringIO.new,
        error_output: error_output,
        binary: "hv",
        global_migration: -> { },
        command_factory: lambda { |_path|
          Command.new(-> { raise Hive::ConfigError, "profile is unavailable" })
        }
      ).call
    end

    assert_includes error_output.string, "hive: migration: recovery: hv migrate /tmp/alpha"
  end
end
