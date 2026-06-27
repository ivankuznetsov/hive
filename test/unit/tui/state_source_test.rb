require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/task_meta"
require "hive/tui/state_source"
require "hive/workflows/project"

# StateSource is the only TUI component that touches threads, so these
# tests pin two contracts hard: (1) the polling thread really does land
# a Snapshot in `#current` (using the real registry + real Status
# command — no mocks of the JSON payload), and (2) `#stop` deterministically
# tears the thread down so test teardown never leaks a worker.
class TuiStateSourceTest < Minitest::Test
  include HiveTestHelper

  # Spin until `block` returns truthy or the deadline elapses. Returns
  # the truthy value or nil. Replaces `sleep N` (forbidden by project
  # rules; flaky and hides timing issues) with an explicit poll.
  def wait_for(deadline_seconds: 2.0, interval: 0.02)
    deadline = Time.now + deadline_seconds
    loop do
      result = yield
      return result if result
      return nil if Time.now > deadline

      sleep interval
    end
  end

  def with_seeded_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "probe").call }
        yield(project, dir)
      end
    end
  end

  def with_direct_project(name: "demo")
    with_tmp_global_config do |home|
      project_root = File.join(home, name)
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))
      Hive::Stages::DIRS.each { |stage| FileUtils.mkdir_p(File.join(hive_state, "stages", stage)) }
      File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.to_yaml)
      project = { "name" => name, "path" => project_root, "hive_state_path" => hive_state }
      File.write(File.join(home, "config.yml"), { "registered_projects" => [ project ] }.to_yaml)
      yield(project, hive_state)
    end
  end

  def add_direct_project(global_home, name:)
    project_root = File.join(global_home, name)
    hive_state = File.join(project_root, ".hive-state")
    FileUtils.mkdir_p(File.join(hive_state, "stages"))
    Hive::Stages::DIRS.each { |stage| FileUtils.mkdir_p(File.join(hive_state, "stages", stage)) }
    File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.to_yaml)
    project = { "name" => name, "path" => project_root, "hive_state_path" => hive_state }
    current = YAML.safe_load(File.read(File.join(global_home, "config.yml"))) || {}
    current["registered_projects"] = Array(current["registered_projects"]) + [ project ]
    File.write(File.join(global_home, "config.yml"), current.to_yaml)
    [ project, hive_state ]
  end

  # Registers a project whose tasks use a custom (non-built-in) workflow
  # whose active stage dir (`2-<stage_name>`) is absent from the default
  # registry union. Returns the project's hive_state path.
  def write_custom_workflow_project(global_home, name:, workflow:, stage_name: "work")
    project_root = File.join(global_home, name)
    hive_state = File.join(project_root, ".hive-state")
    instruction_dir = File.join(hive_state, "workflows", workflow)
    FileUtils.mkdir_p(instruction_dir)
    File.write(File.join(instruction_dir, "#{stage_name}.md"), "Do #{stage_name}.\n")
    File.write(File.join(hive_state, "workflows", "#{workflow}.yml"), <<~YAML)
      id: #{workflow}
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: #{stage_name}
          kind: agent
          state_file: #{stage_name}.md
          instruction: ./#{workflow}/#{stage_name}.md
        - name: done
          kind: terminal
          state_file: done.md
    YAML
    FileUtils.mkdir_p(File.join(hive_state, "stages", "2-#{stage_name}"))
    File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.to_yaml)
    project = { "name" => name, "path" => project_root, "hive_state_path" => hive_state }
    current = YAML.safe_load(File.read(File.join(global_home, "config.yml"))) || {}
    current["registered_projects"] = Array(current["registered_projects"]) + [ project ]
    File.write(File.join(global_home, "config.yml"), current.to_yaml)
    hive_state
  end

  def write_state_task(hive_state, stage, slug, marker:, id: nil, depends_on: nil)
    folder = File.join(hive_state, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: nil, depends_on: depends_on)
    File.write(File.join(folder, state_file_name(stage)), "<!-- #{marker} -->\n")
    folder
  end

  def state_file_name(stage)
    _, stage_name = Hive::Stages.parse(stage)
    Hive::Task::STATE_FILES.fetch(stage_name)
  end

  def test_start_polls_real_status_and_populates_current
    with_seeded_project do |project, _dir|
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.start
      begin
        snapshot = wait_for { source.current }
        refute_nil snapshot, "current should be populated within the deadline"
        assert_operator snapshot.rows.size, :>=, 1, "seeded project must have at least one row"

        first_row = snapshot.rows.first
        assert_match(/probe-/, first_row.slug,
                     "row slug should match the seeded slug pattern")
        assert_equal project, first_row.project_name
      ensure
        source.stop
      end

      refute_includes Thread.list, source.instance_variable_get(:@thread),
                      "stop must drop the polling thread out of Thread.list"
      assert_nil source.last_error, "happy path leaves last_error nil"
    end
  end

  def test_refresh_now_populates_current_without_background_thread
    with_seeded_project do |project, _dir|
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 60)

      snapshot = source.refresh_now

      refute_nil snapshot, "refresh_now must synchronously seed the first snapshot"
      assert_same snapshot, source.current
      assert_nil source.instance_variable_get(:@thread),
                 "refresh_now must not start the background polling thread"
      assert_operator snapshot.rows.size, :>=, 1,
                      "refresh_now must find at least one row for the seeded project"
      assert_equal project, snapshot.rows.first.project_name
      assert_nil source.last_error
    end
  end

  # Boot path contract: when the synchronous prime fails, refresh_now must
  # return nil and record last_error WITHOUT starting the background thread,
  # so App can still seed the model (snapshot: nil, last_error: <err>) and
  # render the stalled banner instead of crashing the TUI launch.
  def test_refresh_now_records_last_error_and_stays_threadless_on_failure
    with_seeded_project do |_project, _dir|
      keep_raising = true
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          raise StandardError, "synthetic refresh failure" if keep_raising

          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      begin
        source = Hive::Tui::StateSource.new(poll_interval_seconds: 60)

        snapshot = source.refresh_now

        assert_nil snapshot, "refresh_now must return nil when the prime fails"
        assert_nil source.current, "a failed prime must leave current nil"
        refute_nil source.last_error, "a failed prime must record last_error"
        assert_match(/synthetic refresh failure/, source.last_error.message)
        assert_nil source.instance_variable_get(:@thread),
                   "refresh_now must not start the background thread, even on failure"
      ensure
        keep_raising = false
      end
    end
  end

  def test_last_error_records_failure_and_clears_on_subsequent_success
    with_seeded_project do |_project, _dir|
      # Inject a one-shot raise into `Status#json_payload` via a
      # prepended module. We capture the call count on a sentinel so the
      # next call after the raise falls through to the real implementation,
      # producing a successful poll that should clear @last_error.
      raised = false
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          unless raised
            raised = true
            raise StandardError, "synthetic refresh failure"
          end
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      begin
        source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
        source.start
        begin
          err = wait_for { source.last_error }
          refute_nil err, "first poll's failure must populate last_error"
          assert_match(/synthetic refresh failure/, err.message)

          # Subsequent successful poll: current becomes non-nil and
          # last_error clears.
          snapshot = wait_for { source.current }
          refute_nil snapshot, "successful poll after failure must populate current"
          cleared = wait_for { source.last_error.nil? }
          assert cleared, "last_error must clear after a successful poll"
        ensure
          source.stop
        end
      ensure
        # Flip the toggle so any leftover call into the prepended patch
        # falls through to `super(projects, **kwargs)` — equivalent to a no-op.
        # MRI has no `unprepend`, so the prepended Module remains on
        # `Hive::Commands::Status.ancestors`. That's an acceptable leak
        # because the patch is now inert (raised==true short-circuits
        # the raise branch on every subsequent call) and each test that
        # injects a fresh Module gets its own ancestor entry rather
        # than mutating ours.
        raised = true
      end
    end
  end

  def test_stalled_when_current_seen_at_older_than_threshold
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
    source.instance_variable_set(:@current_seen_at, Time.now - 6.0)
    assert source.stalled?, "snapshot 6s old must be stalled at default 5s threshold"

    source.instance_variable_set(:@current_seen_at, Time.now - 1.0)
    refute source.stalled?, "snapshot 1s old must not be stalled"
  end

  def test_stalled_in_boot_state_with_no_successful_poll
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
    assert source.stalled?, "boot state (no successful poll) counts as stalled"
  end

  def test_stop_is_safe_when_start_was_never_called
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
    # Should not raise.
    source.stop
  end

  # Renderer reads `last_error` and `stalled?` together when poll
  # failures persist; pin that both stay reachable via the public
  # surface (no instance-variable peeking) after a refresh fault.
  def test_stalled_and_last_error_are_both_reachable_when_poll_fails
    raised = false
    keep_raising = true
    patch = Module.new do
      define_method(:json_payload) do |projects, **kwargs|
        if keep_raising
          raised = true
          raise StandardError, "synthetic refresh failure"
        end
        super(projects, **kwargs)
      end
    end
    Hive::Commands::Status.prepend(patch)

    begin
      with_seeded_project do |_project, _dir|
        source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
        source.start
        begin
          err = wait_for { source.last_error }
          refute_nil err, "poll failure must populate last_error"
          assert source.stalled?, "no successful poll yet — must report stalled"
          assert_match(/synthetic refresh failure/, err.message)
          assert raised
        ensure
          source.stop
        end
      end
    ensure
      # See sibling test — MRI has no `unprepend`. Flip `keep_raising`
      # so any future call through the prepended Module falls through
      # to `super(projects, **kwargs)` (a no-op). The empty/no-op Module remains
      # on the ancestor chain; that's the documented acceptable leak.
      keep_raising = false
    end
  end

  def test_refresh_once_skips_status_parse_when_mtime_fingerprint_is_unchanged
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      first = source.current
      source.send(:refresh_once)

      assert_equal 1, calls, "unchanged mtimes should reuse the cached snapshot"
      assert_same first, source.current
    end
  end

  def test_refresh_once_reparses_when_state_file_mtime_changes
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      state_file = source.current.rows.first.state_file
      File.utime(Time.now + 5, Time.now + 5, state_file)
      source.send(:refresh_once)

      assert_equal 2, calls, "state-file mtime changes must invalidate the cached snapshot"
    end
  end

  def test_refresh_once_reparses_when_task_lock_appears
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      first = source.current
      row = first.rows.first
      assert_equal "ready_to_brainstorm", row.action_key

      File.write(File.join(row.folder, ".lock"), Hive::Lock.base_payload.to_yaml)
      source.send(:refresh_once)

      refute_same first, source.current
      assert_equal 2, calls, "task .lock changes must invalidate the cached snapshot"
      assert_equal "agent_running", source.current.rows.first.action_key
      assert_equal true, source.current.rows.first.live_task_lock
    end
  end

  def test_refresh_once_reparses_when_task_lock_disappears
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      lock_path = File.join(source.current.rows.first.folder, ".lock")
      File.write(lock_path, Hive::Lock.base_payload.to_yaml)
      source.send(:refresh_once)
      locked = source.current
      assert_equal "agent_running", locked.rows.first.action_key

      File.delete(lock_path)
      source.send(:refresh_once)

      refute_same locked, source.current
      assert_equal 3, calls, "task .lock removal must invalidate the cached snapshot"
      assert_equal "ready_to_brainstorm", source.current.rows.first.action_key
      assert_equal false, source.current.rows.first.live_task_lock
    end
  end

  def test_refresh_once_reparses_when_task_lock_mtime_changes
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      row = source.current.rows.first
      lock_path = File.join(row.folder, ".lock")
      File.write(lock_path, Hive::Lock.base_payload.to_yaml)
      source.send(:refresh_once)
      locked = source.current

      updated_at = Time.now + 5
      File.utime(updated_at, updated_at, lock_path)
      source.send(:refresh_once)

      refute_same locked, source.current
      assert_equal 3, calls, "task .lock mtime changes must invalidate the cached snapshot"
      assert_equal "agent_running", source.current.rows.first.action_key
      assert_equal true, source.current.rows.first.live_task_lock
    end
  end

  def test_archived_task_files_are_excluded_from_active_fingerprint
    with_direct_project do |_project, hive_state|
      active_folder = write_state_task(hive_state, "4-execute", "active-task-260626-abcd",
                                       marker: "EXECUTE_COMPLETE", id: 1)
      archived_folder = write_state_task(hive_state, "9-done", "archived-task-260626-abcd",
                                         marker: "COMPLETE", id: 2)
      File.write(File.join(archived_folder, ".lock"), Hive::Lock.base_payload.to_yaml)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)

      fingerprint_paths = source.instance_variable_get(:@mtime_fingerprint).keys
      assert_includes fingerprint_paths, File.join(active_folder, "task.md")
      refute_includes fingerprint_paths, File.join(archived_folder, "task.md")
      refute_includes fingerprint_paths, File.join(archived_folder, ".lock")
      assert_includes source.instance_variable_get(:@archive_dir_mtimes).keys,
                      File.join(hive_state, "stages", "9-done")
    end
  end

  def test_archive_dir_change_refreshes_cache_without_active_reparse
    with_direct_project do |_project, hive_state|
      write_state_task(hive_state, "4-execute", "active-task-260626-abcd",
                       marker: "EXECUTE_COMPLETE", id: 1)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      active_calls = 0
      archive_calls = 0
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          stages = kwargs[:stages]
          if stages == [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ]
            archive_calls += 1
          else
            active_calls += 1
          end
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source.send(:refresh_once)
      first = source.current
      write_state_task(hive_state, "9-done", "archived-task-260626-abcd",
                       marker: "COMPLETE", id: 2)
      File.utime(Time.now + 5, Time.now + 5, File.join(hive_state, "stages", "9-done"))
      source.send(:refresh_once)

      assert_equal 1, active_calls, "archive-only changes must not force an active parse"
      assert_same first, source.current, "current active snapshot is reused while archive cache refreshes"
      refreshed = wait_for { archive_calls.positive? && source.instance_variable_get(:@archived_cache) }
      refute_nil refreshed, "archive dir changes should trigger a background archive refresh"
    ensure
      source&.stop
    end
  end

  def test_task_moving_into_done_appears_from_archive_cache_without_duplicates
    with_direct_project do |_project, hive_state|
      folder = write_state_task(hive_state, "4-execute", "moving-task-260626-abcd",
                                marker: "EXECUTE_COMPLETE", id: 1)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)

      done_folder = File.join(hive_state, "stages", "9-done", File.basename(folder))
      FileUtils.mv(folder, done_folder)
      source.send(:refresh_once)
      refute_includes source.current.rows.map(&:slug), "moving-task-260626-abcd",
                      "active parse should drop a row moved out of active stages"

      wait_for { !source.instance_variable_get(:@archive_refresh_thread)&.alive? }
      source.send(:refresh_once)
      rows = source.current.rows.select { |row| row.slug == "moving-task-260626-abcd" }

      assert_equal 1, rows.size
      assert_equal "9-done", rows.first.stage
    ensure
      source&.stop
    end
  end

  def test_liveness_fallback_rechecks_active_tasks_without_mtime_change
    with_direct_project do |_project, hive_state|
      folder = write_state_task(hive_state, "4-execute", "live-task-260626-abcd",
                                marker: "AGENT_WORKING pid=#{Process.pid}", id: 1)
      File.write(File.join(folder, ".lock"), YAML.dump(
        "claude_pid" => Process.pid,
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid)
      ))
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      assert_equal "agent_running", source.current.rows.first.action_key

      fallback = Hive::Tui::StateSource::LIVENESS_REPARSE_FALLBACK_SECONDS
      parsed_at = source.instance_variable_get(:@last_full_parse_at)
      dead_holder = lambda do |_signal, pid|
        raise Errno::ESRCH if pid == Process.pid

        true
      end

      # Lower edge: just under the fallback window the mtime gate still
      # reuses the cached snapshot, so the now-dead holder keeps its stale
      # "agent_running" indicator — proving the boundary actually gates.
      with_replaced_singleton_method(Time, :now, -> { parsed_at + fallback - 0.5 }) do
        with_replaced_singleton_method(Process, :kill, dead_holder) do
          source.send(:refresh_once)
        end
      end
      assert_equal "agent_running", source.current.rows.first.action_key,
                   "no reparse before the liveness fallback window elapses"

      # At the boundary the forced reparse re-checks liveness and the dead
      # holder's indicator clears.
      with_replaced_singleton_method(Time, :now, -> { parsed_at + fallback }) do
        with_replaced_singleton_method(Process, :kill, dead_holder) do
          source.send(:refresh_once)
        end
      end

      assert_equal "error", source.current.rows.first.action_key
      assert_equal false, source.current.rows.first.live_task_lock
    end
  end

  def test_archived_dependency_identity_keeps_active_dependent_unblocked_after_reparse
    with_direct_project do |_project, hive_state|
      base_slug = "archived-base-260626-abcd"
      write_state_task(hive_state, "9-done", base_slug, marker: "COMPLETE", id: 1)
      dependent = write_state_task(hive_state, "4-execute", "dependent-task-260626-abcd",
                                   marker: "EXECUTE_COMPLETE", id: 2, depends_on: base_slug)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)

      File.utime(Time.now + 5, Time.now + 5, File.join(dependent, "task.md"))
      source.send(:refresh_once)
      row = source.current.rows.find { |candidate| candidate.slug == "dependent-task-260626-abcd" }

      assert_equal false, row.blocked
      assert_equal base_slug, row.blocked_by
      assert_equal "9-done", row.dependency_stage
    end
  end

  def test_registry_project_set_changes_are_reflected_and_drop_removed_archive_cache
    with_tmp_global_config do |home|
      _project_a, state_a = add_direct_project(home, name: "alpha")
      write_state_task(state_a, "9-done", "alpha-done-260626-abcd", marker: "COMPLETE", id: 1)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      assert_equal [ "alpha" ], source.current.projects.map(&:name)
      assert_includes source.current.rows.map(&:slug), "alpha-done-260626-abcd"

      _project_b, state_b = add_direct_project(home, name: "beta")
      write_state_task(state_b, "4-execute", "beta-active-260626-abcd",
                       marker: "EXECUTE_COMPLETE", id: 2)
      source.send(:refresh_once)
      assert_equal [ "alpha", "beta" ], source.current.projects.map(&:name)

      config_path = File.join(home, "config.yml")
      data = YAML.safe_load(File.read(config_path))
      data["registered_projects"] = data.fetch("registered_projects").reject { |entry| entry["name"] == "alpha" }
      File.write(config_path, data.to_yaml)
      source.send(:refresh_once)

      assert_equal [ "beta" ], source.current.projects.map(&:name)
      refute_includes source.current.rows.map(&:slug), "alpha-done-260626-abcd"
    ensure
      source&.stop
    end
  end

  def test_stop_joins_archive_refresher_thread
    with_direct_project do |_project, hive_state|
      write_state_task(hive_state, "9-done", "archived-task-260626-abcd",
                       marker: "COMPLETE", id: 1)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      source.request_archive_refresh
      source.send(:start_archive_refresh_if_needed)
      thread = source.instance_variable_get(:@archive_refresh_thread)

      source.stop

      refute thread&.alive?, "stop must join the archive refresher thread"
    end
  end

  # Directly pins the 30s archive backstop: with no `9-done` dir-mtime
  # change, archive_refresh_due? must flip from false to true once
  # @archive_last_refresh_at + ARCHIVE_REFRESH_FALLBACK_SECONDS elapses.
  # An inverted comparison or a bad constant would otherwise slip through.
  def test_archive_backstop_requests_refresh_after_fallback_window
    with_direct_project do |_project, hive_state|
      write_state_task(hive_state, "4-execute", "active-task-260626-abcd",
                       marker: "EXECUTE_COMPLETE", id: 1)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)

      fallback = Hive::Tui::StateSource::ARCHIVE_REFRESH_FALLBACK_SECONDS
      last_refresh = source.instance_variable_get(:@archive_last_refresh_at)

      refute source.send(:archive_refresh_due?, now: last_refresh + fallback - 1.0),
             "no backstop refresh before the fallback window elapses"
      assert source.send(:archive_refresh_due?, now: last_refresh + fallback),
             "backstop must request a refresh once the fallback window elapses"
    ensure
      source&.stop
    end
  end

  # Overlap guard (state_source.rb): start_archive_refresh_if_needed must
  # NOT spawn a second refresher while one is still alive, and must leave
  # the dropped request armed so the next tick retries — otherwise a burst
  # of triggers under load could leak refresher threads.
  def test_start_archive_refresh_skips_when_a_refresher_is_already_alive
    with_direct_project do |_project, _hive_state|
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)

      release = Queue.new
      running = Thread.new { release.pop }
      source.instance_variable_set(:@archive_refresh_thread, running)
      source.request_archive_refresh

      source.send(:start_archive_refresh_if_needed)

      assert_same running, source.instance_variable_get(:@archive_refresh_thread),
                  "overlap guard must not replace a live refresher thread"
      assert source.instance_variable_get(:@archive_refresh_dirty),
             "the dropped refresh stays armed so the next tick retries"
    ensure
      release << :go if release
      running&.join(1)
      source&.stop
    end
  end

  # Shutdown hardening (state_source.rb): once @stop is set,
  # start_archive_refresh_if_needed must refuse to spawn a refresher even
  # with the dirty flag armed, so a poll thread overshooting stop's join
  # deadline can't leave a detached refresher alive past teardown.
  def test_start_archive_refresh_refuses_to_spawn_after_stop
    with_direct_project do |_project, hive_state|
      write_state_task(hive_state, "9-done", "archived-task-260626-abcd",
                       marker: "COMPLETE", id: 1)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      source.stop # sets @stop = true and clears the thread reference
      source.request_archive_refresh

      source.send(:start_archive_refresh_if_needed)

      assert_nil source.instance_variable_get(:@archive_refresh_thread),
                 "no refresher may be spawned after stop"
    end
  end

  # Identities derive from the cache's :projects rows (no parallel map to
  # drift) and are memoized per cache object so the hot active reparse
  # doesn't rebuild them every tick.
  def test_archived_identities_are_memoized_per_cache_object
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 60)
    cache = {
      projects: {
        "/p" => [ { "slug" => "a-260626-abcd", "id" => 1, "stage" => "9-done" }.freeze ].freeze
      }.freeze
    }.freeze

    first = source.send(:archived_identities_from_cache, cache)
    second = source.send(:archived_identities_from_cache, cache)

    assert_same first, second, "identities are memoized while the cache object is unchanged"
    assert_equal([ { "slug" => "a-260626-abcd", "id" => 1, "stage" => "9-done" } ], first.fetch("/p"))
  end

  # Codex regression: the steady-state active reparse must compute the
  # active-stage set per project AFTER each project's workflow overlay
  # loads, not from a single union snapshot taken before json_payload.
  # With a custom-workflow project registered ahead of a default one, the
  # registry union no longer reflects the custom project's overlay when a
  # pre-computed active filter is built, so its custom active stage
  # (`2-work`) would be dropped from every incremental tick.
  def test_incremental_reparse_keeps_custom_workflow_active_stage_rows
    with_tmp_global_config do |home|
      custom_state = write_custom_workflow_project(home, name: "custom", workflow: "my-flow")
      custom_task = File.join(custom_state, "stages", "2-work", "work-task-260626-abcd")
      FileUtils.mkdir_p(custom_task)
      Hive::TaskMeta.write(custom_task, id: 1, slug: "work-task-260626-abcd",
                           display_name: nil, workflow: "my-flow")
      File.write(File.join(custom_task, "work.md"), "<!-- COMPLETE -->\n")

      _coding, coding_state = add_direct_project(home, name: "coding")
      write_state_task(coding_state, "4-execute", "exec-task-260626-efgh",
                       marker: "EXECUTE_COMPLETE", id: 2)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      assert_includes source.current.rows.map(&:slug), "work-task-260626-abcd",
                      "cold full parse must include the custom-workflow task"

      # Force a steady-state active-only reparse via an mtime bump.
      File.utime(Time.now + 5, Time.now + 5, File.join(custom_task, "work.md"))
      source.send(:refresh_once)

      slugs = source.current.rows.map(&:slug)
      assert_includes slugs, "work-task-260626-abcd",
                      "incremental reparse must not drop the custom-workflow active stage"
      assert_includes slugs, "exec-task-260626-efgh",
                      "the default project's active rows must still be present"
    ensure
      source&.stop
      Hive::Workflows::Project.reset! if defined?(Hive::Workflows::Project)
    end
  end

  def test_archive_refresher_failure_rearms_and_records_error_without_raising
    with_direct_project do |_project, _hive_state|
      raise_archive_refresh = true
      patch = Module.new do
        define_method(:json_payload) do |projects, **kwargs|
          if raise_archive_refresh && kwargs[:stages] == [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ]
            raise StandardError, "synthetic archive refresh failure"
          end

          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)

      # The worker must not raise, must not `warn` (it would corrupt the
      # alt-screen frame), must surface the failure on the renderer's error
      # channel, and must leave a retry armed for the next poll tick.
      _out, err = capture_io do
        source.send(:refresh_archived_cache, Hive::Config.registered_projects)
      end

      assert_empty err, "a failed archive refresh must not warn under the alt-screen TUI"
      refute_nil source.last_error, "the failure must surface on @last_error"
      assert_match(/synthetic archive refresh failure/, source.last_error.message)
      assert source.instance_variable_get(:@archive_refresh_dirty),
             "a failed refresh must re-arm the dirty flag so the next tick retries"
    ensure
      raise_archive_refresh = false
      source&.stop
    end
  end

  def test_safe_mtime_distinguishes_stat_error_from_absent
    # state_source.rb: the file may vanish (or error) between the
    # File.exist? check and File.mtime. A stat error must degrade to a
    # fresh, never-equal StatError marker (NOT nil) so the change
    # detectors bias toward a re-check; nil is reserved for a genuinely
    # absent path so a stable absence still compares equal across ticks.
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)

    assert_nil source.send(:safe_mtime, File.join(Dir.tmpdir, "definitely-absent-260626-abcd.md")),
               "an absent path must read as nil"

    Dir.mktmpdir("state-source-safe-mtime") do |dir|
      path = File.join(dir, "vanishing.md")
      File.write(path, "x\n")
      with_replaced_singleton_method(File, :mtime, lambda { |arg|
        raise Errno::ENOENT, arg if arg == path

        File.stat(arg).mtime
      }) do
        first = source.send(:safe_mtime, path)
        second = source.send(:safe_mtime, path)

        refute_nil first, "a stat error must NOT collapse into the absent (nil) reading"
        refute_equal first, second,
                     "two errored reads must compare unequal so the change detector re-checks"
      end
    end
  end

  def test_registry_config_path_returns_nil_when_global_config_path_raises
    # state_source.rb 141: mtime_fingerprint_for must keep working even
    # if the registry path lookup blows up (e.g. HOME unset / config
    # subsystem error). The rescue degrades to nil so the registry path
    # is simply dropped from the watched-mtime set instead of crashing
    # the poll thread.
    source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)

    with_replaced_singleton_method(Hive::Config, :global_config_path, lambda {
      raise StandardError, "registry path unavailable"
    }) do
      assert_nil source.send(:registry_config_path),
                 "registry_config_path must degrade to nil when global_config_path raises"
    end
  end

  def test_poll_loop_observes_state_file_change_within_latency_budget
    with_seeded_project do |_project, _dir|
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.start
      begin
        first = wait_for(deadline_seconds: 0.5) { source.current }
        refute_nil first

        state_file = first.rows.first.state_file
        File.utime(Time.now + 5, Time.now + 5, state_file)

        changed = wait_for(deadline_seconds: 1.5) { source.current unless source.current.equal?(first) }
        refute_nil changed, "state-file mtime changes must produce a fresh snapshot within 1.5s"
      ensure
        source.stop
      end
    end
  end
end
