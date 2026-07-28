require "test_helper"
require "hive/commands/module/migration"

class ModuleMigrationCommandTest < Minitest::Test
  include HiveTestHelper

  Outcome = Data.define(:state)

  class FakeMigration
    attr_reader :rollbacks, :cutovers

    def initialize
      @rollbacks = 0
      @cutovers = []
    end

    def rollback!(now:)
      @rollbacks += 1
      Outcome.new({ "status" => "rolled_back", "at" => now.iso8601 })
    end

    def cutover!(report:, now:)
      @cutovers << [ report, now ]
      Outcome.new({ "status" => "cut_over", "at" => now.iso8601 })
    end
  end

  def test_rollback_and_cutover_emit_the_resulting_state
    with_tmp_dir do |project|
      migration = FakeMigration.new
      rollback = command("rollback", project, yes: true)
      rollback.instance_variable_set(:@migration, migration)

      assert_equal "rolled_back", rollback.call.fetch("status")
      assert_equal 1, migration.rollbacks

      report = Object.new
      cutover = command("cutover", project, yes: true)
      cutover.instance_variable_set(:@migration, migration)
      cutover.define_singleton_method(:report_path) { "/unused/report.json" }
      with_singleton_method(Hive::Modules::Migration::Report, :load, ->(_path) { report }) do
        assert_equal "cut_over", cutover.call.fetch("status")
      end
      assert_equal report, migration.cutovers.last.first
    end
  end

  def test_confirmation_state_and_project_identity_fail_closed
    with_tmp_dir do |project|
      denied = command("rollback", project, yes: false)
      assert_raises(Hive::Commands::Module::ConsentRequired) { denied.call }

      status = command("status", project, yes: false, json: false)
      status.define_singleton_method(:read_state) { { "status" => "shadowing" } }
      assert_equal({ "status" => "shadowing" }, status.call)
      assert_match(/Patrol module migration: shadowing/, status.instance_variable_get(:@stdout).string)

      missing = command("status", project, yes: false)
      with_singleton_method(Hive::Modules::Migration::Patrols, :read_state, ->(*) { nil }) do
        assert_raises(Hive::ConfigError) { missing.call }
      end

      registered = [ { "name" => "registered-name", "path" => File.expand_path(project) } ]
      with_singleton_method(Hive::Config, :registered_projects, -> { registered }) do
        assert_equal "registered-name", status.send(:project_name)
      end
      with_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
        assert_equal File.basename(project), status.send(:project_name)
      end
    end
  end

  private

  def command(action, project, yes:, json: true)
    Hive::Commands::Module::Migration.new(
      action, project_root: project, json: json, stdout: StringIO.new, yes: yes
    )
  end

  def with_singleton_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, replacement)
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
