require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/task_meta"
require "hive/tui/state_source"
require "thread"

class TuiStateSourceTest < Minitest::Test
  include HiveTestHelper

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
      Hive::Stages::DIRS.each do |stage|
        FileUtils.mkdir_p(File.join(hive_state, "stages", stage))
      end
      File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.to_yaml)
      project = { "name" => name, "path" => project_root, "hive_state_path" => hive_state }
      File.write(File.join(home, "config.yml"), { "registered_projects" => [ project ] }.to_yaml)
      yield(project, hive_state)
    end
  end

  def write_task(hive_state, stage, slug, marker:, id:, depends_on: nil)
    folder = File.join(hive_state, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(
      folder, id: id, slug: slug, display_name: nil, depends_on: depends_on,
      completed_at: (Time.now.utc if stage == "9-done")
    )
    _, stage_name = Hive::Stages.parse(stage)
    state_file = Hive::Task::STATE_FILES.fetch(stage_name)
    File.write(File.join(folder, state_file), "<!-- #{marker} -->\n")
    folder
  end

  def test_start_polls_real_active_status_and_stop_joins_the_poller
    with_seeded_project do |project, _dir|
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.start
      begin
        snapshot = wait_for { source.current }
        refute_nil snapshot
        assert_operator snapshot.rows.size, :>=, 1
        assert_equal project, snapshot.rows.first.project_name
      ensure
        thread = source.instance_variable_get(:@thread)
        source.stop
      end

      refute_includes Thread.list, thread
      assert_nil source.last_error
    end
  end

  def test_refresh_now_is_active_only_and_does_not_scan_archive
    with_direct_project do |_project, hive_state|
      active = write_task(
        hive_state, "1-inbox", "active-task-260828-abcd", marker: "WAITING", id: 1
      )
      write_task(
        hive_state, "9-done", "patrol-history-260828-abcd", marker: "COMPLETE", id: 2
      )
      source = Hive::Tui::StateSource.new

      snapshot = source.refresh_now

      assert_equal [ File.basename(active) ], snapshot.rows.map(&:slug)
      assert_empty snapshot.archive_rows
      assert_nil source.instance_variable_get(:@archive_refresh_thread)
    ensure
      source&.stop
    end
  end

  def test_archive_is_loaded_only_after_an_explicit_request
    with_direct_project do |_project, hive_state|
      active = write_task(
        hive_state, "1-inbox", "active-task-260828-bcde", marker: "WAITING", id: 1
      )
      archived = write_task(
        hive_state, "9-done", "patrol-history-260828-bcde", marker: "COMPLETE", id: 2
      )
      source = Hive::Tui::StateSource.new
      source.refresh_now

      source.request_archive_refresh
      snapshot = wait_for do
        current = source.current
        current if current&.archive_rows&.any? { |row| row.folder == archived }
      end

      refute_nil snapshot
      assert_equal [ File.basename(active) ], snapshot.rows.map(&:slug)
      assert_equal [ File.basename(archived) ], snapshot.archive_rows.map(&:slug)
      assert_nil source.last_error
    ensure
      source&.stop
    end
  end

  def test_repeated_archive_requests_coalesce_while_refresh_is_running
    with_direct_project do |_project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-coalesce", marker: "WAITING", id: 1
      )
      source = Hive::Tui::StateSource.new
      source.refresh_now
      entered = Queue.new
      release = Queue.new
      calls = 0
      source.define_singleton_method(:refresh_archive) do |_projects, generation:|
        calls += 1
        entered << true
        release.pop
      end

      source.request_archive_refresh
      entered.pop
      source.request_archive_refresh
      release << true
      assert wait_for { !source.instance_variable_get(:@archive_refresh_thread)&.alive? }

      source.refresh_now
      assert_equal 1, calls
    ensure
      source&.stop
    end
  end

  def test_active_publication_preserves_archive_published_while_it_was_building
    with_direct_project do |project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-race", marker: "WAITING", id: 1
      )
      archived = write_task(
        hive_state, "9-done", "patrol-history-260828-race", marker: "COMPLETE", id: 2
      )
      source = Hive::Tui::StateSource.new
      active_payload = source.refresh_payload_now
      admission_context = Hive::DependencySnapshot.admission_context([ project ])
      archive_payload = Hive::Commands::Status.new(archive: true).json_payload(
        [ project ], admission_context: admission_context, now: Time.now.utc
      )
      entered = Queue.new
      release = Queue.new
      original_policy_fingerprint = source.method(:policy_fingerprint_for)
      source.define_singleton_method(:policy_fingerprint_for) do |snapshot|
        entered << true
        release.pop
        original_policy_fingerprint.call(snapshot)
      end

      active_publisher = Thread.new do
        source.send(:publish_active_snapshot, active_payload)
      end
      entered.pop
      publication_mutex = source.instance_variable_get(:@publication_mutex)
      publication_mutex.synchronize do
        source.instance_variable_set(
          :@current,
          Hive::Tui::Snapshot.from_payload(
            active_payload, archive_payload: archive_payload
          )
        )
      end
      release << true
      active_publisher.join

      assert_equal [ File.basename(archived) ], source.current.archive_rows.map(&:slug)
    ensure
      release << true if defined?(release) && release.empty?
      active_publisher&.join(0.5)
      source&.stop
    end
  end

  def test_stopped_archive_refresh_cannot_publish_into_a_restarted_source
    with_direct_project do |_project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-restart", marker: "WAITING", id: 1
      )
      write_task(
        hive_state, "9-done", "archive-task-260828-restart", marker: "COMPLETE", id: 2
      )
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.refresh_now
      entered = Queue.new
      release = Queue.new
      original_capture = source.method(:capture_status_io)
      source.define_singleton_method(:capture_status_io) do |&block|
        entered << true
        release.pop
        original_capture.call(&block)
      end

      source.request_archive_refresh
      entered.pop
      stale_thread = source.instance_variable_get(:@archive_refresh_thread)
      source.stop
      assert_same stale_thread, source.instance_variable_get(:@archive_refresh_thread)
      assert stale_thread.alive?

      source.start
      release << true
      assert wait_for { !stale_thread.alive? }
      assert_empty source.current.archive_rows
    ensure
      release << true if defined?(release) && release.empty?
      source&.stop
    end
  end

  def test_restart_hands_off_from_a_timed_out_active_poller
    with_direct_project do |_project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-handoff", marker: "WAITING", id: 1
      )
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      entered = Queue.new
      release = Queue.new
      calls = 0
      original_capture = source.method(:capture_status_io)
      source.define_singleton_method(:capture_status_io) do |&block|
        calls += 1
        if calls == 1
          entered << true
          release.pop
        end
        original_capture.call(&block)
      end

      source.start
      entered.pop
      stale_thread = source.instance_variable_get(:@thread)
      source.stop
      assert stale_thread.alive?

      source.start
      replacement_thread = source.instance_variable_get(:@thread)
      refute_same stale_thread, replacement_thread
      assert replacement_thread.alive?

      release << true
      assert wait_for { calls >= 2 && source.current }
      refute stale_thread.alive?
      assert replacement_thread.alive?
    ensure
      release << true if defined?(release) && release.empty?
      source&.stop
    end
  end

  def test_active_projection_keeps_completed_prerequisite_admission
    with_direct_project do |_project, hive_state|
      prerequisite = "completed-prerequisite-260828-abcd"
      dependent = "dependent-task-260828-abcd"
      write_task(hive_state, "9-done", prerequisite, marker: "COMPLETE", id: 1)
      write_task(
        hive_state, "1-inbox", dependent, marker: "WAITING", id: 2,
        depends_on: prerequisite
      )
      source = Hive::Tui::StateSource.new

      row = source.refresh_now.rows.fetch(0)

      assert_equal dependent, row.slug
      assert_equal false, row.blocked
      assert_nil row.admission_error
    ensure
      source&.stop
    end
  end

  def test_active_refresh_publishes_one_projection_payload_and_context_pair
    source = Hive::Tui::StateSource.new
    payload = Object.new
    admission_context = Object.new
    projection = Hive::Commands::Status::ActiveProjection.new(
      payload: payload, admission_context: admission_context
    )
    status = Object.new
    status.define_singleton_method(:active_projection) { |*, **| projection }
    published = nil
    source.define_singleton_method(:publish_active_snapshot) do |received, admission_context:, **|
      published = [ received, admission_context ]
    end

    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
      with_replaced_singleton_method(Hive::Commands::Status, :new, ->(**) { status }) do
        source.send(:refresh_once)
      end
    end

    assert_same payload, published.fetch(0)
    assert_same admission_context, published.fetch(1)
  ensure
    source&.stop
  end

  def test_idle_refresh_reuses_snapshot_until_a_watched_file_changes
    with_direct_project do |_project, hive_state|
      folder = write_task(
        hive_state, "1-inbox", "watched-task-260828-abcd", marker: "WAITING", id: 1
      )
      state_file = File.join(folder, "idea.md")
      source = Hive::Tui::StateSource.new
      first = source.refresh_now

      assert_same first, source.refresh_now

      File.write(state_file, "<!-- ERROR reason=changed -->\n")
      changed = source.refresh_now
      refute_same first, changed
      assert_equal "error", changed.rows.fetch(0).marker
    ensure
      source&.stop
    end
  end

  def test_active_refresh_records_a_live_failure
    source = Hive::Tui::StateSource.new
    failure = IOError.new("active status unavailable")

    source.define_singleton_method(:capture_status_io) { raise failure }
    source.send(:refresh_once)

    assert_same failure, source.last_error
  ensure
    source&.stop
  end

  def test_filesystem_probe_failures_degrade_to_safe_markers
    source = Hive::Tui::StateSource.new
    logs = []
    project = Struct.new(:hive_state_path, :path).new("/tmp/hive-state", "/tmp/project")

    with_replaced_singleton_method(Hive::Tui::Debug, :log, ->(*args) { logs << args }) do
      with_replaced_singleton_method(Hive::Config, :global_config_path, -> { raise IOError, "registry unavailable" }) do
        assert_nil source.send(:registry_config_path)
      end
      with_replaced_singleton_method(Dir, :glob, ->(*) { raise IOError, "workflow listing unavailable" }) do
        assert_equal [ "/tmp/hive-state/workflows" ], source.send(:project_policy_paths, project)
      end
      with_replaced_singleton_method(File, :stat, ->(*) { raise IOError, "stat unavailable" }) do
        assert_instance_of Hive::Tui::StateSource::StatError, source.send(:safe_content_signature, __FILE__)
      end
      with_replaced_singleton_method(File, :mtime, ->(*) { raise IOError, "mtime unavailable" }) do
        markers = 5.times.map { source.send(:safe_mtime, __FILE__) }
        assert markers.all? { |marker| marker.is_a?(Hive::Tui::StateSource::StatError) }
      end
    end

    assert_equal 3, logs.length
    assert_match(/stat error persists \(5x\)/, logs.last.fetch(1))
  ensure
    source&.stop
  end

  def test_archive_churn_reparses_active_rows_without_loading_archive
    with_direct_project do |_project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-archive-churn", marker: "WAITING", id: 1
      )
      source = Hive::Tui::StateSource.new
      first = source.refresh_now

      write_task(
        hive_state, "9-done", "archived-task-260828-archive-churn", marker: "COMPLETE", id: 2
      )

      refute_same first, source.refresh_now
      assert_empty source.current.archive_rows
      assert_nil source.instance_variable_get(:@archive_refresh_thread)
    ensure
      source&.stop
    end
  end

  def test_refresh_payload_exposes_active_payload_and_dependency_snapshot
    with_seeded_project do |project, _dir|
      source = Hive::Tui::StateSource.new

      payload = source.refresh_payload_now

      assert_equal "hive-status", payload.fetch("schema")
      assert_equal project, payload.dig("projects", 0, "name")
      dependency = source.dependency_context_snapshot
      assert_instance_of Hive::DependencyAdmission::Context, dependency.fetch(:context)
      assert_match(/\A[0-9a-f]{64}\z/, dependency.fetch(:fingerprint))
    ensure
      source&.stop
    end
  end

  def test_refresh_payload_raises_poll_failure_without_discarding_latest_good
    source = Hive::Tui::StateSource.new
    stale_payload = { "schema" => "hive-status", "projects" => [] }
    failure = Hive::ConfigError.new("synthetic refresh failure")
    source.instance_variable_set(:@current_payload, stale_payload)
    source.define_singleton_method(:refresh_once) { @last_error = failure }

    raised = assert_raises(Hive::ConfigError) { source.refresh_payload_now }

    assert_same failure, raised
    assert_same stale_payload, source.instance_variable_get(:@current_payload)
  ensure
    source&.stop
  end

  def test_archive_failure_is_isolated_from_active_polling_and_can_retry
    with_direct_project do |_project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-cdef", marker: "WAITING", id: 1
      )
      source = Hive::Tui::StateSource.new
      source.refresh_now
      source.define_singleton_method(:capture_status_io) do |&block|
        raise IOError, "archive offline" if !defined?(@failed_once) || !@failed_once

        block.call
      ensure
        @failed_once = true
      end

      source.request_archive_refresh
      assert wait_for { source.last_error }
      assert_instance_of IOError, source.last_error
      refute_empty source.current.rows

      source.request_archive_refresh
      assert wait_for { source.last_error.nil? }
      refute_empty source.current.rows
    ensure
      source&.stop
    end
  end

  def test_degraded_archive_project_keeps_its_last_known_rows
    with_direct_project do |project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-degraded", marker: "WAITING", id: 1
      )
      archived = write_task(
        hive_state, "9-done", "archive-task-260828-degraded", marker: "COMPLETE", id: 2
      )
      source = Hive::Tui::StateSource.new
      source.refresh_now
      healthy = Hive::Commands::Status.new(archive: true).json_payload([ project ])
      degraded = Marshal.load(Marshal.dump(healthy))
      degraded_project = degraded.fetch("projects").fetch(0)
      degraded_project["error"] = "project_load_failed"
      degraded_project["tasks"] = []
      payloads = [ healthy, degraded ]
      source.define_singleton_method(:capture_status_io) { |&_| payloads.shift }

      source.send(:refresh_archive, [ project ])
      source.send(:refresh_archive, [ project ])

      assert_equal [ archived ], source.current.archive_rows.map(&:folder)
      assert_equal "project_load_failed", source.current.archive_projects.fetch(0).error
      assert_nil source.last_error
    ensure
      source&.stop
    end
  end

  def test_boot_state_and_old_snapshot_are_stalled
    source = Hive::Tui::StateSource.new
    assert source.stalled?

    source.instance_variable_set(:@current_seen_at, Time.now - 10)
    assert source.stalled?(threshold_seconds: 5)
    refute source.stalled?(threshold_seconds: 20)
  ensure
    source&.stop
  end

  def test_stop_is_safe_before_start_or_refresh
    source = Hive::Tui::StateSource.new
    assert_nil source.stop
    assert_nil source.current
  end
  def publish_tui_task_lease(folder, payload = {})
    publish_test_task_lease(
      folder, payload, state_home: Hive::Paths.state_home
    )
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
    Hive::TaskMeta.write(
      folder, id: id, slug: slug, display_name: nil, depends_on: depends_on,
      completed_at: (Time.now.utc if stage == "9-done")
    )
    state_file = File.join(folder, state_file_name(stage))
    File.write(state_file, "<!-- #{marker} -->\n")
    folder
  end

  def write_retention_workflow(hive_state, retention)
    workflows_dir = File.join(hive_state, "workflows")
    FileUtils.mkdir_p(workflows_dir)
    path = File.join(workflows_dir, "retained.yml")
    File.write(path, <<~YAML)
      id: retained
      archive_visibility_retention_days: #{retention}
      stages:
        - name: one
          kind: terminal
          state_file: one.md
        - name: two
          kind: terminal
          state_file: two.md
        - name: three
          kind: terminal
          state_file: three.md
        - name: four
          kind: terminal
          state_file: four.md
        - name: five
          kind: terminal
          state_file: five.md
        - name: six
          kind: terminal
          state_file: six.md
        - name: seven
          kind: terminal
          state_file: seven.md
        - name: eight
          kind: terminal
          state_file: eight.md
        - name: done
          kind: terminal
          state_file: done.md
    YAML
    path
  end

  def state_file_name(stage)
    _, stage_name = Hive::Stages.parse(stage)
    Hive::Task::STATE_FILES.fetch(stage_name)
  end

  def test_refresh_once_reparses_when_state_file_mtime_changes
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:active_projection) do |projects, **kwargs|
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

      assert_equal 2, calls, "state-file mtime changes must invalidate the ordinary snapshot"
    end
  end

  def test_refresh_once_reparses_when_active_task_folder_mtime_changes
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:active_projection) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      folder = source.current.rows.first.folder
      File.write(File.join(folder, "brainstorm.md"), "# New artifact\n")
      changed_at = Time.now + 5
      File.utime(changed_at, changed_at, folder)
      source.send(:refresh_once)

      assert_equal 2, calls,
                   "active task artifact changes must invalidate the ordinary snapshot"
    end
  end

  def test_refresh_once_reparses_when_task_lease_appears
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:active_projection) do |projects, **kwargs|
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

      publish_tui_task_lease(row.folder)
      source.send(:refresh_once)

      refute_same first, source.current
      assert_equal 2, calls, "task lease changes must invalidate the cached snapshot"
      assert_equal "agent_running", source.current.rows.first.action_key
      assert_equal true, source.current.rows.first.live_task_lock
    end
  end

  def test_refresh_once_reparses_when_task_lease_disappears
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:active_projection) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      folder = source.current.rows.first.folder
      held = publish_tui_task_lease(folder)
      source.send(:refresh_once)
      locked = source.current
      assert_equal "agent_running", locked.rows.first.action_key

      calls_before_release = calls
      Hive::Lock.task_lease_repository.release(folder, lock_id: held.fetch("lock_id"))
      source.send(:refresh_once)

      refute_same locked, source.current
      assert_operator calls, :>, calls_before_release,
                      "task lease release must invalidate the cached snapshot"
      assert_equal "ready_to_brainstorm", source.current.rows.first.action_key
      assert_equal false, source.current.rows.first.live_task_lock
    end
  end

  def test_refresh_once_reparses_when_task_lease_payload_changes
    with_seeded_project do |_project, _dir|
      calls = 0
      patch = Module.new do
        define_method(:active_projection) do |projects, **kwargs|
          calls += 1
          super(projects, **kwargs)
        end
      end
      Hive::Commands::Status.prepend(patch)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      row = source.current.rows.first
      held = publish_tui_task_lease(row.folder)
      source.send(:refresh_once)
      locked = source.current

      calls_before_update = calls
      Hive::Lock.task_lease_repository.update(
        row.folder, { "phase" => "updated" }, lock_id: held.fetch("lock_id")
      )
      source.send(:refresh_once)

      refute_same locked, source.current
      assert_operator calls, :>, calls_before_update,
                      "task lease payload changes must invalidate the cached snapshot"
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

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)

      fingerprint_paths = source.instance_variable_get(:@mtime_fingerprint).keys
      assert_includes fingerprint_paths, active_folder
      assert_includes fingerprint_paths, File.join(active_folder, "task.md")
      refute_includes fingerprint_paths, archived_folder
      refute_includes fingerprint_paths, File.join(archived_folder, "task.md")
      assert_includes fingerprint_paths, Hive::Paths.runtime_control_plane_path
      assert_includes fingerprint_paths, "#{Hive::Paths.runtime_control_plane_path}-wal"
    end
  end

  def test_idle_policy_fingerprint_excludes_archived_metadata
    with_direct_project do |_project, hive_state|
      active_folder = write_state_task(
        hive_state, "4-execute", "active-policy-260626-abcd",
        marker: "EXECUTE_COMPLETE", id: 1
      )
      archived_folder = write_state_task(
        hive_state, "9-done", "archived-policy-260626-abcd",
        marker: "COMPLETE", id: 2
      )
      Hive::TaskMeta.write(
        archived_folder, id: 2, slug: File.basename(archived_folder), display_name: nil,
        completed_at: Time.now.utc - (10 * 86_400)
      )
      source = Hive::Tui::StateSource.new
      source.send(:refresh_once)
      fingerprint = source.send(:policy_fingerprint_for, source.current)

      assert_includes fingerprint, File.join(active_folder, "meta.yml")
      refute_includes fingerprint, File.join(archived_folder, "meta.yml")
    ensure
      source&.stop
    end
  end

  def test_new_folder_in_non_last_custom_project_surfaces_via_mtime_gate
    with_tmp_global_config do |home|
      custom_state = write_custom_workflow_project(home, name: "custom", workflow: "my-flow")
      seed = File.join(custom_state, "stages", "2-work", "seed-task-260626-abcd")
      FileUtils.mkdir_p(seed)
      Hive::TaskMeta.write(seed, id: 1, slug: "seed-task-260626-abcd",
                           display_name: nil, workflow: "my-flow")
      File.write(File.join(seed, "work.md"), "<!-- COMPLETE -->\n")

      # Register a DEFAULT-workflow project AFTER the custom one so load! leaves
      # the default overlay registered last — the exact condition under which a
      # union-derived watch set would omit the custom project's 2-work dir.
      _coding, coding_state = add_direct_project(home, name: "coding")
      write_state_task(coding_state, "4-execute", "exec-task-260626-efgh",
                       marker: "EXECUTE_COMPLETE", id: 2)

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      refute_includes source.current.rows.map(&:slug), "new-task-260626-ijkl"

      new_task = File.join(custom_state, "stages", "2-work", "new-task-260626-ijkl")
      FileUtils.mkdir_p(new_task)
      Hive::TaskMeta.write(new_task, id: 3, slug: "new-task-260626-ijkl",
                           display_name: nil, workflow: "my-flow")
      File.write(File.join(new_task, "work.md"), "<!-- COMPLETE -->\n")
      # A child folder bumps the 2-work dir mtime; push it past 1s FS
      # granularity so the assertion pins watch-set membership, not FS timing.
      File.utime(Time.now + 5, Time.now + 5, File.join(custom_state, "stages", "2-work"))
      # Pin the 3s liveness fallback OFF so a pass can only come from the mtime
      # gate, never the time-based reparse.
      source.instance_variable_set(:@last_active_parse_at, Time.now)
      source.send(:refresh_once)

      assert_includes source.current.rows.map(&:slug), "new-task-260626-ijkl",
                      "a new task in a non-last custom project's active stage must surface via the mtime gate"
    ensure
      source&.stop
      Hive::Workflows::Project.reset! if defined?(Hive::Workflows::Project)
    end
  end

  def test_policy_fingerprint_evicts_obsolete_content_signature_paths
    with_direct_project do |_project, hive_state|
      write_state_task(
        hive_state, "4-execute", "active-cache-260626-abcd",
        marker: "EXECUTE_COMPLETE", id: 1
      )
      source = Hive::Tui::StateSource.new
      source.send(:refresh_once)
      obsolete = File.join(hive_state, "stages", "9-done", "gone", "meta.yml")
      source.instance_variable_get(:@file_signature_cache)[obsolete] = {
        identity: [ :old ], signature: [ :old ]
      }

      source.send(:policy_fingerprint_for, source.current)

      refute_includes source.instance_variable_get(:@file_signature_cache), obsolete
    ensure
      source&.stop
    end
  end

  def test_same_size_active_metadata_edit_with_preserved_mtime_reparses
    with_direct_project do |_project, hive_state|
      folder = write_task(hive_state, "1-inbox", "metadata-task", marker: "WAITING", id: 1)
      meta = File.join(folder, "meta.yml")
      Hive::TaskMeta.write(folder, id: 1, slug: "metadata-task", display_name: "Before")
      source = Hive::Tui::StateSource.new
      first = source.refresh_now
      before = File.stat(meta)
      File.write(meta, File.read(meta).sub("Before", "After!"))
      File.utime(before.atime, before.mtime, meta)

      refute_same first, source.refresh_now
      assert_equal "After!", source.current.rows.first.display_name
      assert_empty source.current.archive_rows
    ensure
      source&.stop
    end
  end

  def test_same_size_policy_edit_and_liveness_fallback_never_scan_archive
    with_direct_project do |_project, hive_state|
      write_task(hive_state, "1-inbox", "policy-task", marker: "WAITING", id: 1)
      policy = write_retention_workflow(hive_state, 7)
      source = Hive::Tui::StateSource.new
      first = source.refresh_now
      before = File.stat(policy)
      File.write(policy, File.read(policy).sub("retention_days: 7", "retention_days: 1"))
      File.utime(before.atime, before.mtime, policy)
      second = source.refresh_now
      refute_same first, second
      source.instance_variable_set(:@last_active_parse_at, Time.now - 4)
      refute_same second, source.refresh_now
      assert_empty source.current.archive_rows
      assert_nil source.instance_variable_get(:@archive_refresh_thread)
    ensure
      source&.stop
    end
  end

  def test_repeated_content_stat_failures_always_invalidate
    source = Hive::Tui::StateSource.new
    with_replaced_singleton_method(File, :stat, ->(*) { raise IOError, "offline" }) do
      first = source.send(:safe_content_signature, __FILE__)
      second = source.send(:safe_content_signature, __FILE__)
      assert_instance_of Hive::Tui::StateSource::StatError, first
      refute_equal first, second
    end
  ensure
    source&.stop
  end

  def test_explicit_archive_refresh_removes_deleted_rows_without_ghosts
    with_direct_project do |project, hive_state|
      folder = write_task(hive_state, "9-done", "deleted-history", marker: "COMPLETE", id: 1)
      source = Hive::Tui::StateSource.new
      source.refresh_now
      source.send(:refresh_archive, [ project ])
      assert_equal [ folder ], source.current.archive_rows.map(&:folder)
      FileUtils.rm_rf(folder)
      source.send(:refresh_archive, [ project ])
      assert_empty source.current.archive_rows
    ensure
      source&.stop
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
      assert_nil row.blocked_by
      assert_nil row.dependency_stage
      assert_nil row.admission_error
    end
  end

  def test_active_reparse_preserves_archived_transitive_dependency_wait
    with_direct_project do |_project, hive_state|
      write_state_task(hive_state, "7-artifacts", "upstream-task-260626-abcd",
                       marker: "ARTIFACTS_COMPLETE", id: 1)
      write_state_task(hive_state, "9-done", "archived-base-260626-abcd",
                       marker: "COMPLETE", id: 2, depends_on: "upstream-task-260626-abcd")
      dependent = write_state_task(
        hive_state, "4-execute", "dependent-task-260626-abcd",
        marker: "EXECUTE_COMPLETE", id: 3, depends_on: "archived-base-260626-abcd"
      )
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)

      File.utime(Time.now + 5, Time.now + 5, File.join(dependent, "task.md"))
      source.send(:refresh_once)
      row = source.current.rows.find { |candidate| candidate.slug == "dependent-task-260626-abcd" }

      assert_equal true, row.blocked
      assert_equal "upstream-task-260626-abcd", row.blocked_by
      assert_equal "7-artifacts", row.dependency_stage
      assert_nil row.admission_error
    ensure
      source&.stop
    end
  end

  def test_background_archive_refresh_preserves_registered_repository_identity
    with_tmp_global_config do |home|
      app, app_state = add_direct_project(home, name: "app")
      data, data_state = add_direct_project(home, name: "data")
      identities = {
        app.fetch("path") => "github.com/acme/app",
        data.fetch("path") => "github.com/acme/data"
      }
      identities.each do |root, identity|
        system("git", "init", "-q", root, out: File::NULL, err: File::NULL)
        system("git", "-C", root, "remote", "add", "origin", "https://#{identity}.git",
               out: File::NULL, err: File::NULL)
      end
      config_path = File.join(home, "config.yml")
      config = YAML.safe_load(File.read(config_path))
      config.fetch("registered_projects").each do |entry|
        entry["repository_identity"] = identities.fetch(entry.fetch("path"))
      end
      File.write(config_path, config.to_yaml)
      write_state_task(data_state, "9-done", "data-base-260626-abcd",
                       marker: "COMPLETE", id: 1)
      write_state_task(app_state, "9-done", "app-done-260626-abcd",
                       marker: "COMPLETE", id: 2, depends_on: "data:data-base-260626-abcd")
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 0.05)
      source.send(:refresh_once)
      source.request_archive_refresh
      source.send(:start_archive_refresh_if_needed)
      assert wait_for { !source.instance_variable_get(:@archive_refresh_thread)&.alive? }

      source.send(:refresh_once)
      row = source.current.archive_rows.find { |candidate| candidate.slug == "app-done-260626-abcd" }
      assert_nil row.admission_error
    ensure
      source&.stop
    end
  end
end
