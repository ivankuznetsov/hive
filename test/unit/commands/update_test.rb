require "test_helper"
require "hive/commands/update"

class UpdateCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeDaemonLifecycle
    attr_reader :calls

    def initialize(was_running: false, quiesce_error: nil, timeline: nil)
      @was_running = was_running
      @quiesce_error = quiesce_error
      @timeline = timeline
      @calls = []
    end

    def quiesce!
      calls << :quiesce
      @timeline << :quiesce if @timeline
      raise @quiesce_error if @quiesce_error

      @was_running
    end

    def restart!
      calls << :restart
      @timeline << :restart if @timeline
    end
  end

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

  def test_brew_dry_run_prints_brew_upgrade
    out = StringIO.new
    Hive::Commands::Update.new(dry_run: true, output: out, channel: "brew").call

    assert_includes out.string, "channel: brew"
    assert_includes out.string, "brew upgrade #{Hive::Commands::Update::BREW_TAP}"
  end

  def test_bash_dry_run_prints_installer
    out = StringIO.new
    Hive::Commands::Update.new(dry_run: true, output: out, channel: "bash").call

    assert_includes out.string, "channel: bash"
    assert_includes out.string, "curl -fsSL"
    assert_includes out.string, "install.sh"
    refute_match(/\|\s*bash/, out.string)
  end

  def test_bash_channel_downloads_installer_before_running
    with_tmp_dir do |dir|
      curl = File.join(dir, "curl")
      File.write(curl, "#!/bin/sh\n")
      FileUtils.chmod(0755, curl)
      captured = nil

      Hive::Commands::Update.new(
        channel: "bash",
        env: { "PATH" => dir },
        candidate_binary_path: -> { "/bin/true" },
        runner: ->(argv) { captured = argv }
      ).call

      assert_equal "bash", captured[0]
      assert_equal "-c", captured[1]
      assert_includes captured[2], "curl -fsSL"
      assert_includes captured[2], '-o "$tmpdir/install.sh"'
      assert_includes captured[2], 'bash "$tmpdir/install.sh"'
      refute_match(/\|\s*bash/, captured[2])
    end
  end

  def test_update_quiesces_a_running_daemon_before_invoking_the_updater_then_restarts
    lifecycle = FakeDaemonLifecycle.new(was_running: true)
    calls = []

    Hive::Commands::Update.new(
      channel: "bash",
      daemon_lifecycle: lifecycle,
      env: { "PATH" => "/bin" },
      candidate_binary_path: -> { "/bin/true" },
      runner: ->(argv) { calls << :updater; argv }
    ).call

    assert_equal [ :quiesce, :updater, :restart ],
                 lifecycle.calls.first(1) + calls + lifecycle.calls.drop(1)
  end

  def test_update_runs_the_candidate_sweep_after_package_replacement_when_daemon_was_stopped
    lifecycle = FakeDaemonLifecycle.new
    calls = []

    Hive::Commands::Update.new(
      channel: "bash",
      daemon_lifecycle: lifecycle,
      env: { "PATH" => "/bin" },
      runner: ->(_argv) { calls << :package_replace; true },
      candidate_binary_path: -> { "/bin/true" },
      candidate_runner: ->(argv) { calls << argv; true }
    ).call

    assert_equal [ :quiesce ], lifecycle.calls
    assert_equal [ :package_replace, [ "/bin/true", "refactor-patrol-migrate-installed" ] ], calls
  end

  def test_update_orders_running_daemon_quiesce_package_replacement_candidate_sweep_then_restart
    timeline = []
    lifecycle = FakeDaemonLifecycle.new(was_running: true, timeline: timeline)

    Hive::Commands::Update.new(
      channel: "bash",
      daemon_lifecycle: lifecycle,
      env: { "PATH" => "/bin" },
      runner: ->(_argv) { timeline << :package_replace; true },
      candidate_binary_path: -> { "/bin/true" },
      candidate_runner: ->(_argv) { timeline << :candidate_sweep; true }
    ).call

    assert_equal [ :quiesce, :restart ], lifecycle.calls
    assert_equal [ :quiesce, :package_replace, :candidate_sweep, :restart ], timeline
  end

  def test_update_restarts_a_previously_running_daemon_when_candidate_sweep_fails
    lifecycle = FakeDaemonLifecycle.new(was_running: true)

    error = assert_raises(Hive::Error) do
      Hive::Commands::Update.new(
        channel: "bash",
        daemon_lifecycle: lifecycle,
        env: { "PATH" => "/bin" },
        runner: ->(_argv) { true },
        candidate_binary_path: -> { "/bin/true" },
        candidate_runner: ->(_argv) { false }
      ).call
    end

    assert_match(/candidate migration command failed/, error.message)
    assert_equal [ :quiesce, :restart ], lifecycle.calls
  end

  def test_update_does_not_invoke_the_updater_when_a_live_writer_cannot_be_quiesced
    error = Hive::ConcurrentRunError.new(
      "live old daemon writer", holder: { pid: 1234 }, lock_path: "/tmp/hive.pid"
    )
    lifecycle = FakeDaemonLifecycle.new(quiesce_error: error)

    assert_raises(Hive::ConcurrentRunError) do
      Hive::Commands::Update.new(
        channel: "bash",
        daemon_lifecycle: lifecycle,
        env: { "PATH" => "/bin" },
        runner: ->(*) { flunk "updater must not run while old writer is live" }
      ).call
    end

    assert_equal [ :quiesce ], lifecycle.calls
  end

  def test_update_does_not_stop_a_daemon_when_the_package_helper_is_unavailable
    lifecycle = FakeDaemonLifecycle.new(was_running: true)

    assert_raises(Hive::UnavailableError) do
      Hive::Commands::Update.new(
        channel: "bash",
        daemon_lifecycle: lifecycle,
        env: { "PATH" => "" },
        runner: ->(*) { flunk "updater must not run without its helper" }
      ).call
    end

    assert_empty lifecycle.calls
  end

  def test_update_leaves_a_stopped_daemon_stopped
    lifecycle = FakeDaemonLifecycle.new

    Hive::Commands::Update.new(
      channel: "bash",
      daemon_lifecycle: lifecycle,
      env: { "PATH" => "/bin" },
      candidate_binary_path: -> { "/bin/true" },
      runner: ->(argv) { argv }
    ).call

    assert_equal [ :quiesce ], lifecycle.calls
  end

  def test_daemon_lifecycle_proves_old_pid_children_and_groups_are_gone_before_update
    calls = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([ { running: true, pid: 71 } ]),
      daemon_factory: ->(_subcommand) { FakeDaemonCommand.new(calls) },
      tree_probe: lambda { |pid|
        [
          { pid: pid, ppid: 1, pgid: 71, start_time: "daemon-start" },
          { pid: 72, ppid: pid, pgid: 72, start_time: "child-start" }
        ]
      },
      process_alive: ->(_pid) { false },
      captured_process_alive: ->(_target) { false },
      process_group_alive: ->(_pgid) { false },
      shutdown_evidence: ->(_identity, now:) { acknowledged_shutdown }
    )

    assert lifecycle.quiesce!
    assert_equal [ :stop ], calls
  end

  def test_daemon_lifecycle_refuses_update_when_a_captured_child_group_remains_live
    calls = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([ { running: true, pid: 71 } ]),
      daemon_factory: ->(_subcommand) { FakeDaemonCommand.new(calls) },
      tree_probe: lambda { |pid|
        [
          { pid: pid, ppid: 1, pgid: 71, start_time: "daemon-start" },
          { pid: 72, ppid: pid, pgid: 72, start_time: "child-start" }
        ]
      },
      process_alive: ->(_pid) { false },
      captured_process_alive: ->(_target) { false },
      process_group_alive: ->(_pgid) { true },
      shutdown_evidence: ->(_identity, now:) { acknowledged_shutdown }
    )

    error = assert_raises(Hive::ConcurrentRunError) { lifecycle.quiesce! }
    assert_match(/child process group remains live/, error.message)
    assert_equal [ :stop ], calls
  end

  def test_daemon_lifecycle_refuses_update_when_final_shutdown_inventory_finds_a_late_child
    calls = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([ { running: true, pid: 71 } ]),
      daemon_factory: ->(_subcommand) { FakeDaemonCommand.new(calls) },
      tree_probe: lambda { |pid|
        [ { pid: pid, ppid: 1, pgid: 71, start_time: "daemon-start" } ]
      },
      process_alive: ->(_pid) { false },
      captured_process_alive: ->(target) { target.fetch(:pid) == 73 },
      process_group_alive: ->(_pgid) { false },
      shutdown_evidence: lambda do |_identity, now:|
        acknowledged_shutdown(
          [ { "pid" => 73, "pgid" => 73, "start_time" => "late-child-start" } ]
        )
      end
    )

    error = assert_raises(Hive::ConcurrentRunError) { lifecycle.quiesce! }
    assert_match(/supervised daemon child remains live/, error.message)
    assert_equal [ :stop ], calls
  end

  def test_daemon_lifecycle_refuses_update_without_daemon_shutdown_acknowledgement
    calls = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([ { running: true, pid: 71 } ]),
      daemon_factory: ->(_subcommand) { FakeDaemonCommand.new(calls) },
      tree_probe: lambda { |pid|
        [ { pid: pid, ppid: 1, pgid: 71, start_time: "daemon-start" } ]
      },
      process_alive: ->(_pid) { false },
      captured_process_alive: ->(_target) { false },
      process_group_alive: ->(_pgid) { false },
      shutdown_evidence: ->(_identity, now:) { nil },
      shutdown_evidence_timeout_sec: 0
    )

    error = assert_raises(Hive::ConcurrentRunError) { lifecycle.quiesce! }
    assert_match(/did not acknowledge admission closure/, error.message)
    assert_match(/daemon may now be stopped/, error.message)
    assert_match(/hive daemon status --json/, error.message)
    assert_match(/hive daemon start --detach/, error.message)
    assert_equal [ :stop ], calls
  end

  def test_daemon_lifecycle_restarts_through_the_post_update_binary
    with_tmp_dir do |dir|
      binary = File.join(dir, "hive")
      File.write(binary, "#!/bin/sh\n")
      FileUtils.chmod(0o755, binary)
      calls = []
      status = FakeStatusReport.new([
        { running: false, pid: nil },
        { running: true, pid: 99 }
      ])
      lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
        hive_home: dir,
        status_report: status,
        binary_path: -> { binary },
        command_runner: ->(argv) { calls << argv; true },
        sleeper: ->(*) { }
      )

      assert lifecycle.restart!
      assert_equal [ [ binary, "daemon", "start", "--detach" ] ], calls
    end
  end

  def test_daemon_lifecycle_default_collaborators_are_executable
    with_tmp_dir do |dir|
      lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
        hive_home: dir
      )

      daemon = lifecycle.instance_variable_get(:@daemon_factory).call(
        "stop"
      )
      assert_instance_of Hive::Commands::Daemon, daemon
      assert_nil lifecycle.instance_variable_get(
        :@shutdown_evidence
      ).call(
        Hive::Daemon::OperationalSnapshot.daemon_identity(
          pid: Process.pid,
          process_start_time: "test-start"
        ),
        now: Time.now.utc
      )
      assert_equal 0,
                   lifecycle.instance_variable_get(:@sleeper).call(0)
    end
  end

  def test_daemon_lifecycle_rejects_missing_or_unbound_tree_evidence
    missing = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([
        { running: true, pid: 71 }
      ]),
      tree_probe: ->(_pid) { nil }
    )
    error = assert_raises(Hive::ConcurrentRunError) do
      missing.quiesce!
    end
    assert_match(/cannot capture the running daemon/, error.message)

    unbound = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([
        { running: true, pid: 71 }
      ]),
      tree_probe: lambda do |pid|
        [
          {
            pid: pid,
            ppid: 1,
            pgid: pid,
            start_time: ""
          }
        ]
      end
    )
    error = assert_raises(Hive::ConcurrentRunError) do
      unbound.quiesce!
    end
    assert_match(/cannot bind shutdown acknowledgement/, error.message)
  end

  def test_daemon_lifecycle_wraps_malformed_running_state
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([
        { running: true, pid: "not-an-integer" }
      ])
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/cannot verify daemon quiescence/, error.message)
    assert_match(/ArgumentError/, error.message)
  end

  def test_daemon_lifecycle_rejects_a_daemon_pid_that_remains_live
    calls = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([
        { running: true, pid: 71 }
      ]),
      daemon_factory: ->(_subcommand) {
        FakeDaemonCommand.new(calls)
      },
      tree_probe: lambda do |pid|
        [
          {
            pid: pid,
            ppid: 1,
            pgid: pid,
            start_time: "daemon-start"
          }
        ]
      end,
      process_alive: ->(_pid) { true },
      shutdown_evidence: ->(_identity, now:) {
        acknowledged_shutdown
      }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/daemon PID remains live/, error.message)
    assert_equal [ :stop ], calls
  end

  def test_daemon_lifecycle_ignores_malformed_child_process_groups
    calls = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([
        { running: true, pid: 71 }
      ]),
      daemon_factory: ->(_subcommand) {
        FakeDaemonCommand.new(calls)
      },
      tree_probe: lambda do |pid|
        [
          {
            pid: pid,
            ppid: 1,
            pgid: pid,
            start_time: "daemon-start"
          },
          {
            pid: 72,
            ppid: pid,
            pgid: "not-an-integer",
            start_time: "child-start"
          }
        ]
      end,
      process_alive: ->(_pid) { false },
      captured_process_alive: ->(_target) { false },
      process_group_alive: ->(_pgid) {
        flunk "malformed group must not be probed"
      },
      shutdown_evidence: ->(_identity, now:) {
        acknowledged_shutdown
      }
    )

    assert lifecycle.quiesce!
    assert_equal [ :stop ], calls
  end

  def test_daemon_lifecycle_waits_for_a_delayed_shutdown_acknowledgement
    calls = []
    evidence_calls = 0
    clock_value = 0
    sleeps = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([
        { running: true, pid: 71 }
      ]),
      daemon_factory: ->(_subcommand) {
        FakeDaemonCommand.new(calls)
      },
      tree_probe: lambda do |pid|
        [
          {
            pid: pid,
            ppid: 1,
            pgid: pid,
            start_time: "daemon-start"
          }
        ]
      end,
      process_alive: ->(_pid) { false },
      captured_process_alive: ->(_target) { false },
      process_group_alive: ->(_pgid) { false },
      shutdown_evidence: lambda do |_identity, now:|
        now
        evidence_calls += 1
        evidence_calls == 1 ? nil : acknowledged_shutdown
      end,
      clock: -> {
        value = Time.at(clock_value).utc
        clock_value += 1
        value
      },
      sleeper: ->(seconds) { sleeps << seconds },
      shutdown_evidence_timeout_sec: 10
    )

    assert lifecycle.quiesce!
    assert_equal 2, evidence_calls
    assert_equal [ 0.05 ], sleeps
  end

  def test_daemon_lifecycle_rejects_malformed_shutdown_inventory
    calls = []
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new(
      hive_home: "/tmp/hive-update-lifecycle",
      status_report: FakeStatusReport.new([
        { running: true, pid: 71 }
      ]),
      daemon_factory: ->(_subcommand) {
        FakeDaemonCommand.new(calls)
      },
      tree_probe: lambda do |pid|
        [
          {
            pid: pid,
            ppid: 1,
            pgid: pid,
            start_time: "daemon-start"
          }
        ]
      end,
      shutdown_evidence: ->(_identity, now:) {
        acknowledged_shutdown([
          {
            "pid" => "bad",
            "pgid" => 72,
            "start_time" => "child-start"
          }
        ])
      }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/shutdown acknowledgement is malformed/, error.message)
  end

  def test_daemon_lifecycle_restart_reports_every_failure_mode
    missing = Hive::Commands::Update::DaemonLifecycle.new(
      binary_path: -> { nil }
    )
    error = assert_raises(Hive::UnavailableError) do
      missing.restart!
    end
    assert_match(/binary is unavailable/, error.message)

    failed = Hive::Commands::Update::DaemonLifecycle.new(
      binary_path: -> { "/bin/true" },
      command_runner: ->(_argv) { false }
    )
    error = assert_raises(Hive::Error) { failed.restart! }
    assert_match(/start command failed/, error.message)

    timed_out = Hive::Commands::Update::DaemonLifecycle.new(
      status_report: FakeStatusReport.new([]),
      binary_path: -> { "/bin/true" },
      command_runner: ->(_argv) { true },
      restart_timeout_sec: 0
    )
    error = assert_raises(Hive::Error) { timed_out.restart! }
    assert_match(/did not become running/, error.message)

    missing_command = Hive::Commands::Update::DaemonLifecycle.new(
      binary_path: -> { "/bin/true" },
      command_runner: ->(_argv) {
        raise Errno::ENOENT, "candidate disappeared"
      }
    )
    error = assert_raises(Hive::UnavailableError) do
      missing_command.restart!
    end
    assert_match(/candidate disappeared/, error.message)
  end

  def test_daemon_lifecycle_default_process_helpers_cover_kernel_results
    lifecycle = Hive::Commands::Update::DaemonLifecycle.new

    alive = with_replaced_singleton_method(
      Process,
      :kill,
      ->(_signal, _pid) { true }
    ) { lifecycle.send(:process_group_alive?, 71) }
    assert alive
    gone = with_replaced_singleton_method(
      Process,
      :kill,
      ->(_signal, _pid) { raise Errno::ESRCH, "gone" }
    ) { lifecycle.send(:process_group_alive?, 71) }
    refute gone
    hidden = with_replaced_singleton_method(
      Process,
      :kill,
      ->(_signal, _pid) { raise Errno::EPERM, "hidden" }
    ) { lifecycle.send(:process_group_alive?, 71) }
    assert hidden

    assert_predicate lifecycle.send(
      :run_command,
      [ "/bin/true" ]
    ), :success?
  end

  def test_updater_and_candidate_failures_are_actionable
    with_tmp_dir do |dir|
      brew = File.join(dir, "brew")
      File.write(brew, "#!/bin/sh\n")
      FileUtils.chmod(0o755, brew)
      lifecycle = FakeDaemonLifecycle.new

      error = assert_raises(Hive::Error) do
        Hive::Commands::Update.new(
          channel: "brew",
          env: { "PATH" => dir },
          daemon_lifecycle: lifecycle,
          runner: ->(_argv) { false }
        ).call
      end
      assert_match(/updater command failed/, error.message)
    end

    missing = Hive::Commands::Update.new(
      candidate_binary_path: -> { nil }
    )
    error = assert_raises(Hive::UnavailableError) do
      missing.send(:invoke_candidate_migration!)
    end
    assert_match(/candidate migration.*binary is unavailable/,
                 error.message)

    disappeared = Hive::Commands::Update.new(
      candidate_binary_path: -> { "/bin/true" },
      candidate_runner: ->(_argv) {
        raise Errno::ENOENT, "candidate disappeared"
      }
    )
    error = assert_raises(Hive::UnavailableError) do
      disappeared.send(:invoke_candidate_migration!)
    end
    assert_match(/candidate disappeared/, error.message)
  end

  def test_bash_channel_preserves_prefix_from_install_marker
    with_xdg_home do |dir|
      prefix = File.join(dir, "prefix")
      marker_home = Hive::Paths.data_home
      FileUtils.mkdir_p(marker_home)
      File.write(File.join(marker_home, "install-channel"), "bash\n")
      File.write(File.join(marker_home, "install-prefix"), "#{prefix}\n")
      curl = File.join(dir, "curl")
      File.write(curl, "#!/bin/sh\n")
      FileUtils.chmod(0755, curl)
      captured = nil

      Hive::Commands::Update.new(
        env: { "PATH" => dir },
        candidate_binary_path: -> { "/bin/true" },
        runner: ->(argv) { captured = argv }
      ).call

      assert_includes captured[2], "raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh"
      assert_includes captured[2], "--prefix=#{Shellwords.escape(prefix)}"
    end
  end

  def acknowledged_shutdown(child_inventory = [])
    {
      "admission_closed" => true,
      "drained" => true,
      "child_inventory" => child_inventory
    }
  end

  def test_dev_channel_prints_git_guidance
    out = StringIO.new
    Hive::Commands::Update.new(output: out, channel: "dev").call

    assert_includes out.string, "channel: dev"
    assert_includes out.string, "git pull && bundle install"
  end

  def test_aur_uses_yay_when_available
    with_tmp_dir do |dir|
      yay = File.join(dir, "yay")
      File.write(yay, "#!/bin/sh\n")
      FileUtils.chmod(0755, yay)
      captured = nil

      Hive::Commands::Update.new(
        channel: "aur",
        env: { "PATH" => dir },
        candidate_binary_path: -> { "/bin/true" },
        runner: ->(argv) { captured = argv }
      ).call

      assert_equal [ yay, "-Syu", "hive-bin" ], captured
    end
  end

  def test_aur_without_helper_exits_unavailable
    err = assert_raises(Hive::UnavailableError) do
      Hive::Commands::Update.new(channel: "aur", env: { "PATH" => "" }).call
    end
    assert_equal Hive::ExitCodes::UNAVAILABLE, err.exit_code
    assert_match(/install yay or paru/, err.message)
  end

  def test_aur_falls_back_to_paru_when_yay_missing
    with_tmp_dir do |dir|
      paru = File.join(dir, "paru")
      File.write(paru, "#!/bin/sh\n")
      FileUtils.chmod(0755, paru)
      captured = nil

      Hive::Commands::Update.new(
        channel: "aur",
        env: { "PATH" => dir },
        candidate_binary_path: -> { "/bin/true" },
        runner: ->(argv) { captured = argv }
      ).call

      assert_equal [ paru, "-Syu", "hive-bin" ], captured
    end
  end

  def test_unknown_channel_raises_config_error
    err = assert_raises(Hive::ConfigError) do
      Hive::Commands::Update.new(dry_run: true, channel: "tarball").call
    end

    assert_match(/unknown hive install channel \"tarball\"/, err.message)
  end

  def test_runner_enoent_is_wrapped_as_unavailable
    with_tmp_dir do |dir|
      brew = File.join(dir, "brew")
      File.write(brew, "#!/bin/sh\n")
      FileUtils.chmod(0755, brew)

      err = assert_raises(Hive::UnavailableError) do
        Hive::Commands::Update.new(
          channel: "brew",
          env: { "PATH" => dir },
          runner: ->(_argv) { raise Errno::ENOENT, "missing-brew" }
        ).call
      end

      assert_match(/hive update: No such file or directory/, err.message)
      assert_match(/missing-brew/, err.message)
    end
  end

  def test_brew_missing_helper_raises_unavailable
    err = assert_raises(Hive::UnavailableError) do
      Hive::Commands::Update.new(channel: "brew", env: { "PATH" => "" }).call
    end

    assert_match(/required helper 'brew' not found/, err.message)
  end

  def test_bash_missing_curl_raises_unavailable
    err = assert_raises(Hive::UnavailableError) do
      Hive::Commands::Update.new(channel: "bash", env: { "PATH" => "" }).call
    end

    assert_match(/required helper 'curl' not found/, err.message)
  end

  def test_nudge_command_per_channel
    assert_equal "brew upgrade ivankuznetsov/hive/hive", Hive::Commands::Update.nudge_command("brew")
    # aur + bash both nudge `hive update` (aur: paru-vs-yay picked at runtime).
    assert_equal "hive update", Hive::Commands::Update.nudge_command("aur")
    assert_equal "hive update", Hive::Commands::Update.nudge_command("bash")
    assert_nil Hive::Commands::Update.nudge_command("dev")
  end
end
