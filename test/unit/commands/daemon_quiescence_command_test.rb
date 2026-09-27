require "test_helper"
require "hive/commands/daemon"
require "hive/daemon/quiescence"
require "json_schemer"

class HiveCommandsDaemonQuiescenceCommandTest < Minitest::Test
  include HiveTestHelper

  def test_quiesce_success_emits_the_strict_paused_envelope
    with_tmp_dir do |root|
      captured_timeout = nil
      factory = lambda do |timeout_sec:|
        captured_timeout = timeout_sec
        fixed_controller(paused_result)
      end
      command = Hive::Commands::Daemon.new(
        "quiesce", json: true, timeout: 12.5, hive_home: root,
        quiescence_factory: factory
      )

      output, _errors = capture_io { assert_equal 0, command.call }
      payload = JSON.parse(output)

      assert_equal 12.5, captured_timeout
      assert_equal "hive-daemon-quiesce", payload.fetch("schema")
      assert_equal "paused", payload.fetch("result")
      assert_equal true, payload.fetch("paused")
      assert_equal true, payload.fetch("ok")
      refute payload.key?("resume_required")
      assert_schema("hive-daemon-quiesce", payload)
    end
  end

  def test_closed_nonpaused_quiesce_requires_explicit_resume_and_tempfails
    with_tmp_dir do |root|
      factory = ->(timeout_sec:) { fixed_controller(nonpaused_result(admission_open: false)) }
      command = Hive::Commands::Daemon.new(
        "quiesce", json: true, hive_home: root, quiescence_factory: factory
      )

      output, _errors = capture_io do
        error = assert_raises(Hive::Error) { command.call }
        assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
      end
      payload = JSON.parse(output)

      assert_equal false, payload.fetch("paused")
      assert_equal true, payload.fetch("resume_required")
      assert_equal "hive daemon resume", payload.fetch("resume_command")
      assert_schema("hive-daemon-quiesce", payload)
    end
  end

  def test_open_precheck_refusal_omits_resume_obligation
    with_tmp_dir do |root|
      factory = ->(timeout_sec:) { fixed_controller(nonpaused_result(admission_open: true)) }
      command = Hive::Commands::Daemon.new(
        "quiesce", json: true, hive_home: root, quiescence_factory: factory
      )

      output, _errors = capture_io { assert_raises(Hive::Error) { command.call } }
      payload = JSON.parse(output)

      assert_equal "ownership_unverifiable", payload.fetch("reason")
      assert_equal true, payload.fetch("admission_open")
      refute payload.key?("resume_required")
      refute payload.key?("resume_command")
      assert_schema("hive-daemon-quiesce", payload)
    end
  end

  def test_unknown_admission_storage_failure_does_not_invent_a_resume_obligation
    with_tmp_dir do |root|
      result = nonpaused_result(admission_open: nil).with(
        reason: "storage_error", phase: "unknown", generation: nil
      )
      command = Hive::Commands::Daemon.new(
        "quiesce", json: true, hive_home: root,
        quiescence_factory: ->(timeout_sec:) { fixed_controller(result) }
      )

      output, _errors = capture_io { assert_raises(Hive::Error) { command.call } }
      payload = JSON.parse(output)
      assert_nil payload.fetch("admission_open")
      refute payload.key?("resume_required")
      assert_schema("hive-daemon-quiesce", payload)
    end
  end

  def test_invalid_timeout_emits_usage_without_constructing_a_controller
    with_tmp_dir do |root|
      constructed = false
      factory = lambda do |timeout_sec:|
        constructed = true
        fixed_controller(paused_result)
      end
      command = Hive::Commands::Daemon.new(
        "quiesce", json: true, timeout: 0, hive_home: root,
        quiescence_factory: factory
      )

      output, _errors = capture_io do
        error = assert_raises(Hive::UsageError) { command.call }
        assert_equal Hive::ExitCodes::USAGE, error.exit_code
      end
      payload = JSON.parse(output)

      refute constructed
      assert_equal "hive-daemon-quiesce", payload.fetch("schema")
      assert_equal "usage", payload.fetch("error_kind")
      assert_schema("hive-daemon-quiesce", payload)
    end
  end

  def test_resume_uses_the_fixed_600_second_default
    with_tmp_dir do |root|
      captured_timeout = nil
      command = Hive::Commands::Daemon.new(
        "resume", json: true, hive_home: root,
        resume_factory: lambda { |timeout_sec:|
          captured_timeout = timeout_sec
          fixed_controller(resumed_result)
        }
      )

      output, _errors = capture_io { assert_equal 0, command.call }

      assert_equal 600.0, captured_timeout
      assert_schema("hive-daemon-resume", JSON.parse(output))
    end
  end

  def test_nonfinite_timeout_is_rejected_for_both_lifecycle_actions
    %w[quiesce resume].each do |action|
      with_tmp_dir do |root|
        constructed = false
        factory = lambda do |timeout_sec:|
          constructed = true
          fixed_controller(action == "quiesce" ? paused_result : resumed_result)
        end
        options = {
          json: true, timeout: Float::INFINITY, hive_home: root
        }
        options[action == "quiesce" ? :quiescence_factory : :resume_factory] = factory
        command = Hive::Commands::Daemon.new(action, **options)

        output, _errors = capture_io { assert_raises(Hive::UsageError) { command.call } }

        refute constructed
        assert_equal "usage", JSON.parse(output).fetch("error_kind")
      end
    end
  end

  def test_resume_reports_admission_and_service_restoration_separately
    with_tmp_dir do |root|
      result = Hive::Daemon::ResumeResult.new(
        status: "partially_resumed", resumed: false, reason: "service_restore_failed",
        phase: "running", admission_open: true, admission_reopened: true,
        generation: 3, lifecycle_revision: 8, reconciled_attempt_ids: [],
        remaining: [], services: [ { "service_identity" => "hive-web", "ok" => false } ],
        details: {}
      )
      command = Hive::Commands::Daemon.new(
        "resume", json: true, hive_home: root,
        resume_factory: ->(timeout_sec:) { fixed_controller(result) }
      )

      output, _errors = capture_io do
        error = assert_raises(Hive::Error) { command.call }
        assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
      end
      payload = JSON.parse(output)

      assert_equal "partially_resumed", payload.fetch("result")
      assert_equal true, payload.fetch("admission_reopened")
      assert_equal false, payload.fetch("resumed")
      assert_schema("hive-daemon-resume", payload)
    end
  end

  def test_controller_busy_quiesce_uses_tempfail_and_preserves_open_admission
    with_tmp_dir do |root|
      result = nonpaused_result(admission_open: true).with(reason: "controller_busy")
      command = Hive::Commands::Daemon.new(
        "quiesce", json: true, hive_home: root,
        quiescence_factory: ->(timeout_sec:) { fixed_controller(result) }
      )

      output, _errors = capture_io do
        error = assert_raises(Hive::Error) { command.call }
        assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
      end
      payload = JSON.parse(output)
      assert_equal "controller_busy", payload.fetch("reason")
      assert_equal true, payload.fetch("admission_open")
      refute payload.key?("resume_required")
      assert_schema("hive-daemon-quiesce", payload)
    end
  end

  def test_storage_result_preserves_software_exit_convention
    with_tmp_dir do |root|
      result = nonpaused_result(admission_open: false).with(reason: "storage_error")
      command = Hive::Commands::Daemon.new(
        "quiesce", json: true, hive_home: root,
        quiescence_factory: ->(timeout_sec:) { fixed_controller(result) }
      )

      output, _errors = capture_io do
        error = assert_raises(Hive::Error) { command.call }
        assert_equal Hive::ExitCodes::SOFTWARE, error.exit_code
      end
      payload = JSON.parse(output)
      assert_equal "storage_error", payload.fetch("reason")
      assert_equal true, payload.fetch("resume_required")
      assert_schema("hive-daemon-quiesce", payload)
    end
  end

  def test_resume_storage_failure_preserves_software_exit_convention
    with_tmp_dir do |root|
      result = resumed_result.with(
        status: "not_resumed", resumed: false, reason: "storage_error",
        admission_open: false, admission_reopened: false, phase: "resuming"
      )
      command = Hive::Commands::Daemon.new(
        "resume", json: true, hive_home: root,
        resume_factory: ->(timeout_sec:) { fixed_controller(result) }
      )

      output, _errors = capture_io do
        error = assert_raises(Hive::Error) { command.call }
        assert_equal Hive::ExitCodes::SOFTWARE, error.exit_code
      end
      assert_equal "storage_error", JSON.parse(output).fetch("reason")
    end
  end

  def test_text_lifecycle_results_report_success_failure_and_resume_obligation
    with_tmp_dir do |root|
      success = Hive::Commands::Daemon.new(
        "quiesce", hive_home: root,
        quiescence_factory: ->(timeout_sec:) { fixed_controller(paused_result) }
      )
      output, errors = capture_io { assert_equal 0, success.call }
      assert_includes output, "paused (generation 3)"
      assert_empty errors

      failure = Hive::Commands::Daemon.new(
        "quiesce", hive_home: root,
        quiescence_factory: ->(timeout_sec:) {
          fixed_controller(nonpaused_result(admission_open: false))
        }
      )
      _output, errors = capture_io { assert_raises(Hive::Error) { failure.call } }
      assert_includes errors, "not_paused (ownership_unverifiable)"
      assert_includes errors, "run hive daemon resume"
    end
  end

  def test_migration_race_still_emits_the_action_specific_error_envelope
    with_tmp_dir do |root|
      error = Hive::RuntimeControlPlane::MigrationRequired.new(
        "upgrade required", code: :older_schema,
        action: Hive::RuntimeControlPlane::Database::MIGRATE_ACTION
      )
      controller = Object.new
      controller.define_singleton_method(:call) { raise error }
      command = Hive::Commands::Daemon.new(
        "resume", json: true, hive_home: root,
        resume_factory: ->(timeout_sec:) { controller }
      )

      output, _errors = capture_io do
        raised = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { command.call }
        assert_equal Hive::ExitCodes::CONFIG, raised.exit_code
      end
      payload = JSON.parse(output)
      assert_equal "hive-daemon-resume", payload.fetch("schema")
      assert_equal "migration_required", payload.fetch("error_kind")
      assert_schema("hive-daemon-resume", payload)
    end
  end

  def test_quiescence_schemas_reject_unknown_reasons
    {
      "hive-daemon-quiesce" => paused_result.to_h,
      "hive-daemon-resume" => resumed_result.to_h
    }.each do |name, payload|
      payload = JSON.parse(JSON.generate(payload))
      payload["reason"] = "typo_reason"
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))

      refute_empty schema.validate(payload).to_a, name
    end
  end

  private

  def assert_schema(name, payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(name))))
    assert_empty schema.validate(payload).map { |error| error["error"] }
  end

  def fixed_controller(result)
    Object.new.tap { |controller| controller.define_singleton_method(:call) { result } }
  end

  def paused_result
    Hive::Daemon::QuiescenceResult.new(
      status: "paused", paused: true, reason: nil, phase: "paused",
      admission_open: false, generation: 3, lifecycle_revision: 7,
      interrupted_attempt_ids: [ "attempt-1" ], remaining: [],
      checkpoint: { complete: true, busy: 0, log_frames: 2, checkpointed_frames: 2 },
      proof: { "generation" => 3 }, capability: nil, details: {}
    )
  end

  def nonpaused_result(admission_open:)
    Hive::Daemon::QuiescenceResult.new(
      status: "not_paused", paused: false, reason: "ownership_unverifiable",
      phase: admission_open.nil? ? "unknown" : (admission_open ? "running" : "quiescing"),
      admission_open: admission_open,
      generation: admission_open ? nil : 3, lifecycle_revision: 7,
      interrupted_attempt_ids: [], remaining: [ { "role" => "attempt" } ],
      checkpoint: nil, proof: nil,
      capability: Hive::RuntimeControlPlane::CapabilityVerdict.new(
        eligible: false, reason: "agent_attempt_root", ownership_mode: "unverified",
        disqualifying_inventory: [ { "role" => "attempt" } ]
      ),
      details: {}
    )
  end

  def resumed_result
    Hive::Daemon::ResumeResult.new(
      status: "resumed", resumed: true, reason: nil, phase: "running",
      admission_open: true, admission_reopened: true, generation: 3,
      lifecycle_revision: 8, reconciled_attempt_ids: [], remaining: [],
      services: [], details: {}
    )
  end
end
