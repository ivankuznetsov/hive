require "test_helper"
require "tmpdir"
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
    def initialize(running_pairs: [])
      @running = running_pairs
    end

    def running_task?(project:, slug:)
      @running.include?([ project, slug ])
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
      assert_equal 1, heals.first[1][:attempt]
      assert_equal 1, heals.first[1][:max_attempts]
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
      assert_equal "reviewer_tmux_session_terminated", failure[1][:reason]
      assert_match(/ENOSPC/, failure[1][:error])
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
