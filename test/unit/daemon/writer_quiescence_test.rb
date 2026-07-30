require "test_helper"
require "hive/daemon/writer_quiescence"

class WriterQuiescenceTest < Minitest::Test
  include HiveTestHelper

  FakeDaemonCommand = Struct.new(:calls) do
    def call
      calls << :stop
    end
  end

  FakeStatusReport = Struct.new(:states) do
    def running_state
      states.shift || { running: false, pid: nil }
    end
  end

  def test_stopped_profile_needs_no_daemon_effect
    lifecycle = writer_quiescence(
      status_report: FakeStatusReport.new([
        { running: false, pid: nil }
      ]),
      daemon_factory: ->(*) { flunk "stopped profile must not stop again" }
    )

    refute lifecycle.quiesce!
  end

  def test_quiescence_binds_shutdown_to_daemon_and_supervised_children
    calls = []
    targets = [
      process_target(71, pgid: 71, start_time: "daemon-start"),
      process_target(72, pgid: 72, start_time: "child-start")
    ]
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new(calls) },
      tree_probe: ->(pid) {
        assert_equal 71, pid
        targets
      },
      process_alive: ->(*) { false },
      captured_process_alive: ->(*) { false },
      process_group_alive: ->(*) { false },
      shutdown_evidence: ->(identity, now:) {
        assert_equal 71, identity.fetch("pid")
        assert_equal "daemon-start",
                     identity.fetch("process_start_time")
        assert_match(/\A[0-9a-f]{64}\z/, identity.fetch("generation"))
        assert_instance_of Time, now
        shutdown_acknowledgement
      }
    )

    assert lifecycle.quiesce!
    assert_equal [ :stop ], calls
  end

  def test_quiescence_refuses_a_live_child_group
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new([]) },
      tree_probe: ->(*) {
        [
          process_target(71, pgid: 71, start_time: "daemon-start"),
          process_target(72, pgid: 72, start_time: "child-start")
        ]
      },
      process_alive: ->(*) { false },
      captured_process_alive: ->(*) { false },
      process_group_alive: ->(pgid) { pgid == 72 },
      shutdown_evidence: ->(*, **) { shutdown_acknowledgement }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/child process group remains live/, error.message)
  end

  def test_quiescence_checks_late_children_from_shutdown_evidence
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new([]) },
      tree_probe: ->(*) {
        [ process_target(71, pgid: 71, start_time: "daemon-start") ]
      },
      process_alive: ->(*) { false },
      captured_process_alive: ->(target) { target.fetch(:pid) == 73 },
      process_group_alive: ->(*) { false },
      shutdown_evidence: ->(*, **) {
        shutdown_acknowledgement([
          {
            "pid" => 73,
            "pgid" => 73,
            "start_time" => "late-child-start"
          }
        ])
      }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/supervised daemon child remains live/, error.message)
  end

  def test_quiescence_refuses_missing_shutdown_acknowledgement_with_recovery
    calls = []
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new(calls) },
      tree_probe: ->(*) {
        [ process_target(71, pgid: 71, start_time: "daemon-start") ]
      },
      shutdown_evidence: ->(*, **) { nil },
      shutdown_evidence_timeout_sec: 0
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/did not acknowledge admission closure/, error.message)
    assert_match(/hive daemon status --json/, error.message)
    assert_match(/hive daemon start --detach/, error.message)
    assert_equal [ :stop ], calls
  end

  def test_quiescence_refuses_missing_or_unbound_process_tree
    missing = writer_quiescence(
      status_report: running_status,
      tree_probe: ->(*) { nil }
    )
    error = assert_raises(Hive::ConcurrentRunError) do
      missing.quiesce!
    end
    assert_match(/cannot capture the running daemon/, error.message)

    unbound = writer_quiescence(
      status_report: running_status,
      tree_probe: ->(*) {
        [ process_target(71, pgid: 71, start_time: "") ]
      }
    )
    error = assert_raises(Hive::ConcurrentRunError) do
      unbound.quiesce!
    end
    assert_match(/cannot bind shutdown acknowledgement/, error.message)
  end

  def test_restart_uses_the_current_invoked_binary_and_waits_for_running
    with_tmp_dir do |dir|
      binary = File.join(dir, "hive")
      File.write(binary, "#!/bin/sh\n")
      FileUtils.chmod(0o755, binary)
      calls = []
      lifecycle = writer_quiescence(
        status_report: FakeStatusReport.new([
          { running: false, pid: nil },
          { running: true, pid: 99 }
        ]),
        binary_path: -> { binary },
        command_runner: ->(argv) {
          calls << argv
          true
        },
        sleeper: ->(*) { }
      )

      assert lifecycle.restart!
      assert_equal(
        [ [ binary, "daemon", "start", "--detach" ] ],
        calls
      )
    end
  end

  def test_restart_reports_missing_failed_and_timed_out_binaries
    missing = writer_quiescence(binary_path: -> { nil })
    error = assert_raises(Hive::UnavailableError) do
      missing.restart!
    end
    assert_match(/binary is unavailable/, error.message)

    failed = writer_quiescence(
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { false }
    )
    error = assert_raises(Hive::Error) { failed.restart! }
    assert_match(/start command failed/, error.message)

    timed_out = writer_quiescence(
      status_report: FakeStatusReport.new([]),
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { true },
      restart_timeout_sec: 0
    )
    error = assert_raises(Hive::Error) { timed_out.restart! }
    assert_match(/did not publish generation-bound/, error.message)
  end

  def test_restart_requires_runtime_readiness_after_pid_liveness
    probes = 0
    lifecycle = writer_quiescence(
      status_report: FakeStatusReport.new([
        { running: true, pid: 99 },
        { running: true, pid: 99 }
      ]),
      runtime_readiness: ->(now:) {
        assert_instance_of Time, now
        probes += 1
        probes > 1
      },
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { true }
    )

    assert lifecycle.restart!
    assert_equal 2, probes
  end

  private

  def writer_quiescence(**options)
    Hive::Daemon::WriterQuiescence.new(
      operation: "hive refactor-patrol-reset",
      hive_home: "/tmp/hive-writer-quiescence-test",
      daemon_factory: ->(*) { FakeDaemonCommand.new([]) },
      status_report: FakeStatusReport.new([
        { running: false, pid: nil }
      ]),
      tree_probe: ->(*) { [] },
      process_alive: ->(*) { false },
      captured_process_alive: ->(*) { false },
      process_group_alive: ->(*) { false },
      shutdown_evidence: ->(*, **) { shutdown_acknowledgement },
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { true },
      runtime_readiness: ->(now:) { !now.nil? },
      sleeper: ->(*) { },
      **options
    )
  end

  def running_status
    FakeStatusReport.new([
      { running: true, pid: 71 }
    ])
  end

  def process_target(pid, pgid:, start_time:)
    {
      pid: pid,
      ppid: 1,
      pgid: pgid,
      start_time: start_time
    }
  end

  def shutdown_acknowledgement(child_inventory = [])
    {
      "admission_closed" => true,
      "drained" => true,
      "child_inventory" => child_inventory
    }
  end
end
