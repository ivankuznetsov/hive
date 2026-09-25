require "test_helper"
require "json_schemer"
require "open3"
require "rbconfig"
require "sqlite3"
require "hive/runtime_control_plane/installation"

class DaemonLifecycleCommandIntegrationTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def test_quiesce_status_and_resume_round_trip_without_a_running_daemon
    with_runtime_home do |root, env|
      output, errors, process = run_hive(env, "daemon", "quiesce", "--timeout", "2", "--json")
      assert_equal 0, process.exitstatus, errors
      quiesced = JSON.parse(output)
      assert_equal true, quiesced.fetch("paused")
      assert_equal "paused", quiesced.fetch("result")
      assert_schema("hive-daemon-quiesce", quiesced)

      output, errors, process = run_hive(env, "daemon", "status", "--json")
      assert_equal 1, process.exitstatus, errors
      status = JSON.parse(output)
      assert_equal false, status.fetch("running")
      assert_equal "paused", status.dig("lifecycle", "phase")
      assert_equal quiesced.fetch("generation"), status.dig("lifecycle", "generation")
      assert_schema("hive-daemon-status", status)

      output, errors, process = run_hive(env, "daemon", "resume", "--timeout", "2", "--json")
      assert_equal 0, process.exitstatus, errors
      resumed = JSON.parse(output)
      assert_equal true, resumed.fetch("resumed")
      assert_equal true, resumed.fetch("admission_reopened")
      assert_equal quiesced.fetch("generation"), resumed.fetch("generation")
      assert_schema("hive-daemon-resume", resumed)
      assert_equal "running", lifecycle(root).fetch(:phase)
    end
  end

  def test_invalid_timeout_emits_action_schema_without_mutating_lifecycle
    with_runtime_home do |root, env|
      before = lifecycle(root)

      [ "0", "not-a-number" ].each do |value|
        output, _errors, process = run_hive(
          env, "daemon", "quiesce", "--timeout", value, "--json"
        )
        assert_equal Hive::ExitCodes::USAGE, process.exitstatus
        payload = JSON.parse(output)
        assert_equal "usage", payload.fetch("error_kind")
        assert_schema("hive-daemon-quiesce", payload)
        assert_equal before, lifecycle(root)
      end
    end
  end

  def test_skewed_status_is_read_only_and_resume_preserves_the_closed_proof
    with_runtime_home do |root, env|
      output, errors, process = run_hive(env, "daemon", "quiesce", "--timeout", "2", "--json")
      assert_equal 0, process.exitstatus, errors
      generation = JSON.parse(output).fetch("generation")
      proof_path = Hive::Paths.runtime_quiescence_proof_path(root)
      proof_before = File.binread(proof_path)
      force_schema_version(root, 0)
      database_before = File.binread(Hive::Paths.runtime_control_plane_path(root))

      output, errors, process = run_hive(env, "daemon", "status", "--json")
      assert_equal 1, process.exitstatus, errors
      status = JSON.parse(output)
      assert_equal "older_schema", status.dig("runtime_installation", "database_status")
      assert_equal "quiescing", status.dig("lifecycle", "phase")
      assert_equal generation, status.dig("lifecycle", "generation")
      assert_equal proof_before, File.binread(proof_path)
      assert_equal database_before, File.binread(Hive::Paths.runtime_control_plane_path(root))
      assert_schema("hive-daemon-status", status)

      output, _errors, process = run_hive(env, "daemon", "resume", "--json")
      assert_equal Hive::ExitCodes::CONFIG, process.exitstatus
      resume = JSON.parse(output)
      assert_equal "migration_required", resume.fetch("error_kind")
      assert_match(/current-format-migration/, resume.fetch("next_action"))
      assert_equal proof_before, File.binread(proof_path)
      assert_schema("hive-daemon-resume", resume)
    end
  end

  private

  def with_runtime_home
    with_tmp_dir do |root|
      Hive::RuntimeControlPlane::Installation.setup(state_home: root)
      env = ENV.to_h.merge(
        "HIVE_HOME" => root, "HOME" => root,
        "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR)
      )
      yield root, env
    end
  end

  def run_hive(env, *argv)
    Open3.capture3(env, RbConfig.ruby, "-Ilib", HIVE_BIN, *argv)
  end

  def lifecycle(root)
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(root)
    )
    row = database.quiescence_status_snapshot.fetch(:lifecycle)
    row.slice(:phase, :generation, :revision, :mutation_sequence)
  ensure
    database&.disconnect
  end

  def force_schema_version(root, version)
    connection = SQLite3::Database.new(Hive::Paths.runtime_control_plane_path(root))
    connection.execute("UPDATE schema_info SET version = ?", version)
  ensure
    connection&.close
  end

  def assert_schema(name, payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    assert_empty schema.validate(payload).map { |error| error["error"] }
  end
end
