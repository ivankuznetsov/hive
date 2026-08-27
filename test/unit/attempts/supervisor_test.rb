require "test_helper"
require "timeout"
require "hive/attempts/diagnostic_channel"
require "hive/attempts/supervisor"
require "hive/patrol_fix/attempt_diagnostic"
require "hive/task_resolver"

class AttemptsSupervisorTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64

  def test_claims_before_worker_and_writes_failed_receipt_with_ordered_output
    worker_argv = [ "/bin/sh", "-c", "printf out; printf err >&2; exit 7" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      ready_r, ready_w = IO.pipe
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        ready_io: ready_w, heartbeat_sec: 0.01, stale_sec: 1,
        first_heartbeat_timeout_sec: 1
      )

      exit_status = supervisor.run
      ready_w.close unless ready_w.closed?
      readiness = JSON.parse(ready_r.read)
      terminal = store.fetch(attempt.attempt_id)

      assert_equal true, readiness["claimed"]
      assert_equal 7, exit_status
      assert_equal "terminal", terminal.state
      assert_equal "failed", terminal.outcome
      assert_equal 7, terminal.receipt.fetch("exit_status")
      frames = Hive::Attempts::StreamLog.read(File.join(store.root, terminal.receipt.dig("log_reference", "path")))
      assert_equal %w[err out], frames.map(&:bytes).sort
      assert terminal["worker"].fetch("pid").positive?
    ensure
      ready_r&.close unless ready_r&.closed?
    end
  end

  def test_timeout_is_terminal_cancelled_and_kills_worker_group
    worker_argv = [ "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      heartbeat_count = 0
      heartbeat = store.method(:heartbeat)
      store.define_singleton_method(:heartbeat) do |*args, **kwargs|
        heartbeat_count += 1
        heartbeat.call(*args, **kwargs)
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        timeout_sec: 0.2, kill_grace_sec: 0.15
      )
      term_heartbeat_count = nil
      signal_worker_group = supervisor.method(:signal_worker_group)
      supervisor.define_singleton_method(:signal_worker_group) do |signal|
        term_heartbeat_count = heartbeat_count if signal == "TERM"
        signal_worker_group.call(signal)
      end

      assert_equal 124, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "cancelled", terminal.outcome
      assert_equal 124, terminal.receipt.fetch("exit_status")
      refute_nil term_heartbeat_count
      assert_operator heartbeat_count, :>, term_heartbeat_count,
                      "heartbeat must continue throughout TERM-to-KILL grace"
    end
  end

  def test_clean_leader_exit_terminates_a_lingering_descendant_group
    worker_argv = [ "/bin/sh", "-c", "(sleep 10) & exit 0" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        kill_grace_sec: 0.2
      )

      assert_equal 0, Timeout.timeout(2) { supervisor.run }
      assert_equal "succeeded", store.fetch(attempt.attempt_id).outcome
    end
  end

  def test_hive_worker_receives_capability_context_only_after_durable_checkpoint
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      worker = <<~'RUBY'
        context = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_CONTEXT_FD")), "r")
        gate = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_GATE_FD")), "r")
        abort "invalid capability" unless context.read == "c" * 64
        abort "gate not released" unless gate.read(1) == "1"
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 0, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      assert terminal.worker.fetch("pid").positive?
    end
  end

  def test_explicit_worker_safe_evidence_pipe_binds_signal_to_failed_terminal_receipt
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(worker_argv: worker_argv, routing: explicit_routing) do |store, attempt|
      signal = {
        "failure_class" => "model_capacity",
        "scope" => {
          "kind" => "model", "provider_account_id" => "account-a", "model" => "model-a"
        },
        "provenance" => "codex_jsonl_transport",
        "reset_hint_seconds" => 30
      }
      worker = <<~RUBY
        evidence = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_EVIDENCE_FD")), "w")
        evidence.write(#{JSON.generate("#{JSON.generate(signal)}\n")})
        evidence.close
        puts "raw-provider-message=secret-canary"
        exit 0
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal Hive::ExitCodes::SOFTWARE, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "failed", terminal.outcome
      assert_equal "model_capacity", terminal.receipt.dig("provider_evidence", "failure_class")
      assert_equal terminal.receipt.fetch("log_reference"),
                   terminal.receipt.dig("provider_evidence", "source_reference")
      refute_includes JSON.generate(terminal.receipt), "secret-canary"
    end
  end

  def test_provider_signal_owns_missing_frame_patrol_diagnostic
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, routing: explicit_routing,
      intended_stage: "2-fix", workflow_controller: :patrol_fix
    ) do |store, attempt|
      signal = {
        "failure_class" => "model_capacity",
        "scope" => {
          "kind" => "model", "provider_account_id" => "account-a", "model" => "model-a"
        },
        "provenance" => "codex_jsonl_transport",
        "reset_hint_seconds" => 30
      }
      worker = <<~RUBY
        evidence = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_EVIDENCE_FD")), "w")
        evidence.write(#{JSON.generate("#{JSON.generate(signal)}\n")})
        evidence.close
        exit 0
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal Hive::ExitCodes::SOFTWARE, Timeout.timeout(2) { supervisor.run }
      diagnostic = diagnostic_from_terminal(store, store.fetch(attempt.attempt_id))
      assert_equal "model_capacity", diagnostic.fetch("code")
      assert_equal "provider", diagnostic.fetch("owner")
      assert_equal "codex", diagnostic.dig("provider", "name")
      assert_equal "model_capacity", diagnostic.dig("provider", "failure_class")
      assert_equal "codex_jsonl_transport", diagnostic.dig("provider", "provenance")
      assert_equal "30", diagnostic.dig("provider", "retry_hint")
      assert_equal "missing", diagnostic.fetch("transport_status")
    end
  end

  def test_failed_bench_publish_does_not_receive_a_patrol_diagnostic
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "5-publish",
      workflow_controller: :benchmark
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", "exit 7" ]
      end

      assert_equal 7, Timeout.timeout(2) { supervisor.run }
      assert_empty store.fetch(attempt.attempt_id).receipt.fetch("output_references")
    end
  end

  def test_failed_patrol_inbox_receives_a_bound_diagnostic
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "1-inbox",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", "exit 8" ]
      end

      assert_equal 8, Timeout.timeout(2) { supervisor.run }
      diagnostic = diagnostic_from_terminal(store, store.fetch(attempt.attempt_id))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal "1-inbox", diagnostic.fetch("stage")
    end
  end

  def test_patrol_diagnostic_pipe_binds_one_artifact_and_exact_log_to_terminal_receipt
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
        {
          "status" => "error", "exit_code" => 7, "timed_out" => false,
          "cancelled" => false, "signal" => nil,
          "report_status" => "unknown", "firewall_status" => "clean",
          "custody_status" => "clean", "detail" => "agent exited without a report"
        },
        stage: "4-review",
        task_generation: attempt.task_generation,
        attempt_id: attempt.attempt_id,
        recorded_at: NOW
      )
      secret = "github" + "_pat_" + ("A" * 24)
      draft = draft.merge("detail" => "\e[31magent failed #{secret}")
      worker = <<~RUBY
        diagnostic = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_DIAGNOSTIC_FD")), "w")
        diagnostic.write(#{JSON.generate("#{JSON.generate(draft)}\n")})
        diagnostic.close
        warn "private provider body"
        exit 7
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 7, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      references = terminal.receipt.fetch("output_references")
      assert_equal 1, references.length
      reference = references.fetch(0)
      assert Hive::Attempts::OutputReference.verify(reference, root: store.root)
      diagnostic = JSON.parse(File.binread(File.join(store.root, reference.fetch("path"))))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal attempt.attempt_id, diagnostic.fetch("correlation_id")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
      assert_equal "malformed", diagnostic.fetch("transport_status")
      assert_nil diagnostic.fetch("detail")
      refute_includes JSON.generate(diagnostic), secret
      refute_includes JSON.generate(diagnostic), "\e[31m"
      refute_includes JSON.generate(diagnostic), "private provider body"
    end
  end

  def test_diagnostic_pipe_is_single_frame_bounded_and_fails_closed
    assert_operator Hive::Attempts::DiagnosticChannel::MAX_FRAME_BYTES, :<, 4_096

    missing = Hive::Attempts::DiagnosticChannel.read(StringIO.new(""))
    assert_nil missing.document
    assert_equal "missing", missing.status

    malformed = Hive::Attempts::DiagnosticChannel.read(StringIO.new("{\n"))
    assert_nil malformed.document
    assert_equal "malformed", malformed.status

    duplicate = Hive::Attempts::DiagnosticChannel.read(StringIO.new("{}\n{}\n"))
    assert_nil duplicate.document
    assert_equal "duplicate", duplicate.status

    oversized = Hive::Attempts::DiagnosticChannel.read(
      StringIO.new("x" * (Hive::Attempts::DiagnosticChannel::MAX_FRAME_BYTES + 1))
    )
    assert_nil oversized.document
    assert_equal "oversized", oversized.status
  end

  def test_diagnostic_channel_contains_writer_and_reader_io_failures
    writer = Hive::Attempts::DiagnosticChannel::Writer.new(StringIO.new)
    with_replaced_singleton_method(
      Hive::PatrolFix::AttemptDiagnostic, :validate!, ->(*, **) { true }
    ) do
      assert_raises(IOError) do
        writer.write("detail" => "x" * Hive::Attempts::DiagnosticChannel::MAX_FRAME_BYTES)
      end
    end

    broken_close = Object.new
    broken_close.define_singleton_method(:closed?) { false }
    broken_close.define_singleton_method(:close) { raise IOError }
    refute Hive::Attempts::DiagnosticChannel::Writer.new(broken_close).close

    unavailable = Object.new
    unavailable.define_singleton_method(:read) { |_limit| raise IOError }
    unavailable.define_singleton_method(:closed?) { false }
    unavailable.define_singleton_method(:close) { @closed = true }
    result = Hive::Attempts::DiagnosticChannel.read(unavailable)
    assert_equal "unavailable", result.status
    assert_nil result.document
  end

  def test_supervisor_finalizes_valid_frames_and_synthesizes_identity_mismatches
    with_attempt(
      worker_argv: [ "hive", "run", "durable-task" ], intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |_store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: Object.new, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), clock: -> { NOW }
      )
      log_reference = {
        "path" => "logs/attempt-1.frames", "size" => 12, "sha256" => "a" * 64
      }
      draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", "exit_code" => 7 },
        stage: "4-review", task_generation: attempt.task_generation,
        attempt_id: attempt.attempt_id, recorded_at: NOW
      )
      frame = Hive::Attempts::DiagnosticChannel::ReadResult.new(
        document: draft, status: "valid"
      )

      finalized = supervisor.send(
        :finalize_or_synthesize_diagnostic, attempt, frame,
        log_reference: log_reference, exit_status: 7, outcome: "failed",
        transport_status: "valid"
      )
      assert_equal "valid", finalized.fetch("transport_status")
      assert_equal log_reference, finalized.fetch("log_reference")

      mismatched = frame.with(document: draft.merge(
        "attempt_id" => "other-attempt", "correlation_id" => "other-attempt"
      ))
      fallback = supervisor.send(
        :finalize_or_synthesize_diagnostic, attempt, mismatched,
        log_reference: log_reference, exit_status: 7, outcome: "failed",
        transport_status: "valid"
      )
      assert_equal "malformed", fallback.fetch("transport_status")
      assert_equal attempt.attempt_id, fallback.fetch("attempt_id")
    end
  end

  def test_existing_diagnostic_collision_is_read_with_a_strict_bound_and_no_symlinks
    with_tmp_dir do |root|
      path = File.join(root, Hive::PatrolFix::AttemptDiagnostic::FILENAME)
      supervisor = Hive::Attempts::Supervisor.new(
        store: Object.new, attempt_id: "attempt-1",
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      File.binwrite(
        path, "x" * (Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES + 1)
      )
      error = assert_raises(Hive::Attempts::StoreError) do
        supervisor.send(:persist_diagnostic_once, path, {})
      end
      assert_match(/size limit/, error.message)

      target = File.join(root, "target")
      File.binwrite(target, "{}")
      File.unlink(path)
      File.symlink(target, path)
      assert_raises(Hive::Attempts::StoreError) do
        supervisor.send(:persist_diagnostic_once, path, {})
      end
    end
  end

  def test_existing_diagnostic_reconciliation_accepts_exact_bytes_and_rejects_other_shapes
    with_tmp_dir do |root|
      supervisor = Hive::Attempts::Supervisor.new(
        store: Object.new, attempt_id: "attempt-1",
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      log_reference = {
        "path" => "logs/attempt-1.frames", "size" => 12, "sha256" => "a" * 64
      }
      document = Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", "exit_code" => 1 },
        stage: "4-review", task_generation: "generation-1",
        attempt_id: "attempt-1", recorded_at: NOW, log_reference: log_reference
      )
      path = File.join(root, Hive::PatrolFix::AttemptDiagnostic::FILENAME)

      assert supervisor.send(:persist_diagnostic_once, path, document)
      assert supervisor.send(:persist_diagnostic_once, path, document)
      conflict = document.merge("recorded_at" => (NOW + 1).iso8601(6))
      assert_raises(Hive::Attempts::StoreError) do
        supervisor.send(:persist_diagnostic_once, path, conflict)
      end
      assert_raises(Hive::Attempts::StoreError) do
        supervisor.send(:persist_diagnostic_once, File.join(root, "missing", "diagnostic"), document)
      end

      fake_status = Object.new
      fake_status.define_singleton_method(:file?) { false }
      fake_status.define_singleton_method(:nlink) { 1 }
      fake_status.define_singleton_method(:size) { 0 }
      fake_file = Object.new
      fake_file.define_singleton_method(:stat) { fake_status }
      with_replaced_singleton_method(File, :open, ->(*_args, &block) { block.call(fake_file) }) do
        assert_raises(Hive::Attempts::StoreError) do
          supervisor.send(:read_existing_diagnostic, path)
        end
      end

      fake_status.define_singleton_method(:file?) { true }
      fake_status.define_singleton_method(:size) do
        Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES
      end
      fake_file.define_singleton_method(:read) do |_limit|
        "x" * (Hive::PatrolFix::AttemptDiagnostic::MAX_BYTES + 1)
      end
      with_replaced_singleton_method(File, :open, ->(*_args, &block) { block.call(fake_file) }) do
        error = assert_raises(Hive::Attempts::StoreError) do
          supervisor.send(:read_existing_diagnostic, path)
        end
        assert_match(/size limit/, error.message)
      end
    end
  end

  def test_failed_patrol_attempt_synthesizes_bound_diagnostic_when_frame_is_malformed
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      worker = <<~'RUBY'
        diagnostic = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_DIAGNOSTIC_FD")), "w")
        diagnostic.write("{malformed\n")
        diagnostic.close
        exit 9
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 9, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      references = terminal.receipt.fetch("output_references")
      assert_equal 1, references.length
      diagnostic = JSON.parse(File.binread(File.join(store.root, references.fetch(0).fetch("path"))))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal "malformed", diagnostic.fetch("transport_status")
      assert_equal attempt.task_generation, diagnostic.fetch("task_generation")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_secret_bearing_metadata_frame_is_replaced_by_safe_fallback
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
        {
          "status" => "error", "exit_code" => 9,
          "provider" => "codex", "provider_failure" => "provider_error",
          "provider_provenance" => "codex_jsonl_transport"
        },
        stage: "4-review", task_generation: attempt.task_generation,
        attempt_id: attempt.attempt_id, recorded_at: NOW
      )
      secret = "github" + "_pat_" + ("A" * 24)
      draft = JSON.parse(JSON.generate(draft))
      draft.fetch("provider")["provenance"] = secret
      worker = <<~RUBY
        diagnostic = IO.for_fd(Integer(ENV.fetch("HIVE_ATTEMPT_DIAGNOSTIC_FD")), "w")
        diagnostic.write(#{JSON.generate("#{JSON.generate(draft)}\n")})
        diagnostic.close
        exit 9
      RUBY
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", worker ]
      end

      assert_equal 9, Timeout.timeout(2) { supervisor.run }
      diagnostic = diagnostic_from_terminal(store, store.fetch(attempt.attempt_id))
      assert_equal "malformed", diagnostic.fetch("transport_status")
      assert_nil diagnostic.fetch("provider")
      refute_includes JSON.generate(diagnostic), secret
    end
  end

  def test_cancelled_patrol_attempt_synthesizes_diagnostic_when_frame_is_missing
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        timeout_sec: 0.03, kill_grace_sec: 0.03
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", "sleep 10" ]
      end

      assert_equal 124, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      references = terminal.receipt.fetch("output_references")
      assert_equal 1, references.length
      diagnostic = JSON.parse(File.binread(File.join(store.root, references.fetch(0).fetch("path"))))
      assert_equal "agent_timeout", diagnostic.fetch("code")
      assert_equal true, diagnostic.fetch("timed_out")
      assert_equal true, diagnostic.fetch("cancelled")
      assert_equal "missing", diagnostic.fetch("transport_status")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_signalled_patrol_attempt_synthesizes_artifact_and_log_reference
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "2-fix",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", 'Process.kill("KILL", Process.pid)' ]
      end

      assert_equal 137, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      diagnostic = diagnostic_from_terminal(store, terminal)
      assert_equal "agent_signalled", diagnostic.fetch("code")
      assert_equal "KILL", diagnostic.fetch("signal")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_cancel_signal_synthesizes_cancelled_artifact_and_log_reference
    worker_argv = [ "hive", "run", "durable-task" ]
    with_attempt(
      worker_argv: worker_argv, intended_stage: "2-fix",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), heartbeat_sec: 0.01,
        stale_sec: 1, first_heartbeat_timeout_sec: 1, kill_grace_sec: 0.03
      )
      supervisor.define_singleton_method(:resolved_worker_argv) do |_record|
        [ RbConfig.ruby, "-e", "sleep 10" ]
      end
      supervisor.instance_variable_set(:@cancel_reason, :signal)
      supervisor.instance_variable_set(:@cancel_signal, "TERM")

      assert_equal 143, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      diagnostic = diagnostic_from_terminal(store, terminal)
      assert_equal "agent_cancelled", diagnostic.fetch("code")
      assert_equal true, diagnostic.fetch("cancelled")
      assert_equal "TERM", diagnostic.fetch("signal")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_timeout_and_heartbeat_continue_while_descendant_holds_output_pipe
    worker_argv = [
      "/bin/sh", "-c",
      "(trap '' TERM; exec sleep 10) & printf 'leader-exited\\n'; exit 0"
    ]
    with_attempt(worker_argv: worker_argv) do |store, attempt|
      heartbeat_count = 0
      heartbeat = store.method(:heartbeat)
      store.define_singleton_method(:heartbeat) do |*args, **kwargs|
        heartbeat_count += 1
        heartbeat.call(*args, **kwargs)
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        timeout_sec: 0.05, kill_grace_sec: 0.1
      )

      assert_equal 124, Timeout.timeout(2) { supervisor.run }
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "cancelled", terminal.outcome
      assert_operator heartbeat_count, :>, 0
      frames = Hive::Attempts::StreamLog.read(
        File.join(store.root, terminal.receipt.dig("log_reference", "path"))
      )
      assert_includes frames.map(&:bytes).join, "leader-exited"
    end
  end

  def test_lost_claim_exits_without_starting_worker
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      store.mark_lost(attempt, reason: "launch_timeout", now: NOW + 2)
      sentinel = File.join(store.root, "worker-started")
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY),
        first_heartbeat_timeout_sec: 1
      )

      assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
      refute File.exist?(sentinel)
      assert_equal "lost", store.fetch(attempt.attempt_id).state
    end
  end

  def test_compare_and_swap_failure_reports_temporary_failure
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      ready = StringIO.new
      store.define_singleton_method(:claim) { |*_args, **_kwargs| raise Hive::Attempts::CompareAndSwapFailed, "lost" }
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), ready_io: ready
      )

      assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
      assert_includes ready.string, "lost"
    end
  end

  def test_invalid_capability_cannot_claim_or_start_the_recorded_worker
    with_tmp_dir do |root|
      sentinel = File.join(root, "worker-started")
      with_attempt(worker_argv: [ "/bin/sh", "-c", "touch #{sentinel}" ]) do |store, attempt|
        supervisor = Hive::Attempts::Supervisor.new(
          store: store, attempt_id: attempt.attempt_id,
          claim_io: StringIO.new("f" * 64)
        )

        assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
        refute File.exist?(sentinel)
        refute store.fetch(attempt.attempt_id).claimed?
      end
    end
  end

  def test_unexpected_running_failure_writes_a_failed_receipt
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      ready = StringIO.new
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY), ready_io: ready
      )
      supervisor.define_singleton_method(:run_worker) { |_record, _log| raise "boom" }

      assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "terminal", terminal.state
      assert_equal "failed", terminal.outcome
      assert_includes ready.string, '"claimed":true'
    end
  end

  def test_unexpected_patrol_supervisor_failure_still_binds_synthetic_diagnostic
    with_attempt(
      worker_argv: [ "hive", "run", "durable-task" ], intended_stage: "4-review",
      workflow_controller: :patrol_fix
    ) do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      supervisor.define_singleton_method(:run_worker) { |_record, _log| raise "boom" }

      assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      reference = terminal.receipt.fetch("output_references").fetch(0)
      diagnostic = JSON.parse(File.binread(File.join(store.root, reference.fetch("path"))))
      assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
      assert_equal "missing", diagnostic.fetch("transport_status")
      assert_equal terminal.receipt.fetch("log_reference"), diagnostic.fetch("log_reference")
    end
  end

  def test_secondary_failure_during_unexpected_error_is_contained
    with_attempt(worker_argv: [ "/bin/true" ]) do |store, attempt|
      original_fetch = store.method(:fetch)
      fetches = 0
      store.define_singleton_method(:fetch) do |attempt_id|
        fetches += 1
        raise "store unavailable" if fetches > 1

        original_fetch.call(attempt_id)
      end
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new(CLAIM_CAPABILITY)
      )
      supervisor.define_singleton_method(:run_worker) { |_record, _log| raise "boom" }

      assert_equal Hive::ExitCodes::SOFTWARE, supervisor.run
    end
  end

  def test_private_process_and_stream_helpers_cover_race_paths
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt", claim_io: StringIO.new(CLAIM_CAPABILITY),
      kill_grace_sec: 0, monotonic: -> { 1.0 }
    )

    wait_io = Struct.new(:closed?) do
      def read_nonblock(*_args, **_kwargs) = :wait_readable
      def close = nil
    end.new(false)
    readers = { wait_io => :stdout }
    supervisor.send(:drain_reader, wait_io, readers, Object.new)
    assert_equal({ wait_io => :stdout }, readers)

    broken_io = Struct.new(:closed?) do
      def read_nonblock(*_args, **_kwargs) = raise(IOError)
      def close = nil
    end.new(false)
    readers = { broken_io => :stderr }
    supervisor.send(:drain_reader, broken_io, readers, Object.new)
    assert_empty readers

    status = Struct.new(:exited?, :termsig).new(false, 9)
    assert_equal 137, supervisor.send(:status_exit, status)
    assert_equal Hive::ExitCodes::SOFTWARE, supervisor.send(:status_exit, nil)
    record = { "worker_argv" => [ "hive", "run", "task" ] }
    assert_equal RbConfig.ruby, supervisor.send(:resolved_worker_argv, record).first

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { raise Errno::ESRCH }) do
      assert_raises(Hive::Attempts::StoreError) { supervisor.send(:process_identity, 99) }
    end
  end

  def test_worker_termination_escalation_and_signal_setup_are_defensive
    ticks = [ 0.0, 0.0, 0.0, 0.01 ]
    supervisor = Hive::Attempts::Supervisor.new(
      store: Object.new, attempt_id: "attempt", claim_io: StringIO.new(CLAIM_CAPABILITY),
      kill_grace_sec: 0.01, monotonic: -> { ticks.shift || 0.01 }
    )
    supervisor.instance_variable_set(:@worker_pid, 456)
    signals = []
    sleeps = []
    supervisor.define_singleton_method(:signal_worker_group) { |signal| signals << signal }
    supervisor.define_singleton_method(:sleep) { |seconds| sleeps << seconds }
    status = Struct.new(:last).new(:killed)
    waits = [ nil, nil, status ]
    with_replaced_singleton_method(Process, :wait2, ->(*_args) { waits.shift }) do
      assert_equal :killed, supervisor.send(:terminate_worker_group)
    end
    assert_equal %w[TERM KILL], signals
    refute_empty sleeps

    with_replaced_singleton_method(Process, :wait2, ->(*_args) { raise Errno::ECHILD }) do
      assert_nil supervisor.send(:terminate_worker_group)
    end

    trapped = {}
    with_replaced_singleton_method(Signal, :trap, ->(signal, &block) { trapped[signal] = block }) do
      supervisor.send(:install_signal_handlers!)
    end
    assert_equal %w[INT TERM], trapped.keys.sort
    trapped.fetch("TERM").call
    assert_equal "TERM", supervisor.instance_variable_get(:@cancel_signal)
    assert_equal :signal, supervisor.instance_variable_get(:@cancel_reason)

    ready = Object.new
    ready.define_singleton_method(:closed?) { false }
    ready.define_singleton_method(:write) { |_bytes| raise Errno::EPIPE }
    supervisor.instance_variable_set(:@ready_io, ready)
    supervisor.send(:signal_ready, "claimed" => true)
    assert_equal true, supervisor.instance_variable_get(:@ready_sent)

    supervisor.singleton_class.send(:remove_method, :signal_worker_group)
    supervisor.instance_variable_set(:@worker_pgid, 456)
    with_replaced_singleton_method(Process, :getpgid, ->(_pid) { 999 }) do
      assert_raises(Hive::Attempts::StoreError) { supervisor.send(:signal_worker_group, "TERM") }
    end
    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      refute supervisor.send(:signal_recorded_worker_group, "TERM")
    end
    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert_raises(Hive::Attempts::StoreError) do
        supervisor.send(:signal_recorded_worker_group, "TERM")
      end
      assert supervisor.send(:recorded_worker_group_alive?)
    end

    unreadable = Object.new
    unreadable.define_singleton_method(:read) { |_limit| raise IOError }
    supervisor.instance_variable_set(:@claim_io, unreadable)
    assert_nil supervisor.send(:read_claim_capability)
  end

  private

  def diagnostic_from_terminal(store, terminal)
    reference = terminal.receipt.fetch("output_references").find do |candidate|
      File.basename(candidate.fetch("path")) == Hive::PatrolFix::AttemptDiagnostic::FILENAME
    end
    JSON.parse(File.binread(File.join(store.root, reference.fetch("path"))))
  end

  def with_attempt(worker_argv:, routing: { "mode" => "legacy" }, intended_stage: "4-execute",
                   workflow_controller: nil)
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      attempt = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "durable-task",
        intended_stage: intended_stage, task_generation: "generation-1",
        progress_token: "progress-1", provider: "codex", worker_argv: worker_argv,
        claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY), starting_revision: nil,
        retry_charge: 0, inherited_outputs: [], routing: routing,
        launch_timeout_sec: 30, now: Time.now.utc
      )
      unless workflow_controller
        yield store, attempt
        next
      end

      workflow = Struct.new(:controller).new(workflow_controller)
      task = Struct.new(:workflow).new(workflow)
      resolver = Object.new
      resolver.define_singleton_method(:resolve) { task }
      with_replaced_singleton_method(
        Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }
      ) { yield store, attempt }
    end
  end

  def explicit_routing
    account_scope = {
      "kind" => "provider_account", "provider_account_id" => "account-a", "model" => nil
    }
    model_scope = {
      "kind" => "model", "provider_account_id" => "account-a", "model" => "model-a"
    }
    {
      "mode" => "explicit", "policy_digest" => "a" * 64,
      "decision" => {
        "decision_id" => "decision-1", "policy_digest" => "a" * 64,
        "decided_at" => Time.now.utc.iso8601(6), "exclusions" => []
      },
      "route" => {
        "route_id" => "account-a/model-a", "provider_account_id" => "account-a",
        "adapter" => "codex", "launch_binding_id" => "default",
        "model" => "model-a", "effort" => "high"
      },
      "circuit_generations" => [
        { "scope" => account_scope, "journal_epoch" => 0, "observed_generation" => 0 },
        { "scope" => model_scope, "journal_epoch" => 0, "observed_generation" => 0 }
      ],
      "probe_bindings" => []
    }
  end
end
