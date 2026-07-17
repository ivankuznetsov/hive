require "test_helper"
require "hive/attempts/client"
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
    lost_store = Struct.new(:logs_root) do
      define_method(:fetch) { |_id| lost }
    end.new(Dir.tmpdir)
    result = Hive::Attempts::Client.new(store: lost_store).attach("lost")
    assert_equal :lost, result.status
    assert_equal Hive::ExitCodes::TEMPFAIL, result.exit_status

    missing_store = Struct.new(:logs_root) do
      define_method(:fetch) { |_id| nil }
    end.new(Dir.tmpdir)
    assert_raises(Hive::Attempts::StoreError) do
      Hive::Attempts::Client.new(store: missing_store).attach("missing")
    end

    interrupted_store = Struct.new(:logs_root) do
      define_method(:fetch) { |_id| raise Interrupt }
    end.new(Dir.tmpdir)
    detached = Hive::Attempts::Client.new(store: interrupted_store).attach("running")
    assert_equal :detached, detached.status
  end

  def test_running_attachment_polls_before_terminal
    terminal = Struct.new(:state, :receipt).new(
      "terminal", { "exit_status" => 0, "outcome" => "succeeded" }
    )
    records = [ Struct.new(:state).new("running"), terminal ]
    store = Struct.new(:logs_root) do
      define_method(:fetch) { |_id| records.shift }
    end.new(Dir.tmpdir)
    result = Hive::Attempts::Client.new(store: store, poll_interval: 0).attach("attempt")
    assert_equal :terminal, result.status
  end

  private

  def with_terminal_attempt
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
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
