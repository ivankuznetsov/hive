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

  class FakeOperationalReader
    attr_reader :calls

    def initialize
      @calls = []
    end

    def shutdown_acknowledgement(expected_daemon:, now:)
      @calls << [ :shutdown, expected_daemon, now ]
      { "child_inventory" => [] }
    end

    def runtime_readiness(now:)
      @calls << [ :runtime, now ]
      true
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

  def test_default_collaborators_delegate_to_daemon_status_and_snapshot
    with_tmp_dir do |hive_home|
      daemon_calls = []
      daemon_constructions = []
      reader = FakeOperationalReader.new
      daemon_command = FakeDaemonCommand.new(daemon_calls)

      with_replaced_singleton_method(
        Hive::Commands::Daemon,
        :new,
        ->(subcommand, hive_home:) {
          daemon_constructions << [ subcommand, hive_home ]
          daemon_command
        }
      ) do
        with_replaced_singleton_method(
          Hive::Daemon::OperationalSnapshot::Reader,
          :new,
          ->(**) { reader }
        ) do
          lifecycle = Hive::Daemon::WriterQuiescence.new(
            operation: "default collaborators",
            hive_home: hive_home
          )
          assert_instance_of(
            Hive::Daemon::StatusReport,
            lifecycle.instance_variable_get(:@status_report)
          )
          lifecycle.instance_variable_get(
            :@daemon_factory
          ).call("stop").call
          identity = { "pid" => 19 }
          now = Time.at(0)
          assert_equal(
            { "child_inventory" => [] },
            lifecycle.instance_variable_get(
              :@shutdown_evidence
            ).call(identity, now: now)
          )
          assert lifecycle.instance_variable_get(
            :@runtime_readiness
          ).call(now: now)
          lifecycle.instance_variable_get(:@sleeper).call(0)
        end
      end

      assert_equal [ :stop ], daemon_calls
      assert_equal [ [ "stop", hive_home ] ], daemon_constructions
      assert_equal(
        [
          [ :shutdown, { "pid" => 19 }, Time.at(0) ],
          [ :runtime, Time.at(0) ]
        ],
        reader.calls
      )
    end
  end

  def test_quiescence_wraps_an_invalid_running_pid
    lifecycle = writer_quiescence(
      status_report: FakeStatusReport.new([
        { running: true, pid: "not-a-pid" }
      ])
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/cannot verify daemon quiescence/, error.message)
    assert_match(/ArgumentError/, error.message)
  end

  def test_restart_wraps_a_missing_command
    lifecycle = writer_quiescence(
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) {
        raise Errno::ENOENT, "synthetic missing command"
      }
    )

    error = assert_raises(Hive::UnavailableError) do
      lifecycle.restart!
    end

    assert_match(/cannot restart daemon/, error.message)
    assert_match(/synthetic missing command/, error.message)
  end

  def test_quiescence_refuses_a_daemon_that_remains_live
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new([]) },
      tree_probe: ->(*) {
        [ process_target(71, pgid: 71, start_time: "daemon-start") ]
      },
      process_alive: ->(*) { true },
      shutdown_evidence: ->(*, **) { shutdown_acknowledgement }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/daemon PID remains live after stop/, error.message)
  end

  def test_quiescence_ignores_malformed_child_process_groups
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new([]) },
      tree_probe: ->(*) {
        [
          process_target(71, pgid: 71, start_time: "daemon-start"),
          process_target(72, pgid: "invalid", start_time: "child-start")
        ]
      },
      process_alive: ->(*) { false },
      captured_process_alive: ->(*) { false },
      process_group_alive: ->(*) {
        flunk "malformed process group must not be probed"
      },
      shutdown_evidence: ->(*, **) { shutdown_acknowledgement }
    )

    assert lifecycle.quiesce!
  end

  def test_quiescence_waits_for_shutdown_evidence_before_timing_out
    now = Time.at(0)
    sleeps = []
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new([]) },
      tree_probe: ->(*) {
        [ process_target(71, pgid: 71, start_time: "daemon-start") ]
      },
      shutdown_evidence: ->(*, **) { nil },
      clock: -> { now },
      sleeper: ->(seconds) {
        sleeps << seconds
        now += 1
      },
      shutdown_evidence_timeout_sec: 0.1
    )

    assert_raises(Hive::ConcurrentRunError) { lifecycle.quiesce! }

    assert_equal [ 0.05 ], sleeps
  end

  def test_quiescence_rejects_a_malformed_shutdown_inventory
    lifecycle = writer_quiescence(
      status_report: running_status,
      daemon_factory: ->(*) { FakeDaemonCommand.new([]) },
      tree_probe: ->(*) {
        [ process_target(71, pgid: 71, start_time: "daemon-start") ]
      },
      shutdown_evidence: ->(*, **) {
        shutdown_acknowledgement([
          {
            "pid" => "invalid",
            "pgid" => 72,
            "start_time" => "late-child"
          }
        ])
      }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/shutdown acknowledgement is malformed/, error.message)
  end

  def test_default_process_group_probe_distinguishes_process_states
    lifecycle = writer_quiescence
    kill_calls = []

    with_replaced_singleton_method(
      Process, :kill, ->(signal, pid) {
        kill_calls << [ signal, pid ]
        1
      }
    ) do
      assert lifecycle.send(:process_group_alive?, "72")
    end
    assert_equal [ [ 0, -72 ] ], kill_calls

    with_replaced_singleton_method(
      Process, :kill, ->(*) { raise Errno::ESRCH }
    ) do
      refute lifecycle.send(:process_group_alive?, 72)
    end

    with_replaced_singleton_method(
      Process, :kill, ->(*) { raise Errno::EPERM }
    ) do
      assert lifecycle.send(:process_group_alive?, 72)
    end
  end

  def test_default_command_runner_returns_the_child_status
    status = writer_quiescence.send(:run_command, [ "/bin/true" ])

    assert_instance_of Process::Status, status
    assert status.success?
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
