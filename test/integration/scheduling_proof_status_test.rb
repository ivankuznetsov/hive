require "test_helper"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/scheduling_proof/snapshot_store"

class SchedulingProofStatusTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 12, 0, 0)

  def test_status_projects_one_shared_task_and_fleet_explanation
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "explain idle capacity").call }
        enable_daemon(dir)
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        snapshot = scheduler_snapshot(project, slug)
        status = status_command(snapshot)

        payload = status.json_payload(Hive::Config.registered_projects)
        task = payload.dig("projects", 0, "tasks", 0)
        proof = task.fetch("scheduling_proof")
        scheduler = payload.fetch("scheduler")

        assert_equal "needs_input", proof.fetch("reason")
        assert_equal NOW.iso8601(6), proof.dig("freshness", "as_of")
        assert_equal "needs_input", scheduler.dig("causal_buckets", 0, "reason")
        assert_equal scheduler.fetch("configured_slots"),
                     scheduler.fetch("used_slots") + scheduler.fetch("unused_slots")
        assert_equal scheduler.fetch("unused_slots"),
                     scheduler.fetch("causal_buckets").sum { |bucket| bucket.fetch("units") }

        schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-status"))))
        assert_empty schemer.validate(payload).to_a

        text, = capture_io { status.render_status_payload(payload) }
        assert_includes text, scheduler.fetch("summary")
        assert_includes text, proof.fetch("summary")
        assert_includes text, proof.dig("action", "text")
      end
    end
  end

  def test_status_correlates_a_live_attempt_as_the_current_slot_owner
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "explain running work").call }
        enable_daemon(dir)
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        snapshot = scheduler_snapshot(project, slug)
        record = live_attempt(project, slug)

        payload = status_command(snapshot, records: [ record ]).json_payload(Hive::Config.registered_projects)

        proof = payload.dig("projects", 0, "tasks", 0, "scheduling_proof")
        assert_equal "execution", proof.fetch("kind")
        assert_equal "attempt-1", proof.dig("attempt", "id")
        assert_equal "attempt-1", payload.dig("scheduler", "owners", 0, "attempt_id")
        assert_equal 1, payload.dig("scheduler", "used_slots")
      end
    end
  end

  def test_status_degrades_when_scheduler_evidence_loading_raises
    snapshot_store = Object.new
    snapshot_store.define_singleton_method(:read) { raise IOError, "snapshot unavailable" }
    status = Hive::Commands::Status.new(clock: -> { NOW }, scheduler_snapshot_store: snapshot_store)

    payload = nil
    _out, err = capture_io { payload = status.json_payload([]) }

    assert_includes err, "scheduler evidence failed"
    assert_equal "accounting_inconsistent", payload.dig("scheduler", "health")
    assert_includes payload.dig("scheduler", "accounting_errors"), "unreadable_attempt_record"
  end

  def test_status_ignores_malformed_prior_fleet_buckets
    snapshot = scheduler_snapshot("demo", "task").merge("fleet" => "malformed")

    payload = status_command(snapshot).json_payload([])

    assert_equal [], payload.dig("scheduler", "prior_causal_buckets")
  end

  private

  def enable_daemon(project_root)
    path = File.join(project_root, ".hive-state", "config.yml")
    config = YAML.safe_load_file(path)
    config["daemon"] ||= {}
    config["daemon"]["enabled"] = true
    File.write(path, YAML.dump(config))
  end

  def scheduler_snapshot(project, slug)
    candidate = {
      "project" => project, "task_slug" => slug, "stage" => "1-inbox",
      "task_generation" => 0, "reason" => "needs_input", "eligible" => false,
      "queue_position" => 1, "observed_at" => NOW.iso8601(6),
      "action" => nil
    }
    {
      "schema" => "hive-scheduler-snapshot", "schema_version" => 1,
      "daemon_instance_id" => "daemon-1", "daemon_state" => "running",
      "heartbeat_at" => NOW.iso8601(6), "poll_interval_sec" => 30,
      "configuration_fingerprint" => "config-1", "tick_health" => "ok",
      "unavailable_live_claims" => [], "tasks" => [ candidate ],
      "fleet" => { "configured_slots" => 3, "owners" => [], "candidates" => [ candidate ] }
    }
  end

  def status_command(snapshot, records: [])
    snapshot_store = Object.new
    snapshot_store.define_singleton_method(:read) do
      Hive::SchedulingProof::SnapshotStore::ReadResult.new(snapshot: snapshot, status: :ok, error: nil)
    end
    attempt_store = Object.new
    attempt_store.define_singleton_method(:scan) do
      Hive::Attempts::Scan.new(records: records, invalid_records: [])
    end
    daemon_report = Object.new
    daemon_report.define_singleton_method(:running_state) { { running: true } }
    Hive::Commands::Status.new(
      clock: -> { NOW }, scheduler_snapshot_store: snapshot_store,
      attempt_store: attempt_store, daemon_status_report: daemon_report
    )
  end

  def live_attempt(project, slug)
    data = {
      "attempt_id" => "attempt-1", "project" => project, "task_slug" => slug,
      "intended_stage" => "1-inbox", "task_input_epoch" => 0,
      "state" => "running", "provider" => "codex", "heartbeat_at" => NOW.iso8601(6),
      "retry_charge" => 0
    }
    Object.new.tap do |record|
      record.define_singleton_method(:live?) { true }
      record.define_singleton_method(:to_h) { data }
    end
  end
end
