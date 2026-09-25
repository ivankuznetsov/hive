require "test_helper"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"
require "yaml"
require "hive/one_shot/project_guard"

class OneShotCommandTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def test_all_commands_emit_one_shared_document_without_explicit_json
    cases = {
      "patrol" => "patrol",
      "refactor-patrol" => "architecture_patrol",
      "babysit" => "babysitter",
      "daemon" => "dispatch"
    }
    with_tmp_global_config do |home|
      cases.each do |command, component|
        out, _err, status = run_hive(home, command, "missing", "--once", "--dry-run")
        refute status.success?
        document = one_document(out)
        assert_equal component, document.fetch("component")
        assert_equal "missing", document.fetch("project")
        assert_equal "error", document.fetch("status")
        assert_nil document.fetch("pending")
        assert_schema(document)
      end
    end
  end

  def test_explicit_json_and_invalid_once_combinations_still_emit_one_document
    cases = [
      %w[patrol demo --once --list --json],
      %w[refactor-patrol demo --once --list --json],
      %w[babysit start --once --json],
      %w[daemon start --once --json]
    ]
    with_tmp_global_config do |home|
      cases.each do |argv|
        out, _err, status = run_hive(home, *argv)
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        document = one_document(out)
        assert_equal "error", document.fetch("status")
        assert_equal "usage", document.dig("error", "code")
        assert_schema(document)
      end
    end
  end

  def test_daemon_owner_refuses_babysitter_before_runtime_construction
    with_tmp_global_config do |home|
      root = File.join(home, "project")
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => [ { "name" => "demo", "path" => root } ] }.to_yaml
      )
      guard = Hive::OneShot::ProjectGuard.new(
        state_root: state, project: "demo", kind: :daemon
      ).acquire!
      begin
        out, _err, status = run_hive(home, "babysit", "demo", "--once")
        assert_equal Hive::ExitCodes::TEMPFAIL, status.exitstatus
        document = one_document(out)
        assert_equal "refused", document.fetch("status")
        assert_equal "daemon_owned", document.dig("error", "code")
        assert_equal Process.pid, document.dig("owner", "pid")
        assert_schema(document)
      ensure
        guard.release!
      end
    end
  end

  def test_zero_project_babysitter_aggregate_is_a_successful_document
    with_tmp_global_config do |home|
      out, _err, status = run_hive(home, "babysit", "--once", "--all")
      assert status.success?
      document = one_document(out)
      assert_equal "ok", document.fetch("status")
      assert_empty document.fetch("projects")
      assert document.fetch("host_stop_allowed")
      assert_schema(document)
    end
  end

  def test_daemon_dry_run_succeeds_for_an_idle_registered_project
    with_tmp_global_config do |home|
      root = File.join(home, "project")
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "stages"))
      File.write(
        File.join(state, "config.yml"),
        { "default_workflow" => "coding", "daemon" => { "enabled" => true } }.to_yaml
      )
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => [ { "name" => "demo", "path" => root,
                                        "hive_state_path" => state } ] }.to_yaml
      )
      prepare_runtime_project(state_home: home, name: "demo", path: root,
                              state_root_path: state).disconnect

      out, _err, status = run_hive(home, "daemon", "demo", "--once", "--dry-run")
      assert status.success?
      document = one_document(out)
      assert_equal "ok", document.fetch("status")
      assert_empty document.fetch("ran")
      assert_empty document.dig("pending", "runnable_now")
      assert_schema(document)
    end
  end

  private

  def run_hive(home, *argv)
    Open3.capture3({ "HIVE_HOME" => home }, RbConfig.ruby, "-Ilib", HIVE_BIN, *argv)
  end

  def one_document(output)
    lines = output.lines.reject { |line| line.strip.empty? }
    assert_equal 1, lines.length, output
    JSON.parse(lines.fetch(0))
  end

  def assert_schema(document)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-one-shot"))))
    assert_empty schema.validate(document).map { |failure| failure.fetch("error") }
  end
end
