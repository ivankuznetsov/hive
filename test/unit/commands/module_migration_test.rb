require "test_helper"
require "open3"
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

  def test_deterministic_receipt_delegates_and_emits_the_receipt
    with_tmp_dir do |project|
      selector = { "module" => "patrol", "trigger_id" => "trigger-1" }
      metadata = { "configuration_digest" => "config", "repository" => { "id" => "repo" } }
      receipt = { "schema" => "hive-patrol-evidence-receipt", "schema_version" => 1 }
      arguments = nil
      migration = command(
        "deterministic-receipt", project, yes: false,
        stdin: StringIO.new(JSON.generate("selector" => selector, "metadata" => metadata))
      )
      migration.define_singleton_method(:hive_state_path) { "/state" }

      replacement = lambda do |root, selector:, metadata:, hive_state_path:|
        arguments = [ root, selector, metadata, hive_state_path ]
        receipt
      end
      with_singleton_method(Hive::Modules::Migration::Patrols, :deterministic_receipt_for!, replacement) do
        assert_equal receipt, migration.call
      end

      assert_equal [ File.expand_path(project), selector, metadata, "/state" ], arguments
      assert_equal receipt, JSON.parse(migration.instance_variable_get(:@stdout).string)
    end
  end

  def test_deterministic_qualification_requires_confirmation_then_delegates
    with_tmp_dir do |project|
      request = {
        "receipts" => [ { "receipt" => 1 } ],
        "expected_bindings" => [ { "binding" => 1 } ],
        "generated_at" => "2026-08-04T00:00:00Z",
        "expected_report_digest" => "a" * 64
      }
      denied = command(
        "deterministic-qualification", project, yes: false,
        stdin: StringIO.new(JSON.generate(request))
      )
      assert_raises(Hive::Commands::Module::ConsentRequired) { denied.call }

      report = { "schema" => "hive-module-migration-report", "schema_version" => 2 }
      projection = Struct.new(:to_h).new(report)
      arguments = nil
      migration = command(
        "deterministic-qualification", project, yes: true,
        stdin: StringIO.new(JSON.generate(request))
      )
      migration.define_singleton_method(:hive_state_path) { "/state" }
      replacement = lambda do |root, receipts:, expected_bindings:, generated_at:,
                              expected_report_digest:, hive_state_path:|
        arguments = [
          root, receipts, expected_bindings, generated_at,
          expected_report_digest, hive_state_path
        ]
        projection
      end
      with_singleton_method(Hive::Modules::Migration::Patrols, :admit_deterministic_qualification!, replacement) do
        assert_equal report, migration.call
      end

      assert_equal [
        File.expand_path(project), request.fetch("receipts"),
        request.fetch("expected_bindings"), request.fetch("generated_at"),
        request.fetch("expected_report_digest"), "/state"
      ], arguments
      assert_equal report, JSON.parse(migration.instance_variable_get(:@stdout).string)
    end
  end

  def test_deterministic_input_is_bounded_strict_utf8_json_object
    with_tmp_dir do |project|
      invalid_inputs = [
        " " * (Hive::Commands::Module::Migration::MAX_REQUEST_BYTES + 1),
        "{",
        "[]",
        "\xFF".b
      ]
      invalid_inputs.each do |input|
        migration = command(
          "deterministic-receipt", project, yes: false, stdin: StringIO.new(input)
        )
        assert_raises(Hive::ConfigError) { migration.call }
      end
    end
  end

  def test_deterministic_input_rejects_extra_top_level_keys
    with_tmp_dir do |project|
      receipt_request = { "selector" => {}, "metadata" => {}, "extra" => true }
      qualification_request = {
        "receipts" => [], "expected_bindings" => [], "generated_at" => "now",
        "expected_report_digest" => "a" * 64, "extra" => true
      }

      assert_raises(Hive::ConfigError) do
        command(
          "deterministic-receipt", project, yes: false,
          stdin: StringIO.new(JSON.generate(receipt_request))
        ).call
      end
      assert_raises(Hive::ConfigError) do
        command(
          "deterministic-qualification", project, yes: true,
          stdin: StringIO.new(JSON.generate(qualification_request))
        ).call
      end
    end
  end

  def test_unknown_action_error_lists_all_actions
    error = assert_raises(Hive::Error) do
      command("unknown", Dir.pwd, yes: false).call
    end
    assert_equal Hive::ExitCodes::USAGE, error.exit_code
    assert_match(/deterministic-receipt, or deterministic-qualification/, error.message)
  end

  def test_migration_load_does_not_load_the_module_lifecycle_base
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path("../../../lib", __dir__).inspect})
      require "hive/commands/module/migration"
      abort "module lifecycle base loaded" if $LOADED_FEATURES.any? { |path| path.end_with?("/hive/commands/module/base.rb") }
    RUBY
    _out, err, status = Open3.capture3(RbConfig.ruby, "-e", script)

    assert status.success?, err
  end

  private

  def command(action, project, yes:, json: true, stdin: StringIO.new)
    Hive::Commands::Module::Migration.new(
      action, project_root: project, json: json, stdout: StringIO.new, stdin: stdin,
      yes: yes
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
