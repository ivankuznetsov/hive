require "test_helper"
require "hive/attempts/client"
require "hive/attempts/log_archive"
require "hive/attempts/supervisor"

class AttemptsClientTest < Minitest::Test
  include HiveTestHelper

  def test_attach_replays_channels_and_returns_receipt_status
    with_terminal_attempt do |store, terminal|
      stdout = StringIO.new
      stderr = StringIO.new
      result = Hive::Attempts::Client.new(store: store, poll_interval: 0.001).attach(
        terminal.attempt_id, stdout: stdout, stderr: stderr
      )

      assert_equal "stdout", stdout.string
      assert_equal "stderr", stderr.string
      assert_equal 0, result.exit_status
      assert_equal "succeeded", result.outcome
      assert_equal "stdout".bytesize, result.stdout_bytes
      assert result.stdout_emitted?
    end
  end

  def test_duplicate_clients_are_read_only_and_each_replays_once
    with_terminal_attempt do |store, terminal|
      outputs = 2.times.map do
        io = StringIO.new
        Hive::Attempts::Client.new(store: store, poll_interval: 0.001).attach(
          terminal.attempt_id, stdout: io, stderr: StringIO.new
        )
        io.string
      end
      assert_equal %w[stdout stdout], outputs
      assert_equal "terminal", store.fetch(terminal.attempt_id).state
    end
  end

  def test_lost_unknown_and_interrupted_attachments_are_typed
    lost = Struct.new(:state).new("lost")
    result = Hive::Attempts::Client.new(store: contract_store(lost)).attach("lost")
    assert_equal :lost, result.status
    assert_equal Hive::ExitCodes::TEMPFAIL, result.exit_status

    assert_raises(Hive::Attempts::RepositoryError) do
      Hive::Attempts::Client.new(store: contract_store(nil)).attach("missing")
    end

    interrupted_store = contract_store(Struct.new(:state).new("running"))
    interrupted_store.define_singleton_method(:fetch) { |_id| raise Interrupt }
    detached = Hive::Attempts::Client.new(store: interrupted_store).attach("running")
    assert_equal :detached, detached.status
  end

  def test_running_attachment_polls_before_terminal
    terminal = Struct.new(:state, :receipt).new(
      "terminal", { "exit_status" => 0, "outcome" => "succeeded" }
    )
    records = [ Struct.new(:state).new("running"), terminal ]
    result = Hive::Attempts::Client.new(
      store: contract_store(nil, fetch: ->(_id) { records.shift }), poll_interval: 0
    ).attach("attempt")
    assert_equal :terminal, result.status
    assert_equal 0, result.stdout_bytes
    refute result.stdout_emitted?
  end

  def test_terminal_transition_drains_frames_published_during_receipt_fetch
    with_repository do |store|
      attempt_id = "attempt-tail"
      writer = store.log_archive.open_writer(attempt_id)
      writer.append("stdout", "before-")
      terminal = Struct.new(:state, :receipt).new(
        "terminal", { "exit_status" => 0, "outcome" => "succeeded" }
      )
      store.define_singleton_method(:fetch) do |_id|
        writer.append("stdout", "terminal")
        writer.close
        terminal
      end
      stdout = StringIO.new

      result = Hive::Attempts::Client.new(store: store, poll_interval: 0).attach(
        attempt_id, stdout: stdout, stderr: StringIO.new
      )

      assert_equal "before-terminal", stdout.string
      assert_equal "before-terminal".bytesize, result.stdout_bytes
    ensure
      writer&.close unless writer&.closed?
    end
  end

  def test_expired_output_preserves_terminal_receipt_without_launching
    with_terminal_attempt do |store, terminal|
      store.log_archive.archive(terminal.attempt_id)
      store.log_archive.expire(terminal.attempt_id, now: Time.now.utc)
      store.define_singleton_method(:create_launching) do |**|
        raise "client must not launch to recreate expired output"
      end

      stdout = StringIO.new
      stderr = StringIO.new
      result = Hive::Attempts::Client.new(store: store, poll_interval: 0).attach(
        terminal.attempt_id, stdout: stdout, stderr: stderr
      )

      assert_equal :terminal, result.status
      assert_equal :expired, result.output_status
      assert_equal terminal.receipt, result.receipt
      assert_empty stdout.string
      assert_includes stderr.string, "preserved receipt without rerunning"
    end
  end

  def test_lost_transition_drains_frames_published_during_record_fetch
    with_repository do |store|
      attempt_id = "attempt-lost-tail"
      writer = store.log_archive.open_writer(attempt_id)
      writer.append("stdout", "before-")
      writer.append("stderr", "warning-")
      lost = Struct.new(:state).new("lost")
      store.define_singleton_method(:fetch) do |_id|
        writer.append("stdout", "lost")
        writer.append("stderr", "tail")
        writer.close
        lost
      end
      stdout = StringIO.new
      stderr = StringIO.new

      result = Hive::Attempts::Client.new(store: store, poll_interval: 0).attach(
        attempt_id, stdout: stdout, stderr: stderr
      )

      assert_equal :lost, result.status
      assert_equal "before-lost", stdout.string
      assert_equal "warning-tail", stderr.string
      assert_equal stdout.string.bytesize, result.stdout_bytes
      assert_equal "before-".bytesize + "lost".bytesize, result.stdout_bytes
    ensure
      writer&.close unless writer&.closed?
    end
  end

  # Regression: the client consumes exactly the repository's one log-read
  # contract. A store exposing only `fetch` + `read_log` (no `log_archive`, no
  # `logs_root`) must drive frame replay and availability without any
  # capability sniffing or client-side path resolution.
  def test_client_consumes_the_repository_log_read_contract_without_capability_sniffing
    frames = [
      Hive::Attempts::StreamLog::Frame.new(
        sequence: 1, timestamp: "2026-01-01T00:00:00Z", channel: "stdout", bytes: "stdout"
      )
    ]
    store = contract_store(
      Struct.new(:state, :receipt).new(
        "terminal", { "exit_status" => 0, "outcome" => "succeeded" }
      ),
      read_log_result: lambda { |after_sequence:|
        Hive::Attempts::LogArchive::ReadResult.new(
          frames: after_sequence.zero? ? frames : [],
          availability: :available
        )
      }
    )
    stdout = StringIO.new

    result = Hive::Attempts::Client.new(store: store, poll_interval: 0).attach(
      "attempt-1", stdout: stdout, stderr: StringIO.new
    )

    assert_equal :terminal, result.status
    assert_equal "stdout", stdout.string
    assert_equal "stdout".bytesize, result.stdout_bytes
    refute store.respond_to?(:logs_root)
    refute store.respond_to?(:log_archive)
  end

  def test_repository_read_log_is_the_single_authoritative_contract
    with_repository do |store|
      attempt_id = "attempt-read-log"
      writer = store.log_archive.open_writer(attempt_id)
      writer.append("stdout", "one")
      writer.append("stderr", "two")
      writer.close

      result = store.read_log(attempt_id)
      assert_equal %w[one two], result.frames.map(&:bytes)
      assert_equal :available, result.availability
      tail = store.read_log(attempt_id, after_sequence: 1)
      assert_equal %w[two], tail.frames.map(&:bytes)
      assert_equal :available, tail.availability
    end
  end

  private

  # A store that satisfies only the repository read contract the client is
  # allowed to consume: point fetch plus the single authoritative log read.
  def contract_store(record, fetch: nil, read_log_result: nil)
    store = Object.new
    store.define_singleton_method(:fetch) { |_id| fetch ? fetch.call(_id) : record }
    store.define_singleton_method(:read_log) do |_id, after_sequence: 0|
      if read_log_result
        read_log_result.call(after_sequence: after_sequence)
      else
        Hive::Attempts::LogArchive::ReadResult.new(frames: [], availability: :unavailable)
      end
    end
    store
  end

  def with_repository
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      yield store
    end
  end

  def with_terminal_attempt
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      attempt = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
        task_generation: "generation-1", progress_token: "progress", provider: "codex",
        worker_argv: [ "/bin/sh", "-c", "printf stdout; printf stderr >&2" ],
        claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
        starting_revision: nil, retry_charge: 0, inherited_outputs: [],
        launch_timeout_sec: 30, now: Time.now.utc
      )
      Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        claim_io: StringIO.new("c" * 64),
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1
      ).run
      yield store, store.fetch(attempt.attempt_id)
    end
  end
end
