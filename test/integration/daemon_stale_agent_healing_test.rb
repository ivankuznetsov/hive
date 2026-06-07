require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/status_consumer"
require "hive/daemon/logger"
require "hive/daemon/concurrency_controller"
require "hive/daemon/policy"
require "hive/markers"

# End-to-end integration: drive the real status command on a tmpdir
# project, feed its JSON-shaped output through the daemon's
# StatusConsumer Row, and assert the StaleAgentHealer rewrites the
# on-disk AGENT_WORKING marker to ERROR.
#
# The unit-level healer tests hand-construct Row(marker: "agent_working",
# action: "agent_running" or "error") — combinations that may or may
# not match what the production status pipeline emits. This integration
# test pins the *contract* between the two components: whatever shape
# status produces, the healer recognises it and acts.
class DaemonStaleAgentHealingTest < Minitest::Test
  include HiveTestHelper

  def setup
    @logger = FakeLogger.new
    @controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 4,
      max_concurrent_per_project: 2,
      max_runs_per_day_per_project: 50
    )
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller, logger: @logger, grace_sec: 300
    )
  end

  class FakeLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      # Mirror the real Logger's closed-enum gate so the integration
      # test would fail if a new event name was emitted without being
      # registered in Hive::Daemon::Logger::EVENTS.
      unless Hive::Daemon::Logger::EVENTS.include?(name)
        raise ArgumentError, "FakeLogger rejected event #{name.inspect}; " \
                             "add it to Hive::Daemon::Logger::EVENTS first"
      end
      @events << [ name, attrs ]
    end
  end

  def with_seeded_task
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "stale-260520-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "task.md")
        yield dir, folder, state_file, slug
      end
    end
  end

  def status_rows_via_consumer(dir)
    # Run the real `hive status --json` against the tmp project and
    # parse it the same way the dispatcher does. Goes through the
    # whole pipeline: Status command → TaskAction classification →
    # JSON envelope → StatusConsumer Row struct.
    out, _err = capture_io do
      Hive::Commands::Status.new(json: true).call
    rescue Hive::Error
      # status command exits non-zero when no tasks; that's fine here
    end
    doc = JSON.parse(out)
    rows = []
    Array(doc["projects"]).each do |project|
      Array(project["tasks"]).each do |task|
        rows << Hive::Daemon::StatusConsumer::Row.new(
          project: project["name"],
          slug: task["slug"],
          stage: task["stage"],
          marker: task["marker"],
          marker_attrs: task["attrs"],
          folder: task["folder"],
          state_file: task["state_file"],
          state_file_mtime: task["mtime"] ? Time.parse(task["mtime"]) : nil,
          action: task["action"],
          suggested_command: task["suggested_command"],
          claude_pid_alive: task["claude_pid_alive"],
          live_task_lock: task["live_task_lock"],
          diagnostic: task["diagnostic"]
        )
      end
    end
    rows
  end

  def test_full_pipeline_heals_placeholder_AGENT_WORKING_past_grace
    with_seeded_task do |_dir, _folder, state_file, slug|
      # Placeholder marker (no pid attr) — exactly the shape
      # lib/hive/stages/execute.rb#write_initial_task_md stamps on
      # stage entry. Then backdate the file so it's past the grace
      # window.
      File.write(state_file, "---\nslug: #{slug}\n---\n\n# #{slug}\n\n<!-- AGENT_WORKING -->\n")
      backdated = Time.now - 600 # 10 minutes ago, past default 300s grace
      File.utime(backdated, backdated, state_file)

      rows = status_rows_via_consumer(File.dirname(File.dirname(File.dirname(state_file))).then { |s| File.dirname(File.dirname(s)) })
      target = rows.find { |r| r.slug == slug }
      assert target, "status pipeline must include the seeded task: rows=#{rows.inspect}"
      assert_equal "agent_working", target.marker,
                   "status pipeline must surface the on-disk marker name as agent_working"
      assert_equal "error", target.action,
                   "TaskAction must reclassify stale agent_working as :error so the in-memory view doesn't lie"

      # Now run the healer against the SAME row the dispatcher would
      # see. Without the marker-name filter (fixing the original bug),
      # the healer would skip this row because action != "agent_running".
      @healer.heal(rows, now: Time.now)

      heal = @logger.events.find { |name, _| name == :marker_healed }
      assert heal, "expected :marker_healed event after healer.heal, got: #{@logger.events.inspect}"
      assert_equal "agent_orphaned", heal[1][:reason]

      on_disk = File.read(state_file)
      refute_match(/AGENT_WORKING/, on_disk,
                   "healer must overwrite the placeholder marker on disk")
      assert_match(/ERROR\s+reason=agent_orphaned/, on_disk,
                   "healed marker must carry reason=agent_orphaned for the diagnose-then-act surface")
    end
  end

  def test_full_pipeline_leaves_AGENT_WORKING_within_grace_window
    with_seeded_task do |_dir, _folder, state_file, slug|
      File.write(state_file, "---\nslug: #{slug}\n---\n\n# #{slug}\n\n<!-- AGENT_WORKING -->\n")
      # Fresh placeholder (mtime within grace). The dispatcher could
      # be mid-spawn; healing here would race a real attaching agent.
      fresh = Time.now - 30
      File.utime(fresh, fresh, state_file)

      rows = status_rows_via_consumer(File.dirname(File.dirname(File.dirname(state_file))).then { |s| File.dirname(File.dirname(s)) })
      target = rows.find { |r| r.slug == slug }
      assert target
      # Within grace: action remains agent_running (no reclassification).
      assert_equal "agent_running", target.action

      @healer.heal(rows, now: Time.now)

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "row inside grace window must not be healed; events=#{@logger.events.inspect}"
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  def test_full_pipeline_uses_closed_event_enum
    # Smoke check that the events StaleAgentHealer emits are all in
    # the real Hive::Daemon::Logger::EVENTS enum. The FakeLogger above
    # mirrors the gate; if a future refactor adds a new event name
    # without registering it, this test catches it instead of the
    # daemon crashing on first stale row in production.
    assert_includes Hive::Daemon::Logger::EVENTS, :marker_healed
    assert_includes Hive::Daemon::Logger::EVENTS, :marker_heal_failed
  end

  def test_status_json_finalize_error_row_attrs_carry_marker_id
    # The healer's TOCTOU guard (auto_recoverable_error_match_attrs) keys
    # off the marker_id carried in the status `attrs`. If `hive status
    # --json` ever stopped surfacing marker_id in attrs, every production
    # heal would silently fall onto the legacy no-id path and the guard
    # would be defeated — with no failing test. Pin the contract end to
    # end: a real status run over a finalize ERROR marker (marker_id
    # auto-stamped by Markers.set, exactly as finalize writes it) carries
    # that id through the JSON envelope into the StatusConsumer Row.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "finalize-260607-bbbb"
        folder = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "pr.md")
        File.write(state_file, "---\nslug: #{slug}\n---\n\n# #{slug}\n")
        # Markers.set auto-stamps a random marker_id on ERROR markers —
        # the same path finalize uses when it writes reason=unpushed_commits.
        Hive::Markers.set(state_file, :error, reason: "unpushed_commits")
        stamped_id = Hive::Markers.current(state_file).attrs["marker_id"].to_s
        refute stamped_id.empty?, "precondition: Markers.set must stamp a marker_id"

        rows = status_rows_via_consumer(dir)
        target = rows.find { |r| r.slug == slug }
        assert target, "status pipeline must include the finalize task: rows=#{rows.inspect}"
        assert_equal "error", target.marker
        assert target.marker_attrs.is_a?(Hash),
               "status attrs must be a hash, got: #{target.marker_attrs.inspect}"
        assert_equal "unpushed_commits", target.marker_attrs["reason"]
        assert_equal stamped_id, target.marker_attrs["marker_id"].to_s,
                     "status --json error-row attrs must carry the on-disk marker_id so the " \
                     "healer's TOCTOU guard keys off the real id, not the legacy no-id path; " \
                     "attrs=#{target.marker_attrs.inspect}"
      end
    end
  end

  def test_finalize_unpushed_clear_redispatches_instead_of_recording_baseline
    # The load-bearing claim behind observe_pre_clear_mtime: clearing a
    # finalize `ERROR reason=unpushed_commits` marker leaves a markerless
    # 8-finalize row that TaskAction classifies as `finalize_waiting`
    # (NEEDS_INPUT → edit_resume). On FIRST sight with no dispatch
    # baseline, Policy#decide_edit returns :record_baseline and SKIPS the
    # dispatch — so finalize would never re-run and the task would strand
    # as a markerless "needs your input" row, even though the heal already
    # consumed a retry. The healer seeds the dispatch baseline with the
    # PRE-clear mtime; the clear then bumps the file mtime past that
    # baseline, so Policy sees a genuine edit and dispatches. This wires
    # the real StaleAgentHealer → ConcurrencyController → Policy chain to
    # prove finalize actually re-fires (it is NOT enough to assert the
    # marker was removed — the unit tests already do that).
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "finalize-260607-abcd"
        folder = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "pr.md")
        File.write(state_file, "---\nslug: #{slug}\n---\n\n# #{slug}\n\n" \
                               "<!-- ERROR reason=unpushed_commits marker_id=err-a -->\n")
        pre_clear_mtime = Time.now - 1000
        File.utime(pre_clear_mtime, pre_clear_mtime, state_file)

        rows = status_rows_via_consumer(dir)
        row = rows.find { |candidate| candidate.slug == slug }
        assert row, "status pipeline must include the finalize task: rows=#{rows.inspect}"
        assert_equal "error", row.marker
        assert_equal "error", row.action
        assert_equal({ "reason" => "unpushed_commits", "marker_id" => "err-a" }, row.marker_attrs)
        assert_in_delta pre_clear_mtime.to_f, row.state_file_mtime.to_f, 1.0,
                        "status pipeline must carry the state-file mtime into healer rows"

        @healer.heal([ row ], now: Time.now)

        assert Hive::Markers.current(state_file).none?,
               "healer must clear the finalize unpushed marker"
        baseline = @controller.last_dispatched_state_file_mtime_for(project: File.basename(dir), slug: slug)
        assert baseline,
               "heal must seed a dispatch baseline so the post-clear row is not treated as first-sight"
        assert_in_delta pre_clear_mtime.to_f, baseline.to_f, 1.0,
                        "the seeded baseline must be the PRE-clear mtime"

        # The clear rewrote the file, bumping its mtime past the seeded
        # baseline — a genuine edit from Policy's point of view. The
        # pre-clear mtime is offset by 1000s above so this assertion does
        # not depend on sub-second filesystem mtime resolution.
        post_clear_mtime = File.mtime(state_file)
        assert post_clear_mtime > baseline,
               "post-clear mtime must exceed the seeded pre-clear baseline"
        post_clear_row = status_rows_via_consumer(dir).find { |candidate| candidate.slug == slug }
        assert post_clear_row, "status pipeline must include the cleared finalize task"
        assert_equal "none", post_clear_row.marker
        assert_equal "needs_input", post_clear_row.action,
                     "policy input must come from the real post-clear status row"

        decision = Hive::Daemon::Policy.decide(
          action: post_clear_row.action,
          stage: post_clear_row.stage,
          command: post_clear_row.suggested_command,
          state_file_mtime: post_clear_row.state_file_mtime,
          last_dispatched_state_file_mtime: baseline,
          now: post_clear_row.state_file_mtime + 3600,
          edit_debounce_sec: 30
        )

        assert_equal :dispatch, decision,
                     "finalize must re-dispatch after the unpushed_commits heal, " \
                     "not strand on :record_baseline"
      end
    end
  end

  def test_agent_marker_grace_sec_threads_from_global_config_to_TaskAction
    # Operator overrides `daemon.agent_marker_grace_sec` in
    # ~/Dev/hive/config.yml. Both surfaces (status/TaskAction in
    # memory, daemon healer on disk) must read the same value so they
    # classify rows with one threshold. This pins the
    # global-config → Status → TaskAction chain via the real
    # `hive status --json` command.
    with_seeded_task do |dir, _folder, state_file, slug|
      File.write(state_file, "---\nslug: #{slug}\n---\n\n# #{slug}\n\n<!-- AGENT_WORKING -->\n")
      # 90 seconds old: still inside the default 300s grace, but well
      # past the 60s override we'll write to config.
      mtime = Time.now - 90
      File.utime(mtime, mtime, state_file)

      # Without the override: row classifies as agent_running.
      out, _err = capture_io { Hive::Commands::Status.new(json: true).call rescue Hive::Error }
      row_default = JSON.parse(out)["projects"].flat_map { |p| p["tasks"] }.find { |t| t["slug"] == slug }
      assert_equal "agent_working", row_default["marker"]
      assert_equal "agent_running", row_default["action"],
                   "with default 300s grace, a 90s-old placeholder must stay agent_running"

      # Override the global config to a 60s grace. Merge into the
      # existing config so the project registry isn't wiped (the
      # registry write happened during `Hive::Commands::Init.new(dir).call`).
      existing = if File.exist?(Hive::Config.global_config_path)
                   YAML.safe_load_file(Hive::Config.global_config_path, permitted_classes: [ Symbol ]) || {}
      else
                   {}
      end
      existing["daemon"] = (existing["daemon"] || {}).merge("agent_marker_grace_sec" => 60)
      Hive::Config.write_global_config!(existing)

      # New Status instance to bypass per-call memoization.
      out2, _err2 = capture_io { Hive::Commands::Status.new(json: true).call rescue Hive::Error }
      row_overridden = JSON.parse(out2)["projects"].flat_map { |p| p["tasks"] }.find { |t| t["slug"] == slug }
      assert_equal "error", row_overridden["action"],
                   "with 60s grace, the same 90s-old placeholder must reclassify to error; " \
                   "if this fails, the daemon.agent_marker_grace_sec config key is not threading " \
                   "through to TaskAction"
    end
  end
end
