require "test_helper"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/recoverable_error_healer"
require "hive/daemon/status_consumer"
require "hive/markers"

class DaemonAutoRetryTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 6, 29, 12, 0, 0)
  Row = Hive::Daemon::StatusConsumer::Row

  class FakeStatusConsumer
    attr_accessor :result

    def fetch
      result || Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], projects: [], error: nil)
    end
  end

  class FakeSupervisor
    attr_reader :spawned

    def initialize
      @spawned = []
      @next_pid = 1000
    end

    def reap_all(now: Time.now) = []
    def reap_dry_run(now: Time.now) = []
    def enforce_timeouts(now:) = []
    def terminate_all(grace_sec:) = nil
    def update_timeouts(default_timeout_sec:, verb_timeouts:, kill_grace_sec:) = nil
    def in_flight_count = @spawned.size

    def spawn(command_string:, project:, slug:, stage:, **attrs)
      @spawned << { command: command_string, project: project, slug: slug, stage: stage, attrs: attrs }
      @next_pid += 1
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      unless Hive::Daemon::Logger::EVENTS.include?(name)
        raise ArgumentError, "unknown daemon log event in integration fake: #{name.inspect}"
      end
      @events << [ name, attrs ]
    end

    def close = nil
  end

  class FakeProbe
    attr_accessor :ok
    attr_reader :calls

    def initialize(ok: true)
      @ok = ok
      @calls = []
    end

    def start_tick(_tick) = nil

    def probe(category)
      @calls << category
      { ok: ok, probes: [ { name: "fake", ok: ok } ] }
    end
  end

  class FakeSignal
    attr_accessor :fingerprint

    def initialize
      @fingerprint = "fp-1"
    end

    def fingerprint(**) = @fingerprint

    def changed_or_fallback?(current_fingerprint:, last_fingerprint:, last_attempt_at:, now:)
      last_fingerprint.to_s.empty? || current_fingerprint != last_fingerprint
    end
  end

  def setup
    @status = FakeStatusConsumer.new
    @supervisor = FakeSupervisor.new
    @logger = FakeLogger.new
    @controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 3,
      max_concurrent_per_project: 3,
      max_runs_per_day_per_project: 50
    )
    @probe = FakeProbe.new(ok: true)
    @signal = FakeSignal.new
  end

  def dispatcher(config: { "daemon" => { "auto_retry" => { "enabled" => true }, "poll_interval_sec" => 30 } })
    d = Hive::Daemon::Dispatcher.new(
      config: config,
      controller: @controller,
      supervisor: @supervisor,
      status_consumer: @status,
      logger: @logger
    )
    d.define_singleton_method(:project_enabled?) { |_project| true }
    d.instance_variable_set(
      :@recoverable_error_healer,
      Hive::Daemon::RecoverableErrorHealer.new(
        controller: @controller,
        logger: @logger,
        config: config,
        health_probe: @probe,
        health_signal: @signal
      )
    )
    d
  end

  def with_error_row(attrs:, stage: "4-execute")
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(state_file, :error, attrs)
      row = Row.new(
        project: "p", slug: "auto-retry-task", stage: stage, workflow: "coding",
        marker: "error", marker_attrs: Hive::Markers.current(state_file).attrs,
        folder: dir, state_file: state_file, state_file_mtime: File.mtime(state_file),
        action: "error", suggested_command: nil, claude_pid_alive: nil,
        live_task_lock: nil, diagnostic: nil
      )
      yield row, state_file, dir
    end
  end

  def set_status_rows(rows)
    @status.result = Hive::Daemon::StatusConsumer::Result.new(
      ok: true,
      rows: rows,
      projects: [],
      error: nil
    )
  end

  def stub_safe(value = [ true, "safe" ])
    with_replaced_singleton_method(Hive::Daemon::AutoRetrySafety, :safe_to_retry?, ->(_row) { value }) do
      yield
    end
  end

  # Re-stamp the cleared error marker (legacy no-id, like the dead run would
  # leave), refresh the row's attrs + status payload, and advance the fake
  # health signal so the changed-signal gate re-arms on the next tick.
  def repark(row, state_file, fingerprint:)
    Hive::Markers.set(state_file, :error, row.marker_attrs.merge("marker_id" => nil))
    row.marker_attrs = Hive::Markers.current(state_file).attrs
    set_status_rows([ row ])
    @signal.fingerprint = fingerprint
  end

  # Dispatcher wired with a caller-supplied health probe (e.g. the real
  # HealthProbe) but the fake signal, so the changed-signal gate stays
  # deterministic while the probe runs for real.
  def dispatcher_with_probe(config:, probe:)
    d = dispatcher(config: config)
    d.instance_variable_set(
      :@recoverable_error_healer,
      Hive::Daemon::RecoverableErrorHealer.new(
        controller: @controller,
        logger: @logger,
        config: config,
        health_probe: probe,
        health_signal: @signal
      )
    )
    d
  end

  def test_codex_auth_marker_clears_and_audits_through_dispatcher_tick
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "401 Missing bearer/basic auth"
    }
    with_error_row(attrs: attrs) do |row, state_file, dir|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :none, Hive::Markers.current(state_file).name
      assert_equal [ :codex_auth ], @probe.calls
      assert @logger.events.any? { |name, _attrs| name == :auto_retry }
      event_types = File.readlines(File.join(dir, "events.jsonl"), chomp: true).map { |line| JSON.parse(line).fetch("event_type") }
      assert_includes event_types, "auto_retry"
    end
  end

  def test_unknown_implementer_failure_stays_parked
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "exit_code=1 failing tests"
    }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "unknown_reason" }
    end
  end

  def test_probe_failure_stays_parked_and_audits_skip
    @probe.ok = false
    attrs = { "reason" => "claude_launch_failed" }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe { dispatcher.tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_equal [ :claude_launcher ], @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "probe_failed" }
    end
  end

  def test_dirty_work_area_stays_parked_without_probe
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "401 Missing bearer/basic auth"
    }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe([ false, "worktree dirty" ]) { dispatcher.tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      assert @logger.events.any? { |name, attrs| name == :auto_retry_skipped && attrs[:action] == "unsafe_work_area" }
    end
  end

  # Drives the REAL AutoRetrySafety, HealthSignal, and HealthProbe through the
  # healer (only the probe's shell-outs are stubbed via injected collaborators)
  # so keyword-seam drift between the healer's calls — fingerprint(category:),
  # probe(category) — and the real implementations fails the build instead of
  # passing unnoticed behind FakeProbe/FakeSignal/stub_safe.
  def test_real_collaborators_clear_codex_auth_marker_end_to_end
    real_status = Struct.new(:ok) do
      def success? = ok
      def exitstatus = ok ? 0 : 1
    end
    doctor = Object.new
    doctor.define_singleton_method(:call) { 0 }
    doctor.define_singleton_method(:rows) { [ { status: "present", label: "claude" } ] }
    config = { "daemon" => { "auto_retry" => { "enabled" => true } } }
    probe = Hive::Daemon::HealthProbe.new(
      config: config,
      project_root: nil,
      env: { "CODEX_HOME" => "/tmp/codex-real-collab" },
      doctor_factory: -> { doctor },
      capture3: ->(_env, *_cmd) { [ "ok", "", real_status.new(true) ] },
      timeout_runner: ->(_seconds, &block) { block.call }
    )
    healer = Hive::Daemon::RecoverableErrorHealer.new(
      controller: @controller,
      logger: @logger,
      config: config,
      health_probe: probe,
      health_signal: Hive::Daemon::HealthSignal
    )
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "401 Missing bearer/basic auth"
    }
    # 2-brainstorm with no brainstorm.md keeps real AutoRetrySafety happy
    # without a worktree, exercising the real safety seam too.
    with_error_row(attrs: attrs, stage: "2-brainstorm") do |row, state_file, _dir|
      healer.heal([ row ], now: T0)

      assert_equal :none, Hive::Markers.current(state_file).name
      assert @logger.events.any? { |name, attrs2| name == :auto_retry && attrs2[:action] == "cleared" }
    end
  end

  # AE4 (plan U9): the full retry lifecycle across dispatcher ticks — two
  # clears bounded by MAX_AUTO_RETRIES, the 30-minute backoff that holds the
  # second retry, and the permanent park once the budget is exhausted. The
  # individual gates are unit-tested (recoverable_error_healer_test
  # test_exhausts_after_two_clears / test_second_retry_waits_for_backoff);
  # this drives them together through real Dispatcher#tick calls.
  def test_auto_retry_lifecycle_across_dispatcher_ticks_clears_backs_off_then_parks
    attrs = {
      "reason" => "implementer_failed",
      "provider" => "codex",
      "message" => "401 Missing bearer/basic auth"
    }
    d = dispatcher
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      stub_safe do
        # Tick 1: fresh signal → first clear (attempt 1/2).
        set_status_rows([ row ])
        d.tick(now: T0)
        assert_equal :none, Hive::Markers.current(state_file).name

        # Re-park with a changed signal but still inside the 30-min backoff
        # window → the second retry is held off, not cleared.
        repark(row, state_file, fingerprint: "fp-2")
        d.tick(now: T0 + 60)
        assert_equal :error, Hive::Markers.current(state_file).name
        assert @logger.events.any? { |name, attrs2| name == :auto_retry_skipped && attrs2[:action] == "backoff" }

        # Past the backoff window → second clear (attempt 2/2).
        repark(row, state_file, fingerprint: "fp-3")
        d.tick(now: T0 + 1900)
        assert_equal :none, Hive::Markers.current(state_file).name

        # Budget exhausted (2/2): the marker stays red permanently, with a
        # single exhausted audit no matter how many further ticks observe it.
        repark(row, state_file, fingerprint: "fp-4")
        d.tick(now: T0 + 3800)
        repark(row, state_file, fingerprint: "fp-5")
        d.tick(now: T0 + 5700)
        assert_equal :error, Hive::Markers.current(state_file).name
        assert_equal 1, @logger.events.count { |name, _attrs| name == :auto_retry_exhausted }
      end
    end
  end

  # AE2 (plan U9): a claude_launcher marker clears ONLY when every claude
  # sub-probe passes — the in-process doctor AND the wrapper-file/tmux/version
  # trio. Drives the REAL HealthProbe (only the tmux/version seams stubbed)
  # through Dispatcher#tick so the doctor+wrapper+tmux+version conjunction is
  # exercised end-to-end, not just per-sub-probe at the unit level.
  def test_claude_marker_clears_only_when_doctor_wrapper_tmux_version_all_pass
    attrs = { "reason" => "claude_launch_failed" }
    config = { "daemon" => { "auto_retry" => { "enabled" => true }, "poll_interval_sec" => 30 } }
    profile = Struct.new(:bin, :version) do
      def check_version! = version
    end.new("claude", "2.1.120")
    doctor = Object.new
    doctor.define_singleton_method(:call) { 0 }
    doctor.define_singleton_method(:rows) { [ { status: "present", label: "claude" } ] }
    build_probe = lambda do
      Hive::Daemon::HealthProbe.new(
        config: config,
        project_root: nil,
        doctor_factory: -> { doctor },
        capture3: ->(_env, *_cmd) { raise "claude probes must not shell out via capture3" },
        timeout_runner: ->(_seconds, &block) { block.call }
      )
    end

    # tmux DOWN: the conjunction fails even though doctor + wrapper + version
    # are healthy → the marker stays parked with a probe_failed audit.
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      d = dispatcher_with_probe(config: config, probe: build_probe.call)
      set_status_rows([ row ])
      with_replaced_singleton_method(Hive::ClaudeLauncher, :tmux_status, -> { [ :absent, "no tmux server" ] }) do
        with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(_name, cfg: nil) { profile }) do
          stub_safe { d.tick(now: T0) }
        end
      end

      assert_equal :error, Hive::Markers.current(state_file).name
      skip = @logger.events.find { |name, a| name == :auto_retry_skipped && a[:action] == "probe_failed" }
      assert skip, "expected a probe_failed skip, got: #{@logger.events.inspect}"
      assert_equal :claude_launcher, skip[1][:category]
    end

    # All four sub-probes pass → the marker clears and audits the retry.
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      d = dispatcher_with_probe(config: config, probe: build_probe.call)
      set_status_rows([ row ])
      with_replaced_singleton_method(Hive::ClaudeLauncher, :tmux_status, -> { [ :present, "tmux ok" ] }) do
        with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(_name, cfg: nil) { profile }) do
          stub_safe { d.tick(now: T0) }
        end
      end

      assert_equal :none, Hive::Markers.current(state_file).name
      retry_event = @logger.events.find { |name, _a| name == :auto_retry }
      assert retry_event, "expected an auto_retry clear, got: #{@logger.events.inspect}"
      assert_equal %w[doctor claude_wrapper claude_tmux claude_version],
                   retry_event[1][:probes].map { |p| p[:name] }
    end
  end

  def test_kill_switch_leaves_marker_and_skips_probe_and_audit
    attrs = { "reason" => "claude_launch_failed" }
    config = { "daemon" => { "auto_retry" => { "enabled" => false }, "poll_interval_sec" => 30 } }
    with_error_row(attrs: attrs) do |row, state_file, _dir|
      set_status_rows([ row ])
      stub_safe { dispatcher(config: config).tick(now: T0) }

      assert_equal :error, Hive::Markers.current(state_file).name
      assert_empty @probe.calls
      refute @logger.events.any? { |name, _attrs| %i[auto_retry auto_retry_skipped].include?(name) }
    end
  end
end
