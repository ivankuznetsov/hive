require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/new"
require "hive/task_meta"
require "hive/runtime_control_plane/command_schema_installation"

# Keyed `hive new` predates durable command receipts. Until the receipt
# extension is published and installed, a keyed call must keep the per-project
# TaskCapture idempotency it had before receipts existed instead of refusing
# with "command receipts are not installed".
class NewIdempotencyWithoutReceiptsTest < Minitest::Test
  include HiveTestHelper

  NOTICE = Hive::Commands::New::RECEIPT_FALLBACK_NOTICE

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "9" * 64
  }.freeze

  def test_base_only_runtime_creates_once_and_replays_the_existing_task
    with_initialized_project do |project_root, project|
      refute receipts_installed?

      first_out, first_err, first_status = run_keyed(project, "weekly digest", key: "digest:2026-10-12")
      first = JSON.parse(first_out)
      assert_equal 0, first_status
      assert_equal "#{NOTICE}\n", first_err
      assert_equal true, first.fetch("created")
      refute first.key?("command_receipt")
      assert_valid_hive_new(first)

      retry_out, retry_err, retry_status = run_keyed(project, "weekly digest", key: "digest:2026-10-12")
      replay = JSON.parse(retry_out)
      assert_equal 0, retry_status
      assert_equal "#{NOTICE}\n", retry_err
      assert_equal false, replay.fetch("created")
      assert_equal first.fetch("slug"), replay.fetch("slug")
      assert_equal first.fetch("task_folder"), replay.fetch("task_folder")
      assert_valid_hive_new(replay)
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_base_only_runtime_rejects_a_different_request_for_the_same_key
    with_initialized_project do |project_root, project|
      run_keyed(project, "first request", key: "creator:stable", slug: "first-task")

      error = assert_raises(Hive::Commands::New::IdempotencyConflict) do
        capture_io do
          Hive::Commands::New.new(
            project, "different request", slug_override: "second-task",
            idempotency_key: "creator:stable", json: true
          ).call!
        end
      end
      assert_includes error.message, "different"

      out, err, status = run_keyed(project, "different request", key: "creator:stable", slug: "second-task")
      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::USAGE, status
      assert_equal "#{NOTICE}\n", err
      assert_equal "usage", payload.fetch("error_kind")
      assert_equal "IdempotencyConflict", payload.fetch("error_class")
      assert_valid_hive_new(payload)
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_plain_text_replay_reports_the_existing_task
    with_initialized_project do |_project_root, project|
      run_keyed(project, "plain retry", key: "creator:plain", slug: "plain-task")

      out, err = capture_io do
        Hive::Commands::New.new(
          project, "plain retry", slug_override: "plain-task", idempotency_key: "creator:plain"
        ).call!
      end

      assert_includes out, "hive: idempotent task already exists at"
      assert_equal "#{NOTICE}\n", err
    end
  end

  def test_host_without_a_runtime_database_uses_per_project_idempotency
    with_initialized_project(runtime: false) do |project_root, project|
      runtime_path = Hive::Paths.runtime_control_plane_path
      refute File.exist?(runtime_path)

      first_out, first_err, first_status = run_keyed(project, "fresh host", key: "fresh:1")
      retry_out, _retry_err, retry_status = run_keyed(project, "fresh host", key: "fresh:1")

      assert_equal [ 0, 0 ], [ first_status, retry_status ]
      assert_equal "#{NOTICE}\n", first_err
      assert_equal [ true, false ], [ JSON.parse(first_out), JSON.parse(retry_out) ].map { |p| p.fetch("created") }
      assert_equal 1, idempotent_tasks(project_root).size
      refute File.exist?(runtime_path), "the fallback must not create the runtime database"
    end
  end

  # Receipt-path creation still writes the TaskCapture key and fingerprint
  # into meta.yml (the pre-receipt on-disk format), so a task keyed while
  # receipts were available is still deduplicated by the fallback.
  def test_fallback_honours_a_key_recorded_through_the_receipt_path
    with_initialized_project do |project_root, project|
      enable_command_receipts!(project_root)
      first_out, first_err, = run_keyed(project, "cross path", key: "cross:1", slug: "cross-task")
      assert_empty first_err
      assert JSON.parse(first_out).key?("command_receipt")
      meta = Hive::TaskMeta.read(File.join(project_root, ".hive-state", "stages", "1-inbox", "cross-task"))
      assert_equal "cross:1", meta[:idempotency_key]
      assert_match(/\A[0-9a-f]{64}\z/, meta[:input_fingerprint])

      with_replaced_singleton_method(Hive::CommandOperation, :receipts_installed?, ->(_store) { false }) do
        out, err, status = run_keyed(project, "cross path", key: "cross:1", slug: "cross-task")
        assert_equal 0, status
        assert_equal "#{NOTICE}\n", err
        assert_equal [ false, "cross-task" ], JSON.parse(out).values_at("created", "slug")
      end
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_installed_receipts_keep_the_command_operation_path
    with_initialized_project do |project_root, project|
      enable_command_receipts!(project_root)

      first_out, first_err, = run_keyed(project, "durable", key: "durable:1", slug: "durable-task")
      retry_out, retry_err, = run_keyed(project, "durable", key: "durable:1", slug: "durable-task")

      assert_empty first_err
      assert_empty retry_err
      assert_equal first_out, retry_out
      assert_equal "succeeded", JSON.parse(retry_out).dig("command_receipt", "state")
    end
  end

  def test_concurrent_same_key_calls_create_one_task
    with_initialized_project do |project_root, project|
      # Children must not inherit writable SQLite connections.
      Hive::RuntimeControlPlane.disconnect
      go_reader, go_writer = IO.pipe
      results = Array.new(3) do
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          go_writer.close
          go_reader.read(1)
          out, _err, status = run_keyed(project, "race", key: "race:1", slug: "race-task")
          writer.write(JSON.generate("status" => status, "payload" => JSON.parse(out)))
          writer.close
          exit! 0
        end
        writer.close
        [ pid, reader ]
      end
      go_reader.close
      go_writer.write("go" * 3)
      go_writer.close
      outcomes = results.map do |pid, reader|
        body = reader.read
        reader.close
        Process.wait(pid)
        JSON.parse(body)
      end

      assert_equal [ 0, 0, 0 ], outcomes.map { |o| o.fetch("status") }
      created = outcomes.map { |o| o.dig("payload", "created") }
      assert_equal 1, created.count(true), outcomes.inspect
      assert_equal [ "race-task" ], outcomes.map { |o| o.dig("payload", "slug") }.uniq
      assert_equal 1, idempotent_tasks(project_root).size
    end
  end

  def test_corrupt_runtime_database_still_fails_without_creating_a_task
    with_initialized_project(runtime: false) do |project_root, project|
      runtime_path = Hive::Paths.runtime_control_plane_path
      FileUtils.mkdir_p(File.dirname(runtime_path))
      File.binwrite(runtime_path, "not a sqlite database" * 64)

      out, err, status = run_keyed(project, "corrupt", key: "corrupt:1")
      payload = JSON.parse(out)

      assert_equal Hive::ExitCodes::CONFIG, status
      assert_equal "config", payload.fetch("error_kind")
      assert_includes payload.fetch("message"), "cannot verify command receipt storage"
      refute_includes err, NOTICE
      assert_empty idempotent_tasks(project_root)
    end
  end

  def test_busy_receipt_storage_still_fails_without_creating_a_task
    with_initialized_project do |project_root, project|
      busy = Hive::CommandReceiptStore.new
      busy.define_singleton_method(:require_extension!) { raise SQLite3::BusyException, "database is locked" }

      out, err, status = with_captured_exit do
        Hive::Commands::New.new(
          project, "busy", idempotency_key: "busy:1", json: true, command_receipt_store: busy
        ).call
      end

      assert_equal Hive::ExitCodes::TEMPFAIL, status
      assert_equal "concurrent_run", JSON.parse(out).fetch("error_kind")
      refute_includes err, NOTICE
      assert_empty idempotent_tasks(project_root)
    end
  end

  private

  def with_initialized_project(runtime: true)
    Hive::Workflows::Project.reset!
    with_tmp_global_config(runtime: runtime) do
      with_tmp_git_repo do |project_root|
        capture_io do
          Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call
        end
        yield project_root, File.basename(project_root)
      end
    end
  ensure
    Hive::Workflows::Project.reset!
  end

  def receipts_installed?
    Hive::CommandOperation.receipts_installed?(Hive::CommandReceiptStore.new)
  end

  def enable_command_receipts!(project_root)
    database = Hive::RuntimeControlPlane.database.open!
    Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
      database: database, package_coordinates: TEST_PACKAGE
    )
    path = File.join(project_root, ".hive-state", "config.yml")
    config = YAML.safe_load_file(path) || {}
    config["command_receipts"] ||= {}
    config["command_receipts"]["keyed_intake_enabled"] = true
    File.write(path, config.to_yaml)
  end

  def run_keyed(project, text, key:, slug: nil)
    with_captured_exit do
      Hive::Commands::New.new(project, text, slug_override: slug, idempotency_key: key, json: true).call
    end
  end

  def assert_valid_hive_new(payload)
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-new"))))
    assert_empty schemer.validate(payload).to_a
  end

  def idempotent_tasks(project_root)
    Dir.glob(File.join(project_root, ".hive-state", "stages", "*", "*", "meta.yml")).select do |path|
      Hive::TaskMeta.read(File.dirname(path))[:idempotency_key]
    end
  end

  def with_captured_exit
    out_pipe = StringIO.new
    err_pipe = StringIO.new
    real_stdout = $stdout
    real_stderr = $stderr
    $stdout = out_pipe
    $stderr = err_pipe
    status = 0
    begin
      yield
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = real_stdout
      $stderr = real_stderr
    end
    [ out_pipe.string, err_pipe.string, status ]
  end
end
