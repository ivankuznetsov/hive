require "test_helper"
require "hive/commands/runtime"
require "json_schemer"
require "open3"

class RuntimeCommandTest < Minitest::Test
  include HiveTestHelper

  def test_status_is_typed_and_returns_nonzero_without_creating_missing_storage
    with_tmp_dir do |root|
      output = StringIO.new
      assert_equal 1, Hive::Commands::Runtime.new(
        "status", json: true, output: output, state_home: root
      ).call
      payload = JSON.parse(output.string)
      assert_equal false, payload.fetch("ok")
      assert_equal "absent", payload.dig("result", "phase")
      assert_equal "missing", payload.dig("result", "database", "status")
      assert_equal "hive setup", payload.dig("result", "next_action")
      assert_nil payload.dig("result", "lifecycle")
      assert_empty runtime_schema.validate(payload).to_a
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  def test_executable_reports_absent_runtime_with_nonzero_exit_and_false_ok
    with_tmp_dir do |root|
      [ %w[runtime status --json], %w[runtime --json status], %w[runtime --json] ].each do |argv|
        output, errors, process = Open3.capture3(
          { "HIVE_HOME" => root }, RbConfig.ruby,
          File.expand_path("../../../bin/hive", __dir__), *argv
        )
        assert_equal 1, process.exitstatus, errors
        payload = JSON.parse(output)
        assert_equal false, payload.fetch("ok")
        assert_equal "absent", payload.dig("result", "phase")
        assert_equal "hive setup", payload.dig("result", "next_action")
        assert_empty runtime_schema.validate(payload).to_a
        refute runtime_schema.valid?(payload.merge("ok" => true))
        refute_path_exists Hive::Paths.runtime_control_plane_path(root)
      end
    end
  end

  def test_json_failure_is_typed_and_actionable
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      File.write(path, "invalid", perm: 0o600)
      output = StringIO.new
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        Hive::Commands::Runtime.new("status", json: true, output: output, state_home: root).call
      end
      payload = JSON.parse(output.string)
      assert_equal false, payload.fetch("ok")
      assert_equal "status", payload.fetch("action")
      assert_kind_of String, payload.fetch("next_action")
      assert_empty runtime_schema.validate(payload).to_a
    end
  end

  def test_json_failure_supplies_a_next_action_when_the_runtime_error_has_none
    output = StringIO.new
    error = Hive::RuntimeControlPlane::IntegrityError.new(
      "broken", code: :broken, action: nil
    )

    with_replaced_singleton_method(Hive::RuntimeControlPlane::Installation, :status, ->(**) { raise error }) do
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        Hive::Commands::Runtime.new("status", json: true, output: output).call
      end
    end

    assert_equal "repair the reported runtime database, then run hive runtime status",
                 JSON.parse(output.string).fetch("next_action")
  end

  def test_status_uses_database_identity_without_manifests
    with_tmp_dir do |root|
      status = Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      output = StringIO.new
      assert_equal 0, Hive::Commands::Runtime.new(
        "status", json: true, output: output, state_home: root
      ).call
      payload = JSON.parse(output.string)
      assert_equal true, payload.fetch("ok")
      assert_equal status, payload.fetch("result")
      assert_equal "running", payload.dig("result", "lifecycle", "phase")
      assert_equal true, payload.dig("result", "lifecycle", "admission_open")
      assert_empty runtime_schema.validate(payload).to_a
      text = StringIO.new
      assert_equal 0, Hive::Commands::Runtime.new("status", output: text, state_home: root).call
      assert_includes text.string, "phase: active"
    end
  end

  def test_removed_recovery_actions_are_rejected_before_any_database_write
    with_tmp_dir do |root|
      %w[resume snapshot backup restore downgrade].each do |action|
        error = assert_raises(Hive::UsageError) do
          Hive::Commands::Runtime.new(action, output: StringIO.new, state_home: root).call
        end
        assert_includes error.message, "expected one of status, projects, payloads"
      end
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  def test_projects_lists_registry_paths_without_loading_project_config
    with_tmp_global_config(runtime: false) do |home|
      root = File.join(home, "workspace", "demo")
      File.write(Hive::Config.global_config_path, {
        "registered_projects" => [
          { "name" => "demo", "path" => root, "hive_state_path" => "state" },
          { "name" => "broken" }
        ]
      }.to_yaml)
      output = StringIO.new
      assert_equal 0, Hive::Commands::Runtime.new("projects", json: true, output: output).call
      payload = JSON.parse(output.string)
      assert_empty runtime_schema.validate(payload).to_a
      assert_equal Hive::Config.global_config_path, payload.dig("result", "registry_path")
      assert_equal 1, payload.dig("result", "projects").size
      project = payload.dig("result", "projects").first
      assert_equal [ "demo", root, nil, File.join(root, "state") ],
                   project.values_at("name", "path", "real_path", "hive_state_path")
      assert_kind_of String, project.fetch("project_id")
      text = StringIO.new
      assert_equal 0, Hive::Commands::Runtime.new("projects", output: text).call
      assert_match(/^projects: \[\{.*"name":"demo"/, text.string)
    end
  end

  def test_projects_reports_an_unreadable_registry_with_a_registry_next_action
    with_tmp_global_config(runtime: false) do
      File.write(Hive::Config.global_config_path, "registered_projects: [")
      output = StringIO.new
      assert_raises(Hive::ConfigError) do
        Hive::Commands::Runtime.new("projects", json: true, output: output).call
      end
      payload = JSON.parse(output.string)
      assert_empty runtime_schema.validate(payload).to_a
      assert_equal [ "projects", "config", "repair the global Hive registry, then run hive runtime projects" ],
                   payload.values_at("action", "runtime_code", "next_action")
    end
  end

  def test_payloads_reports_absent_storage_without_creating_it
    with_tmp_dir do |root|
      output = StringIO.new
      assert_equal 0, Hive::Commands::Runtime.new("payloads", json: true, output: output, state_home: root).call
      payload = JSON.parse(output.string)
      assert_empty runtime_schema.validate(payload).to_a
      assert_equal true, payload.fetch("ok")
      assert_equal({ "phase" => "absent", "payload_root" => Hive::Paths.runtime_payload_root(root),
                     "payloads" => [] }, payload.fetch("result"))
      refute_path_exists Hive::Paths.runtime_control_plane_path(root)
    end
  end

  def test_payloads_resolve_references_on_a_read_only_state_root_without_sidecars
    with_tmp_dir do |root|
      seed_payload_reference(root)
      path = Hive::Paths.runtime_control_plane_path(root)
      before = Dir.children(root).sort
      File.chmod(0o500, root)
      output = StringIO.new
      with_confirmed_read_only_mount do
        assert_equal 0, Hive::Commands::Runtime.new("payloads", json: true, output: output, state_home: root).call
      end
      payload = JSON.parse(output.string)
      assert_empty runtime_schema.validate(payload).to_a
      assert_equal "active", payload.dig("result", "phase")
      assert_equal 1, payload.dig("result", "payloads").size
      reference = payload.dig("result", "payloads").first
      assert_equal [ "log", "open", "task-1", nil, "open/a1/log" ],
                   reference.values_at("kind", "state", "task_id", "attempt_id", "relative_path")
      assert_equal File.join(Hive::Paths.runtime_payload_root(root), "open/a1/log"), reference.fetch("path")
      text = StringIO.new
      with_confirmed_read_only_mount do
        assert_equal 0, Hive::Commands::Runtime.new("payloads", output: text, state_home: root).call
      end
      assert_includes text.string, "phase: active"
      assert_equal before, Dir.children(root).sort
      refute_path_exists "#{path}-wal"
      refute_path_exists "#{path}-shm"
    ensure
      File.chmod(0o700, root)
    end
  end

  def test_payloads_on_an_unconfirmed_read_only_root_fail_with_the_runtime_envelope
    with_tmp_dir do |root|
      seed_payload_reference(root)
      File.chmod(0o500, root)
      output = StringIO.new
      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        Hive::Commands::Runtime.new("payloads", json: true, output: output, state_home: root).call
      end
      assert_equal :state_storage_read_only, error.code
      payload = JSON.parse(output.string)
      assert_empty runtime_schema.validate(payload).to_a
      assert_equal [ "payloads", "state_storage_read_only" ], payload.values_at("action", "runtime_code")
      refute_path_exists "#{Hive::Paths.runtime_control_plane_path(root)}-wal"
    ensure
      File.chmod(0o700, root)
    end
  end

  def test_payloads_raise_unsupported_storage
    with_tmp_dir do |root|
      File.write(Hive::Paths.runtime_control_plane_path(root), "invalid", perm: 0o600)
      output = StringIO.new
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        Hive::Commands::Runtime.new("payloads", json: true, output: output, state_home: root).call
      end
      payload = JSON.parse(output.string)
      assert_empty runtime_schema.validate(payload).to_a
      assert_equal [ "payloads", "database_corrupt" ], payload.values_at("action", "runtime_code")
    end
  end

  private

  # Seeds one task-owned reference, then leaves a clean WAL database with no
  # sidecars, which is what a quiesced, read-only-mounted state root holds.
  def seed_payload_reference(root)
    Hive::RuntimeControlPlane::Installation.setup(state_home: root)
    path = Hive::Paths.runtime_control_plane_path(root)
    database = Hive::RuntimeControlPlane::Database.new(path: path)
    now = Time.now.utc.iso8601(6)
    database.transaction do |db|
      db[:projects].insert(
        project_id: "p1", installation_id: db[:installations].get(:installation_id),
        registration_id: "p1", name: "demo", observed_path: "/w/demo",
        state_root_path: "/w/demo/.hive-state", active: 1, registered_at: now
      )
      db[:task_subjects].insert(
        task_id: "task-1", project_id: "p1", workflow_id: "coding", task_slug: "t",
        observed_path: "/w/demo/t", generation: 0, created_at: now, last_observed_at: now
      )
      db[:payload_references].insert(
        payload_id: "pl-1", task_id: "task-1", kind: "log", relative_path: "open/a1/log",
        state: "open", created_at: now
      )
    end
    database.checkpoint!
    database.disconnect
    [ "#{path}-wal", "#{path}-shm" ].each { |sidecar| FileUtils.rm_f(sidecar) }
  end

  def with_confirmed_read_only_mount
    klass = Hive::RuntimeControlPlane::Database
    original = klass.instance_method(:storage_mount_status)
    klass.define_method(:storage_mount_status) { :read_only }
    yield
  ensure
    klass.define_method(:storage_mount_status, original)
    klass.send(:private, :storage_mount_status)
  end

  def runtime_schema
    JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-runtime-maintenance"))))
  end
end
