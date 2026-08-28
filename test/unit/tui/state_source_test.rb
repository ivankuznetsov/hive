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
        assert_equal [ :stat_error, "IOError" ], source.send(:safe_content_signature, __FILE__)
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

  def test_archive_churn_does_not_invalidate_the_active_snapshot
    with_direct_project do |_project, hive_state|
      write_task(
        hive_state, "1-inbox", "active-task-260828-archive-churn", marker: "WAITING", id: 1
      )
      source = Hive::Tui::StateSource.new
      first = source.refresh_now

      write_task(
        hive_state, "9-done", "archived-task-260828-archive-churn", marker: "COMPLETE", id: 2
      )

      assert_same first, source.refresh_now
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
end
