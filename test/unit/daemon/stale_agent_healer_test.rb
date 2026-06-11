require "test_helper"
require "tmpdir"
require "time"
require "hive/markers"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/status_consumer"

# Healer's job: rewrite AGENT_WORKING markers whose backing agent isn't
# alive to ERROR reason=agent_{died,orphaned}. Anything else (live
# agent, in-grace placeholder, in-flight controller slot) it leaves
# alone. These tests pin those branches without bringing up the full
# dispatcher.
class HiveDaemonStaleAgentHealerTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row

  class FakeController
    attr_reader :observed_mtimes

    def initialize(running_pairs: [])
      @running = running_pairs
      @observed_mtimes = []
    end

    def running_task?(project:, slug:)
      @running.include?([ project, slug ])
    end

    def observe_state_file_mtime(project:, slug:, mtime:)
      @observed_mtimes << { project: project, slug: slug, mtime: mtime }
    end
  end

  class FakeLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end

  NOW = Time.utc(2026, 5, 20, 12, 0, 0)

  def setup
    @logger = FakeLogger.new
    @controller = FakeController.new
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller, logger: @logger, grace_sec: 300
    )
  end

  def heal(rows, **opts)
    @healer.heal(rows, now: NOW, **opts)
  end

  def with_marker_file
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "# task\n\n<!-- AGENT_WORKING -->\n")
      yield state_file
    end
  end

  # Realistic default: post-U4, status.rb classifies stale agent_working
  # rows with action="error". The healer keys off row.marker (the
  # on-disk marker name), not row.action, so we use the production-
  # accurate combo by default. Tests can override via the action: kwarg.
  def make_row(state_file, pid_alive:, mtime: NOW - 1000, project: "p", slug: "s", stage: "4-execute",
               marker: "agent_working", marker_attrs: {}, action: "error", live_task_lock: nil)
    Row.new(
      project: project, slug: slug, stage: stage,
      marker: marker, marker_attrs: marker_attrs, folder: File.dirname(state_file), state_file: state_file,
      state_file_mtime: mtime,
      action: action, suggested_command: nil,
      claude_pid_alive: pid_alive, live_task_lock: live_task_lock, diagnostic: nil
    )
  end

  def test_heals_dead_pid_to_agent_died
    with_marker_file do |state_file|
      # Marker had a pid (we don't model it in the row directly; the
      # healer keys off claude_pid_alive, which the status command
      # computes from the .lock file).
      row = make_row(state_file, pid_alive: false)
      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected a marker_healed event, got: #{@logger.events.inspect}"
      assert_equal "agent_died", heal_event[1][:reason]
      assert_match(/ERROR\s+reason=agent_died/, File.read(state_file))
    end
  end

  def test_heals_pidless_placeholder_when_older_than_grace
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil, mtime: NOW - 600)
      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected agent_orphaned heal, got: #{@logger.events.inspect}"
      assert_equal "agent_orphaned", heal_event[1][:reason]
      assert_match(/ERROR\s+reason=agent_orphaned/, File.read(state_file))
    end
  end

  def test_leaves_pidless_placeholder_within_grace
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil, mtime: NOW - 60)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "row inside grace window must not be healed; events: #{@logger.events.inspect}"
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  def test_leaves_live_pid_untouched
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: true)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  # Issue #144: an externally-spawned `hive run` may hold the per-task
  # .lock with a verified PID + process_start_time match while it does
  # pre-stage work (e.g. auto-rebase) — the marker is still AGENT_WORKING
  # and claude_pid_alive is still nil because the runner has not written
  # its claude_pid yet. Without the live_task_lock skip, the healer
  # races the live runner once mtime exceeds grace.
  def test_skips_row_with_live_task_lock_even_when_grace_exceeded
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil, mtime: NOW - 600, live_task_lock: true)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "live_task_lock=true must pre-empt grace-exceeded heal so the healer does not race the live runner; events: #{@logger.events.inspect}"
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  def test_skips_row_with_live_controller_slot
    with_marker_file do |state_file|
      # Even with pid_alive=false, if the controller has a slot for
      # this task, the daemon believes a dispatch is in flight and
      # the healer must defer (the dispatch will rewrite the marker
      # itself when it completes).
      @controller = FakeController.new(running_pairs: [ [ "p", "s" ] ])
      @healer = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300
      )
      row = make_row(state_file, pid_alive: false)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "controller-managed dispatches must not be healed mid-flight"
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  def test_skips_rows_in_half_migrated_projects
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: false)
      heal([ row ], legacy_layout_projects: { "p" => true })

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "half-migrated projects must be left alone — advancing on top of a renamed stage dir would silently lose work"
    end
  end

  def test_skips_rows_whose_marker_is_not_agent_working
    with_marker_file do |state_file|
      # Healer keys off the on-disk marker name. A row whose marker is
      # already something else (review_error, complete, error, etc.)
      # is out of scope — the marker has already moved past
      # AGENT_WORKING and a different recovery affordance applies.
      row = make_row(state_file, pid_alive: false, marker: "review_error", action: "error")
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_heals_wedged_review_working_lock_when_agent_child_is_dead
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: true
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
        with_replaced_singleton_method(@healer, :terminate_lock_holder, ->(_holder) { nil }) do
          heal([ row ])
        end
      end

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected review marker_healed event, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", heal_event[1][:reason]
      assert_equal "reviewers", heal_event[1][:phase]
      assert_equal "1", heal_event[1][:pass]
      refute File.exist?(lock_path), "stale review lock should be removed so recovery can run"
      refute_match(/REVIEW_WORKING|REVIEW_ERROR/, File.read(state_file),
                   "auto-recoverable stale review markers should clear so daemon can retry review")
    end
  end

  def test_review_working_live_lock_with_children_is_left_alone
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=fix pass=2 -->\n")
      File.write(File.join(File.dirname(state_file), ".lock"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "fix", "pass" => "2" },
        action: "agent_running",
        live_task_lock: true
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [ 12_345 ] }) do
        heal([ row ])
      end

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  def test_review_working_heal_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      File.write(File.join(File.dirname(state_file), ".lock"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: true
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, *args|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, *args)
      end

      begin
        with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
          heal([ row ])
        end
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", failure[1][:reason]
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_review_working_skips_when_child_inspection_fails
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      File.write(File.join(File.dirname(state_file), ".lock"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: true
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { nil }) do
        heal([ row ])
      end

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  # Case B: a signal kill (e.g. daemon restart SIGTERM/SIGKILL) tore down
  # the whole review tree, leaving REVIEW_WORKING with a stale .lock whose
  # holder is gone. live_task_lock is false. Past grace, the marker clears
  # and the stale lock is removed so the daemon re-dispatches review.
  def test_heals_orphaned_review_working_when_holder_is_gone_past_grace
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, { "pid" => 999_999, "claude_pid" => 999_998 }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2" },
        action: "agent_running",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected orphaned review heal, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", heal_event[1][:reason]
      assert_equal "triage", heal_event[1][:phase]
      assert_equal "2", heal_event[1][:pass]
      refute File.exist?(lock_path), "stale review lock should be removed so the daemon re-dispatches"
      refute_match(/REVIEW_WORKING|REVIEW_ERROR/, File.read(state_file),
                   "orphaned REVIEW_WORKING should clear so review re-dispatches under the cap")
    end
  end

  def test_heal_still_succeeds_when_stale_lock_cannot_be_deleted
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      FileUtils.mkdir_p(lock_path)
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2" },
        action: "agent_running",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected marker_healed despite undeletable lock, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", heal_event[1][:reason]
      assert File.directory?(lock_path), "undeletable lock residue should be left for a later tick"
      refute_match(/REVIEW_WORKING|REVIEW_ERROR/, File.read(state_file))
    end
  end

  # Case B with no .lock at all (the holder died before/without recording
  # one, or a restart removed it): claude_pid_alive and live_task_lock are
  # both nil. Past grace, still healed; release_task_lock tolerates ENOENT.
  def test_heals_orphaned_review_working_with_no_lock_file
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: nil
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected orphaned review heal with no lock, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", heal_event[1][:reason]
      refute_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  # Guard against racing a runner that just set REVIEW_WORKING but hasn't
  # recorded its lock yet: within the grace window, leave it alone.
  def test_leaves_orphaned_review_working_within_grace
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: NOW - 100,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "a freshly-set REVIEW_WORKING without a recorded lock yet must not be healed within grace"
      assert_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  # Mirror of the Case A failure test for the orphaned (Case B) path: a
  # disk error while clearing the marker must log marker_heal_failed with
  # reason "review_orphaned" and never crash the tick.
  def test_orphaned_review_working_heal_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 -->\n")
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2" },
        action: "agent_running",
        live_task_lock: false
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, *args|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, *args)
      end

      begin
        heal([ row ])
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", failure[1][:reason]
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_auto_recovers_reviewer_partial_failure_when_errors_are_tmux_session_terminated
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      reviews_dir = File.join(File.dirname(state_file), "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(
        File.join(reviews_dir, "errors-01.md"),
        "# Reviewer infra errors for pass 01\n\n" \
        "- [claude-ce-code-review] reviewer \"claude-ce-code-review\" failed: " \
        "tmux_session_terminated before writing expected output file: " \
        "#{File.join(reviews_dir, 'claude-ce-code-review-01.md')} after 2 attempt(s)\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected auto-recovery event, got: #{@logger.events.inspect}"
      assert_equal "reviewer_tmux_session_terminated", heal_event[1][:reason]
      refute_match(/REVIEW_ERROR/, File.read(state_file),
                   "auto-recoverable reviewer tmux death should clear the marker so daemon can retry")
    end
  end

  def test_does_not_auto_recover_reviewer_partial_failure_with_mixed_error_causes
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      reviews_dir = File.join(File.dirname(state_file), "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(
        File.join(reviews_dir, "errors-01.md"),
        "# Reviewer infra errors for pass 01\n\n" \
        "- [claude-ce-code-review] reviewer \"claude-ce-code-review\" failed: " \
        "tmux_session_terminated before writing expected output file: #{File.join(reviews_dir, 'claude.md')}\n" \
        "- [codex-ce-code-review] reviewer \"codex-ce-code-review\" failed: quota exhausted\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_does_not_auto_recover_reviewer_partial_failure_when_errors_file_is_missing
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_reviewer_partial_failure_signature_falls_back_when_errors_file_disappears
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      reviews_dir = File.join(File.dirname(state_file), "reviews")
      FileUtils.mkdir_p(reviews_dir)
      errors_path = File.join(reviews_dir, "errors-01.md")
      File.write(
        errors_path,
        "- [claude-ce-code-review] reviewer \"claude-ce-code-review\" failed: " \
        "tmux_session_terminated before writing expected output file: #{File.join(reviews_dir, 'claude.md')}\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      original = File.method(:read)
      File.define_singleton_method(:read) do |path, *args, **kwargs|
        raise Errno::ENOENT, path if path == errors_path

        original.call(path, *args, **kwargs)
      end

      begin
        heal([ row ])
      ensure
        File.define_singleton_method(:read, &original)
      end

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected auto-recovery event, got: #{@logger.events.inspect}"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_error_review_agent_died
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected review_agent_died auto-recovery event, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", heal_event[1][:reason]
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  # --- limits_reached cooldown auto-retry (review path) ----------------

  def make_review_limit_row(state_file, retry_after:, pass: "1")
    marker_attrs = { "phase" => "reviewers", "reason" => "limits_reached", "pass" => pass }
    marker_attrs["retry_after"] = retry_after unless retry_after.nil?
    make_row(
      state_file,
      pid_alive: nil,
      stage: "6-review",
      marker: "review_error",
      marker_attrs: marker_attrs,
      action: "recover_review",
      live_task_lock: false
    )
  end

  def write_review_limit_marker(state_file, retry_after:)
    attrs = retry_after ? " retry_after=#{retry_after}" : ""
    File.write(state_file,
               "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=limits_reached pass=1#{attrs} -->\n")
  end

  def test_does_not_auto_recover_review_limits_reached_before_cooldown
    with_marker_file do |state_file|
      future = (NOW + 600).iso8601
      write_review_limit_marker(state_file, retry_after: future)
      row = make_review_limit_row(state_file, retry_after: future)

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "limits_reached must stay red until the cooldown elapses"
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_limits_reached_once_cooldown_has_elapsed
    with_marker_file do |state_file|
      past = (NOW - 60).iso8601
      write_review_limit_marker(state_file, retry_after: past)
      row = make_review_limit_row(state_file, retry_after: past)

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected limits_reached auto-recovery, got: #{@logger.events.inspect}"
      assert_equal "reviewer_limits_reached", heal_event[1][:reason]
      assert_equal 1, heal_event[1][:attempts]
      refute_match(/REVIEW_ERROR/, File.read(state_file),
                   "elapsed-cooldown limits_reached must clear so review re-dispatches")
    end
  end

  def test_auto_recovers_review_limits_reached_exactly_at_cooldown_boundary
    with_marker_file do |state_file|
      now_stamp = NOW.iso8601
      write_review_limit_marker(state_file, retry_after: now_stamp)
      row = make_review_limit_row(state_file, retry_after: now_stamp)

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "now == retry_after must be treated as elapsed (>=)"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_does_not_auto_recover_review_limits_reached_without_retry_after
    with_marker_file do |state_file|
      write_review_limit_marker(state_file, retry_after: nil)
      row = make_review_limit_row(state_file, retry_after: nil)

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "a legacy limits_reached marker lacking retry_after must stay manual"
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_does_not_auto_recover_review_limits_reached_with_unparseable_retry_after
    with_marker_file do |state_file|
      write_review_limit_marker(state_file, retry_after: "not-a-timestamp")
      row = make_review_limit_row(state_file, retry_after: "not-a-timestamp")

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "an unparseable retry_after must stay manual, not crash or self-heal"
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_review_limits_reached_cooldown_waits_do_not_burn_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      review_error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      past = (NOW - 60).iso8601
      future = (NOW + 600).iso8601

      # Three early ticks while still inside the cooldown must not consume
      # the single-slot budget.
      3.times do
        write_review_limit_marker(state_file, retry_after: future)
        heal([ make_review_limit_row(state_file, retry_after: future) ])
        assert_match(/REVIEW_ERROR/, File.read(state_file))
      end
      refute @logger.events.any? { |name, _| name == :marker_healed }

      # First post-cooldown tick spends the only budget slot and clears.
      write_review_limit_marker(state_file, retry_after: past)
      heal([ make_review_limit_row(state_file, retry_after: past) ])
      refute_match(/REVIEW_ERROR/, File.read(state_file))

      # Second post-cooldown tick (limit still not cleared) exhausts budget.
      write_review_limit_marker(state_file, retry_after: past)
      heal([ make_review_limit_row(state_file, retry_after: past) ])
      assert_match(/REVIEW_ERROR/, File.read(state_file),
                   "persistently-limited review must stay red once the budget is spent")

      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size, "only the post-cooldown tick should clear"
      assert_equal "reviewer_limits_reached", heals.first[1][:reason]

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, exhausted.size
      assert_equal "reviewer_limits_reached", exhausted.first[1][:reason]
      assert_equal "limits_reached", exhausted.first[1][:marker_reason]
      assert_match(/usage\/credit limit did not clear/, exhausted.first[1][:remediation])
      assert_match(/hive markers clear/, exhausted.first[1][:remediation])
    end
  end

  # --- limits_reached cooldown auto-retry (terminal ERROR path) --------

  def make_error_limit_row(state_file, retry_after:, stage: "4-execute")
    marker_attrs = { "reason" => "limits_reached" }
    marker_attrs["retry_after"] = retry_after unless retry_after.nil?
    make_row(
      state_file,
      pid_alive: nil,
      mtime: NOW - 1000,
      stage: stage,
      marker: "error",
      marker_attrs: marker_attrs,
      action: "error",
      live_task_lock: false
    )
  end

  def write_error_limit_marker(state_file, retry_after:)
    attrs = retry_after ? " retry_after=#{retry_after}" : ""
    File.write(state_file, "# task\n\n<!-- ERROR reason=limits_reached#{attrs} -->\n")
  end

  def test_does_not_auto_recover_error_limits_reached_before_cooldown
    with_marker_file do |state_file|
      future = (NOW + 600).iso8601
      write_error_limit_marker(state_file, retry_after: future)
      row = make_error_limit_row(state_file, retry_after: future)

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "terminal limits_reached must stay red until the cooldown elapses"
      assert_match(/ERROR reason=limits_reached/, File.read(state_file))
    end
  end

  def test_auto_recovers_error_limits_reached_once_cooldown_has_elapsed_any_stage
    %w[1-brainstorm 4-execute 8-finalize].each do |stage|
      with_marker_file do |state_file|
        past = (NOW - 60).iso8601
        write_error_limit_marker(state_file, retry_after: past)
        row = make_error_limit_row(state_file, retry_after: past, stage: stage)

        heal([ row ])

        heal_event = @logger.events.last
        assert_equal :marker_healed, heal_event[0],
                     "#{stage} limits_reached should clear after cooldown"
        assert_equal "limits_reached", heal_event[1][:reason]
        assert_equal "limits_reached", heal_event[1][:marker_reason]
        assert_equal stage, heal_event[1][:stage]
        assert Hive::Markers.current(state_file).none?,
               "#{stage} limits_reached must clear so the daemon re-dispatches"
      end
    end
  end

  def test_does_not_auto_recover_error_limits_reached_without_retry_after
    with_marker_file do |state_file|
      write_error_limit_marker(state_file, retry_after: nil)
      row = make_error_limit_row(state_file, retry_after: nil)

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "a legacy terminal limits_reached marker must stay manual"
      assert_match(/ERROR reason=limits_reached/, File.read(state_file))
    end
  end

  def test_does_not_auto_recover_error_limits_reached_with_unparseable_retry_after
    with_marker_file do |state_file|
      write_error_limit_marker(state_file, retry_after: "garbled")
      row = make_error_limit_row(state_file, retry_after: "garbled")

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert_match(/ERROR reason=limits_reached/, File.read(state_file))
    end
  end

  def test_error_limits_reached_cooldown_waits_do_not_burn_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      future = (NOW + 600).iso8601
      past = (NOW - 60).iso8601

      3.times do
        write_error_limit_marker(state_file, retry_after: future)
        heal([ make_error_limit_row(state_file, retry_after: future) ])
        assert_match(/ERROR reason=limits_reached/, File.read(state_file))
      end
      refute @logger.events.any? { |name, _| name == :marker_healed }

      write_error_limit_marker(state_file, retry_after: past)
      heal([ make_error_limit_row(state_file, retry_after: past) ])
      assert Hive::Markers.current(state_file).none?

      write_error_limit_marker(state_file, retry_after: past)
      heal([ make_error_limit_row(state_file, retry_after: past) ])
      assert_match(/ERROR reason=limits_reached/, File.read(state_file),
                   "persistently-limited task must stay red once the budget is spent")

      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size
      assert_equal "limits_reached", heals.first[1][:reason]

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, exhausted.size
      assert_equal "limits_reached", exhausted.first[1][:reason]
      assert_equal "limits_reached", exhausted.first[1][:marker_reason]
      assert_match(/usage\/credit limit did not clear/, exhausted.first[1][:remediation])
      assert_match(/hive markers clear/, exhausted.first[1][:remediation])
    end
  end

  def test_auto_recovers_finalize_unpushed_commits_error
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits detail=\"push failed\" marker_id=err-a -->\n")
      # Explicit non-default mtime so the observed_mtimes assertion below
      # actually pins that observe_pre_clear_mtime forwards the row's own
      # state_file_mtime — not the make_row default, which would pass even
      # if the pass-through were hard-coded.
      pre_clear_mtime = NOW - 4242
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: pre_clear_mtime,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: {
          "reason" => "unpushed_commits",
          "detail" => "push failed",
          "marker_id" => "err-a"
        },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected finalize unpushed auto-recovery event, got: #{@logger.events.inspect}"
      assert_equal "finalize_unpushed_commits", heal_event[1][:reason]
      assert_equal "unpushed_commits", heal_event[1][:marker_reason]
      assert_equal 1, heal_event[1][:attempts]
      assert_equal [ { project: "p", slug: "s", mtime: pre_clear_mtime } ], @controller.observed_mtimes
      assert Hive::Markers.current(state_file).none?,
             "auto-recoverable unpushed finalize marker should clear to :none so daemon can rerun finalize"
    end
  end

  def test_auto_recovers_terminal_agent_loss_error_matrix
    # Every stage except 6-review: the sweep-kills-the-server incident took
    # out parallel BRAINSTORMS, and a rerun resumes from on-disk artifacts.
    %w[2-brainstorm 3-plan 4-execute 7-artifacts 8-finalize].product(%w[tmux_session_terminated agent_orphaned]).each_with_index do |(stage, reason), index|
      with_marker_file do |state_file|
        marker_id = "terminal-#{index}"
        File.write(state_file, "# task\n\n<!-- ERROR reason=#{reason} marker_id=#{marker_id} -->\n")
        pre_clear_mtime = NOW - 5151 - index
        row = make_row(
          state_file,
          pid_alive: nil,
          mtime: pre_clear_mtime,
          stage: stage,
          marker: "error",
          marker_attrs: { "reason" => reason, "marker_id" => marker_id },
          action: "error",
          live_task_lock: false
        )

        heal([ row ])

        heal_event = @logger.events.last
        assert_equal :marker_healed, heal_event[0]
        assert_equal "terminal_agent_loss", heal_event[1][:reason]
        assert_equal reason, heal_event[1][:marker_reason]
        assert_equal stage, heal_event[1][:stage]
        assert_equal 1, heal_event[1][:attempts]
        assert_equal({ project: "p", slug: "s", mtime: pre_clear_mtime }, @controller.observed_mtimes.last)
        assert Hive::Markers.current(state_file).none?,
               "#{stage}/#{reason} terminal ERROR should clear so the daemon can rerun the stage"
      end
    end
  end

  def test_terminal_agent_loss_recovery_stays_out_of_review
    # 6-review owns its agent-loss healing (REVIEW_ERROR paths); the generic
    # terminal-ERROR clear must not double-handle it.
    %w[tmux_session_terminated agent_orphaned].each do |reason|
      with_marker_file do |state_file|
        File.write(state_file, "# task\n\n<!-- ERROR reason=#{reason} -->\n")
        row = make_row(
          state_file,
          pid_alive: nil,
          stage: "6-review",
          marker: "error",
          marker_attrs: { "reason" => reason },
          action: "error",
          live_task_lock: false
        )

        heal([ row ])

        refute @logger.events.any? { |name, _| name == :marker_healed },
               "6-review/#{reason} must stay with the review-specific heal paths"
        refute @logger.events.any? { |name, _| name == :marker_heal_failed }
        assert_match(/ERROR reason=#{reason}/, File.read(state_file))
      end
    end
  end

  def test_terminal_agent_loss_recovery_uses_marker_id_guard_when_present
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated marker_id=newer -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "older" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=tmux_session_terminated marker_id=newer/, File.read(state_file),
                   "a stale status row must not clear a newer same-reason ERROR marker")
    end
  end

  def test_terminal_agent_loss_recovery_skips_live_lock
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=agent_orphaned -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "agent_orphaned" },
        action: "error",
        live_task_lock: true
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a live-lock skip must be a clean no-op, not a logged failure"
      assert_match(/ERROR reason=agent_orphaned/, File.read(state_file))
    end
  end

  def test_terminal_agent_loss_recovery_does_not_clear_git_status_failed
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=git_status_failed -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "git_status_failed" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a repository-state failure must stay manual, not enter agent-loss retry"
      assert_match(/ERROR reason=git_status_failed/, File.read(state_file))
    end
  end

  def test_terminal_agent_loss_stays_red_after_retry_budget_is_exhausted
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated -->\n")
      heal([ row ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated -->\n")
      heal([ row ])

      assert_match(/ERROR reason=tmux_session_terminated/, File.read(state_file),
                   "same terminal agent loss must stay red after budget exhaustion")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size
      assert_equal "terminal_agent_loss", heals.first[1][:reason]

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, exhausted.size
      assert_equal "terminal_agent_loss", exhausted.first[1][:reason]
      assert_equal "tmux_session_terminated", exhausted.first[1][:marker_reason]
      assert_equal 1, exhausted.first[1][:attempts]
      assert_equal 1, exhausted.first[1][:max_attempts]
      assert_equal "per_process", exhausted.first[1][:budget_scope]
      assert_equal "manual_fix", exhausted.first[1][:suggested_next_action]
      assert_match(/rerun 7-artifacts/, exhausted.first[1][:remediation])
      assert_match(/hive run s --project p --stage 7-artifacts/, exhausted.first[1][:remediation])
      refute_match(/--from/, exhausted.first[1][:remediation])
      assert_match(/no live agent/, exhausted.first[1][:remediation])
    end
  end

  def test_terminal_agent_loss_budget_accumulates_across_fresh_marker_ids
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      first = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "err-a" },
        action: "error",
        live_task_lock: false
      )
      second = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "err-b" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated marker_id=err-a -->\n")
      heal([ first ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated marker_id=err-b -->\n")
      heal([ second ])

      assert_match(/ERROR reason=tmux_session_terminated marker_id=err-b/, File.read(state_file),
                   "retry budget should key on task/stage/reason, not marker_id")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, heals.size
      assert_equal 1, exhausted.size
      assert_equal "terminal_agent_loss", exhausted.first[1][:reason]
      assert_equal "tmux_session_terminated", exhausted.first[1][:marker_reason]
    end
  end

  def test_finalize_unpushed_recovery_uses_marker_id_guard_when_present
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=newer -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: {
          "reason" => "unpushed_commits",
          "marker_id" => "older"
        },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=unpushed_commits marker_id=newer/, File.read(state_file),
                   "a stale status row must not clear a newer same-reason ERROR marker")
    end
  end

  def test_finalize_unpushed_recovery_clears_legacy_marker_without_marker_id
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected legacy finalize marker to clear, got: #{@logger.events.inspect}"
      assert Hive::Markers.current(state_file).none?,
             "legacy no-marker_id finalize marker should clear to :none"
    end
  end

  def test_finalize_unpushed_recovery_does_not_clear_modern_marker_when_row_lacks_marker_id
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=modern -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=unpushed_commits marker_id=modern/, File.read(state_file),
                   "a row without marker_id must not clear a current marker that has one")
    end
  end

  def test_finalize_unpushed_recovery_does_not_clear_marker_that_gains_id_after_snapshot
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=fresh -->\n")
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=unpushed_commits marker_id=fresh/, File.read(state_file),
                   "a legacy row snapshot must not clear a modern marker written before heal")
    end
  end

  def test_finalize_unpushed_recovery_ignores_missing_or_malformed_marker_attrs
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: nil,
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert_match(/ERROR/, File.read(state_file))
    end
  end

  def test_finalize_unpushed_recovery_skips_when_state_file_mtime_is_missing
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert_match(/ERROR reason=unpushed_commits/, File.read(state_file),
                   "without a pre-clear mtime the healer cannot seed redispatch safely")
    end
  end

  def test_does_not_auto_recover_finalize_unpushed_commits_with_live_lock
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: true
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a live-lock skip must be a clean no-op, not a logged failure"
      assert_match(/ERROR reason=unpushed_commits/, File.read(state_file))
    end
  end

  def test_does_not_auto_recover_unpushed_commits_outside_finalize
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a wrong-stage skip must be a clean no-op, not a logged failure"
      assert_match(/ERROR reason=unpushed_commits/, File.read(state_file))
    end
  end

  def test_does_not_auto_recover_manual_clean_exit_failure
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=ensure_clean_on_exit_failed -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "ensure_clean_on_exit_failed" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a wrong-reason (non-recoverable) skip must be a clean no-op, not a logged failure"
      assert_match(/ERROR reason=ensure_clean_on_exit_failed/, File.read(state_file))
    end
  end

  def test_auto_recoverable_finalize_unpushed_commits_stays_red_after_retry_budget_is_exhausted
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      heal([ row ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      heal([ row ])

      assert_match(/ERROR reason=unpushed_commits/, File.read(state_file),
                   "same finalize push failure must stay red after budget exhaustion")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size
      assert_equal 1, heals.first[1][:attempts]
      assert_equal 1, heals.first[1][:max_attempts]

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, exhausted.size
      assert_equal "finalize_unpushed_commits", exhausted.first[1][:reason]
      assert_equal "unpushed_commits", exhausted.first[1][:marker_reason]
      assert_equal 1, exhausted.first[1][:attempts]
      assert_equal 1, exhausted.first[1][:max_attempts]
      assert_equal "per_process", exhausted.first[1][:budget_scope]
      assert_equal "manual_fix", exhausted.first[1][:suggested_next_action]
      assert_match(/rerun finalize/, exhausted.first[1][:remediation],
                   "exhausted event must carry an actionable remediation hint")
      assert_match(/push the branch manually/, exhausted.first[1][:remediation])
    end
  end

  def test_finalize_unpushed_budget_accumulates_across_fresh_marker_ids
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=err-a -->\n")
      first = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "err-a" },
        action: "error",
        live_task_lock: false
      )
      heal([ first ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=err-b -->\n")
      second = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "err-b" },
        action: "error",
        live_task_lock: false
      )
      heal([ second ])

      assert_match(/ERROR reason=unpushed_commits marker_id=err-b/, File.read(state_file),
                   "fresh marker ids from repeated finalize failures must share one recovery budget")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size
      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, exhausted.size
    end
  end

  def test_finalize_unpushed_recovery_budget_is_isolated_per_task
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    Dir.mktmpdir do |dir|
      first_file = File.join(dir, "first.md")
      second_file = File.join(dir, "second.md")
      File.write(first_file, "# first\n\n<!-- ERROR reason=unpushed_commits -->\n")
      File.write(second_file, "# second\n\n<!-- ERROR reason=unpushed_commits -->\n")

      first = make_row(
        first_file,
        pid_alive: nil,
        project: "p",
        slug: "first",
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )
      second = make_row(
        second_file,
        pid_alive: nil,
        project: "p",
        slug: "second",
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ first, second ])

      refute_match(/ERROR/, File.read(first_file))
      refute_match(/ERROR/, File.read(second_file))
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 2, heals.size
      assert_equal %w[first second], heals.map { |_, attrs| attrs[:slug] }.sort
    end
  end

  def test_finalize_unpushed_clear_false_consumes_no_budget_and_emits_no_event
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      # On-disk marker is NEWER than the stale status row's marker_id, so
      # the reason matches but the marker_id guard makes clear_current
      # return false. That branch must be a pure no-op: no event of any
      # kind, and crucially no retry budget consumed.
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=newer -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "older" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      assert_empty @logger.events,
                   "a clear_current=false skip must emit no event at all, got: #{@logger.events.inspect}"
      assert_empty @controller.observed_mtimes,
                   "no mtime baseline should be seeded when nothing was cleared"

      # The single retry budget must be intact: once the on-disk marker
      # matches the row again, the same task still heals on the first try.
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=older -->\n")
      matching = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "older" },
        action: "error",
        live_task_lock: false
      )
      heal([ matching ])

      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size,
                   "the earlier clear_current=false must not have consumed the single retry budget"
      assert Hive::Markers.current(state_file).none?
    end
  end

  def test_finalize_unpushed_duplicate_rows_in_same_heal_pass_consume_one_budget_slot
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=err-a -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "err-a" },
        action: "error",
        live_task_lock: false
      )

      heal([ row, row ])

      assert Hive::Markers.current(state_file).none?
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size
      assert_equal 1, heals.first[1][:attempts]
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      refute @logger.events.any? { |name, _| name == :marker_heal_exhausted }
    end
  end

  def test_finalize_unpushed_budget_resets_on_fresh_healer_instance
    # The recovery budget is in-memory and per-process. A daemon restart
    # — or the SIGHUP rebuild of the healer in Dispatcher — drops the
    # accumulated counts, so a row that exhausted its budget on the old
    # instance is eligible again on a fresh one. This pins that reset as
    # INTENDED: a future "persist the budget" change must consciously
    # break this test.
    row_attrs = {
      pid_alive: nil,
      stage: "8-finalize",
      marker: "error",
      marker_attrs: { "reason" => "unpushed_commits" },
      action: "error",
      live_task_lock: false
    }

    with_marker_file do |state_file|
      first = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300,
        error_auto_recovery_limit: 1
      )
      row = make_row(state_file, **row_attrs)

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      first.heal([ row ], now: NOW)
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      first.heal([ row ], now: NOW)
      assert_match(/ERROR/, File.read(state_file),
                   "budget must be exhausted on the first instance after the second pass")

      fresh = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300,
        error_auto_recovery_limit: 1
      )
      fresh.heal([ row ], now: NOW)

      assert Hive::Markers.current(state_file).none?,
             "a fresh healer instance must heal the same row again (per-process budget reset)"
    end
  end

  def test_finalize_unpushed_auto_recovery_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, *args|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, *args)
      end

      begin
        heal([ row ])
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "finalize_unpushed_commits", failure[1][:reason]
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_does_not_auto_recover_review_error_review_agent_died_with_live_lock
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: true
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a review live-lock skip must be a clean no-op, not a logged failure"
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recoverable_review_error_stays_red_after_retry_budget_is_exhausted
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      review_error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      heal([ row ])
      refute_match(/REVIEW_ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      heal([ row ])

      assert_match(/REVIEW_ERROR/, File.read(state_file),
                   "same auto-recoverable review error must stay red after budget exhaustion")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size
      assert_equal 1, heals.first[1][:attempts]
      assert_equal 1, heals.first[1][:max_attempts]

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, exhausted.size
      assert_equal "review_agent_died", exhausted.first[1][:marker_reason]
      assert_equal "reviewers", exhausted.first[1][:phase]
      assert_equal "1", exhausted.first[1][:pass]
      assert_equal "per_process", exhausted.first[1][:budget_scope]
      assert_equal "manual_fix", exhausted.first[1][:suggested_next_action]
      assert_match(/rerun review/, exhausted.first[1][:remediation],
                   "exhausted event must carry an actionable remediation hint")
    end
  end

  def test_review_error_auto_recovery_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, *args|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, *args)
      end

      begin
        heal([ row ])
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", failure[1][:reason],
                   "a heal failure on a review_agent_died marker must keep its own " \
                   "label, not be mislabeled as the tmux-death channel"
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_finalize_unpushed_logs_when_controller_cannot_seed_pre_clear_mtime
    controller = Object.new
    def controller.running_task?(project:, slug:) = false
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: controller,
      logger: @logger,
      grace_sec: 300
    )

    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      missing = @logger.events.find { |name, _| name == :marker_heal_observer_missing }
      assert missing, "expected observer-missing event, got: #{@logger.events.inspect}"
      assert_equal "p", missing[1][:project]
      assert_equal "s", missing[1][:slug]
      assert_equal state_file, missing[1][:state_file]
      assert Hive::Markers.current(state_file).none?,
             "missing observer logging must not roll back a successful clear"
    end
  end

  def test_finalize_unpushed_exhausted_event_is_logged_once_per_process_key
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      heal([ row ])
      3.times do
        File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
        heal([ row ])
      end

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 1, exhausted.size,
                   "exhausted seen-map must suppress repeated log spam for the same process key"
    end
  end

  def test_private_stale_review_helpers_cover_process_and_lock_edges
    row = make_row("/tmp/missing-task.md", pid_alive: false, live_task_lock: true)
    assert_nil @healer.send(:task_lock_holder, row)
    assert_nil @healer.send(:release_task_lock, row)

    with_replaced_singleton_method(Open3, :capture3, lambda { |*_args|
      [ "", "", Struct.new(:exitstatus) { def success? = false }.new(1) ]
    }) do
      assert_equal [], @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Open3, :capture3, lambda { |*_args|
      [ "101\nbad\n202\n", "", Struct.new(:exitstatus) { def success? = true }.new(0) ]
    }) do
      assert_equal [ 101, 202 ], @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Open3, :capture3, lambda { |*_args|
      [ "", "boom", Struct.new(:exitstatus) { def success? = false }.new(2) ]
    }) do
      assert_nil @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Open3, :capture3, ->(*_args) { raise Errno::ENOENT }) do
      assert_nil @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      refute @healer.send(:pid_alive?, 12_345)
    end

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert @healer.send(:pid_alive?, 12_345)
      assert_nil @healer.send(:terminate_lock_holder, { "pid" => 12_345 })
    end

    assert_nil @healer.send(:terminate_lock_holder, { "pid" => "not-a-pid" })
  end

  def test_terminate_lock_holder_sends_term_then_stops_when_process_exits
    signals = []
    alive_checks = 0

    with_replaced_singleton_method(Process, :kill, lambda { |signal, pid|
      signals << [ signal, pid ]
      true
    }) do
      with_replaced_singleton_method(@healer, :pid_alive?, lambda { |_pid|
        alive_checks += 1
        alive_checks < 2
      }) do
        with_replaced_singleton_method(@healer, :sleep, ->(_seconds) { }) do
          @healer.send(:terminate_lock_holder, { "pid" => 12_345 })
        end
      end
    end

    assert_equal [ [ "TERM", 12_345 ] ], signals
  end

  def test_terminate_lock_holder_escalates_to_kill_after_deadline
    signals = []
    now = Time.utc(2026, 6, 5, 12, 0, 0)
    times = [ now, now + 2 ]

    with_replaced_singleton_method(Time, :now, -> { times.shift || now + 2 }) do
      with_replaced_singleton_method(Process, :kill, lambda { |signal, pid|
        signals << [ signal, pid ]
        true
      }) do
        with_replaced_singleton_method(@healer, :pid_alive?, ->(_pid) { true }) do
          @healer.send(:terminate_lock_holder, { "pid" => 12_345 })
        end
      end
    end

    assert_equal [ [ "TERM", 12_345 ], [ "KILL", 12_345 ] ], signals
  end

  def test_disk_failure_during_heal_does_not_crash_tick
    # Force Markers.set to raise on a row, and confirm the healer logs
    # and continues to the next row (the next row would otherwise heal).
    Dir.mktmpdir do |dir|
      bad_state = File.join(dir, "bad", "task.md")
      good_state = File.join(dir, "good", "task.md")
      FileUtils.mkdir_p(File.dirname(good_state))
      File.write(good_state, "# task\n\n<!-- AGENT_WORKING -->\n")
      # `bad_state`'s directory doesn't exist; Markers.set's ensure_dir
      # will try to mkdir_p, and that succeeds, so we have to force a
      # different failure. Easier: chmod the parent to read-only. But
      # for portability across CI sandboxes we instead stub.
      original = Hive::Markers.method(:set)
      Hive::Markers.define_singleton_method(:set) do |path, *args|
        raise Errno::ENOSPC, "no space left on device" if path == bad_state

        original.call(path, *args)
      end

      begin
        rows = [
          make_row(bad_state, pid_alive: false, project: "p", slug: "bad"),
          make_row(good_state, pid_alive: false, project: "p", slug: "good")
        ]
        heal(rows)

        failures = @logger.events.select { |name, _| name == :marker_heal_failed }
        heals = @logger.events.select { |name, _| name == :marker_healed }
        assert_equal 1, failures.size, "expected exactly one heal failure logged"
        assert_equal "p", failures.first[1][:project]
        assert_equal "bad", failures.first[1][:slug]
        assert_equal 1, heals.size, "good row must still be healed after bad row's failure"
        assert_equal "good", heals.first[1][:slug]
      ensure
        # Restore via explicit &block coercion so the stub doesn't leak
        # to later tests in the same process — relying on Method-as-
        # block coercion is documented but the explicit form is more
        # readable and version-stable.
        Hive::Markers.define_singleton_method(:set, &original)
      end
    end
  end
end
