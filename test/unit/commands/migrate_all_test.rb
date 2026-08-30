require "test_helper"
require "hive/commands/migrate_all"
require "hive/runtime_control_plane/cutover"

class MigrateAllCommandTest < Minitest::Test
  Result = Data.define(:phase)

  def test_delegates_one_irreversible_fleet_cutover_without_per_project_mutation
    calls = []
    projects = [ { "name" => "alpha" }, { "name" => "beta" } ]
    output = StringIO.new
    command = Hive::Commands::MigrateAll.new(
      projects: projects, output: output, confirm: true, exclusions: [ "beta" ],
      cutover: ->(**options) { calls << options; Result.new("active") }
    )

    assert_equal 0, command.call
    assert_equal [ { confirm: true, exclusions: [ "beta" ], projects: projects } ], calls
    assert_includes output.string, "preparing 2 registered projects"
    assert_includes output.string, "irreversible"
    assert_includes output.string, "migration: active"
  end

  def test_interactive_previous_release_route_prompts_before_cutover
    input = StringIO.new("yes\n")
    input.define_singleton_method(:tty?) { true }
    calls = []
    output = StringIO.new

    result = Hive::Commands::MigrateAll.new(
      projects: [], input: input, output: output, confirm: false,
      cutover: ->(**options) { calls << options; Result.new("active") }
    ).call

    assert_equal 0, result
    assert_equal true, calls.first.fetch(:confirm)
    assert_includes output.string, "cannot be rolled back"
  end

  def test_noninteractive_previous_release_route_refuses_with_exact_yes_command
    error = assert_raises(Hive::RuntimeControlPlane::Cutover::ConfirmationRequired) do
      Hive::Commands::MigrateAll.new(
        projects: [], input: StringIO.new, output: StringIO.new, confirm: false,
        cutover: ->(**) { flunk "cutover must not start" }
      ).call
    end

    assert_equal "hive migrate --all --yes", error.action
    assert_includes error.message, "non-interactive"
  end
end
