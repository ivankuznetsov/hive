require "test_helper"
require "hive/completed_at_backfiller"

class CompletedAtBackfillerTest < Minitest::Test
  include HiveTestHelper
  BackfillTask = Data.define(:folder, :hive_state_path)
  MemoryCursor = Struct.new(:values) do
    def read(state) = values[state]
    def write(state, folder) = values[state] = folder
  end

  def test_backfills_once_from_terminal_transition_history
    with_archived_task do |task, state|
      backfiller = Hive::CompletedAtBackfiller.new

      first = backfiller.completed_at_for(task)
      first_head = run!("git", "-C", state, "rev-parse", "HEAD").strip
      second = backfiller.completed_at_for(Hive::Task.new(task.folder))

      assert_equal Time.utc(2026, 7, 19, 8, 0, 0), first
      assert_equal first, second
      assert_equal "2026-07-19T08:00:00Z", Hive::TaskMeta.read(task.folder)[:completed_at]
      assert_equal first_head, run!("git", "-C", state, "rev-parse", "HEAD").strip
    end
  end

  def test_failed_persistence_restores_metadata_and_fails_open
    with_archived_task do |task, _state|
      backfiller = Hive::CompletedAtBackfiller.new
      backfiller.define_singleton_method(:commit) { |_task| raise Hive::GitError, "commit failed" }

      value = nil
      _out, err = capture_io { value = backfiller.completed_at_for(task) }

      assert_nil value
      refute Hive::TaskMeta.read(task.folder).key?(:completed_at)
      assert_includes err, "keeping task visible"
    end
  end

  def test_task_deleted_while_waiting_for_commit_lock_is_not_recreated
    with_archived_task do |task, _state|
      observed_timeout = nil
      replacement = lambda do |_path, timeout:, &block|
        observed_timeout = timeout
        FileUtils.rm_rf(task.folder)
        block.call
      end

      with_replaced_singleton_method(Hive::Lock, :with_commit_lock, replacement) do
        assert_nil Hive::CompletedAtBackfiller.new.completed_at_for(task)
      end

      assert_operator observed_timeout, :<=, Hive::CompletedAtBackfiller::REFRESH_DEADLINE_SECONDS
      refute File.exist?(task.folder)
    end
  end

  def test_call_stops_attempting_tasks_at_the_refresh_deadline
    now = 0.0
    tasks = 5.times.map { |index| BackfillTask.new("/task-#{index}", "/state") }
    backfiller = Hive::CompletedAtBackfiller.new(
      batch_size: 5, deadline_seconds: 1.0, monotonic_clock: -> { now },
      cursor_store: MemoryCursor.new({})
    )
    attempted = []
    backfiller.define_singleton_method(:completed_at_for) do |task, deadline:|
      attempted << [ task.folder, deadline ]
      now += 0.6
      nil
    end

    backfiller.call(tasks)

    assert_equal %w[/task-0 /task-1], attempted.map(&:first)
    assert attempted.all? { |_folder, deadline| deadline == 1.0 }
  end

  def test_shared_refresh_deadline_bounds_multiple_project_batches
    now = 0.0
    cursor = MemoryCursor.new({})
    backfiller = Hive::CompletedAtBackfiller.new(
      batch_size: 2, deadline_seconds: 1.0, monotonic_clock: -> { now },
      cursor_store: cursor, shared_refresh_deadline: true
    )
    attempted = []
    backfiller.define_singleton_method(:completed_at_for) do |task, deadline:|
      attempted << [ task.folder, deadline ]
      now += 0.6
      nil
    end
    first_project = 2.times.map { |index| BackfillTask.new("/first-#{index}", "/first-state") }
    second_project = 2.times.map { |index| BackfillTask.new("/second-#{index}", "/second-state") }

    backfiller.call(first_project)
    backfiller.call(second_project)

    assert_equal %w[/first-0 /first-1], attempted.map(&:first)
    assert attempted.all? { |_folder, deadline| deadline == 1.0 }
    refute cursor.values.key?("/second-state"),
           "an exhausted fleet refresh budget must not advance an unattempted project's cursor"
  end

  def test_rotating_batches_advance_past_persistent_failures
    tasks = 3.times.map { |index| BackfillTask.new("/task-#{index}", "/state") }
    cursor = MemoryCursor.new({})

    first = Hive::CompletedAtBackfiller.rotating_batch(tasks, 2, cursor_store: cursor)
    second = Hive::CompletedAtBackfiller.rotating_batch(tasks, 2, cursor_store: cursor)

    assert_equal %w[/task-0 /task-1], first.map(&:folder)
    assert_equal %w[/task-2 /task-0], second.map(&:folder)
  end

  def test_cursor_rotation_survives_new_store_instances
    with_tmp_dir do |root|
      tasks = 3.times.map { |index| BackfillTask.new("/task-#{index}", "/state") }

      first = Hive::CompletedAtBackfiller.rotating_batch(
        tasks, 2, cursor_store: Hive::CompletedAtBackfiller::CursorStore.new(root: root)
      )
      second = Hive::CompletedAtBackfiller.rotating_batch(
        tasks, 2, cursor_store: Hive::CompletedAtBackfiller::CursorStore.new(root: root)
      )

      assert_equal %w[/task-0 /task-1], first.map(&:folder)
      assert_equal %w[/task-2 /task-0], second.map(&:folder)
    end
  end

  def test_cursor_store_reads_writes_and_fails_open
    with_tmp_dir do |root|
      store = Hive::CompletedAtBackfiller::CursorStore.new(root: root)

      assert_nil store.read("/state")
      assert store.write("/state", "/task")
      assert_equal "/task", store.read("/state")

      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*) { raise IOError, "cursor unavailable" }
      ) do
        _out, err = capture_io do
          assert_nil store.write("/other-state", "/other-task")
        end
        assert_includes err, "completed_at cursor update failed"
        assert_includes err, "cursor unavailable"
      end
    end
  end

  def test_cursor_rotation_returns_a_bounded_batch_when_persistence_fails
    with_tmp_dir do |root|
      tasks = 3.times.map { |index| BackfillTask.new("/task-#{index}", "/state") }
      store = Hive::CompletedAtBackfiller::CursorStore.new(root: root)

      selected = nil
      with_replaced_singleton_method(
        Hive::AtomicFile, :write, ->(*) { raise IOError, "cursor unavailable" }
      ) do
        _out, err = capture_io { selected = store.rotating_batch(tasks, 2) }
        assert_includes err, "completed_at cursor rotation failed"
      end

      assert_equal %w[/task-0 /task-1], selected.map(&:folder)
    end
  end

  def test_completed_at_for_re_raises_interrupt_and_degrades_other_failures
    with_tmp_dir do |folder|
      task = Struct.new(:folder, :hive_state_path, :completed_at)
                   .new(folder, "/state", nil)
      backfiller = Hive::CompletedAtBackfiller.new

      with_replaced_singleton_method(
        Hive::Lock, :with_commit_lock, ->(*) { raise Interrupt }
      ) do
        assert_raises(Interrupt) { backfiller.completed_at_for(task) }
      end

      with_replaced_singleton_method(
        Hive::Lock, :with_commit_lock, ->(*) { raise RuntimeError, "lock unavailable" }
      ) do
        _out, err = capture_io do
          assert_nil backfiller.completed_at_for(task)
        end
        assert_includes err, "completed_at backfill failed"
        assert_includes err, "lock unavailable"
      end
    end
  end

  def test_archived_classification_failure_keeps_the_task_visible
    task = Struct.new(:folder, :state_file).new("/task", "/task/done.md")
    backfiller = Hive::CompletedAtBackfiller.new

    with_replaced_singleton_method(
      Hive::Markers, :current, ->(*) { raise Hive::ConfigError, "bad marker policy" }
    ) do
      _out, err = capture_io do
        refute backfiller.send(:archived?, task, config: {})
      end
      assert_includes err, "could not classify"
      assert_includes err, "bad marker policy"
    end
  end

  def test_missing_completion_source_and_expired_deadline_fail_open
    task = Struct.new(:folder).new("/task")
    backfiller = Hive::CompletedAtBackfiller.new(
      monotonic_clock: -> { 2.0 }
    )

    with_replaced_singleton_method(Hive::CompletionTime, :discover, ->(*) { nil }) do
      _out, err = capture_io do
        assert_nil backfiller.send(:persist_discovered_time, task, deadline: 3.0)
      end
      assert_includes err, "has no credible source"
    end

    assert_raises(Hive::CompletionTime::DeadlineExceeded) do
      backfiller.send(:ensure_before_deadline!, 1.0)
    end
  end

  def test_interrupt_while_persisting_restores_the_metadata_snapshot
    task = Struct.new(:folder).new("/task")
    backfiller = Hive::CompletedAtBackfiller.new(
      monotonic_clock: -> { 0.0 }
    )
    restored = []
    backfiller.define_singleton_method(:restore) do |observed_task, snapshot, deadline:|
      restored << [ observed_task, snapshot, deadline ]
    end

    with_replaced_singleton_method(
      Hive::CompletionTime, :discover, ->(*) { Time.utc(2026, 7, 1) }
    ) do
      with_replaced_singleton_method(Hive::TaskMeta, :snapshot, ->(*) { :before }) do
        with_replaced_singleton_method(
          Hive::TaskMeta, :write_completed_at_once, ->(*) { raise Interrupt }
        ) do
          assert_raises(Interrupt) do
            backfiller.send(:persist_discovered_time, task, deadline: 1.0)
          end
        end
      end
    end

    assert_equal [ [ task, :before, 1.0 ] ], restored
  end

  def test_backfill_commit_preserves_unrelated_staged_changes
    with_archived_task do |task, state|
      unrelated = File.join(state, "operator.txt")
      File.write(unrelated, "before\n")
      run!("git", "-C", state, "add", "operator.txt")
      run!("git", "-C", state, "commit", "-m", "operator seed", "--quiet")
      File.write(unrelated, "staged operator change\n")
      run!("git", "-C", state, "add", "operator.txt")

      assert Hive::CompletedAtBackfiller.new.completed_at_for(task)

      changed = run!("git", "-C", state, "show", "--format=", "--name-only", "HEAD").lines.map(&:strip)
      staged = run!("git", "-C", state, "diff", "--cached", "--name-only").lines.map(&:strip)
      assert_equal [ "stages/9-done/archive-me-260719-abcd/meta.yml" ], changed.reject(&:empty?)
      assert_equal [ "operator.txt" ], staged.reject(&:empty?)
    end
  end

  def test_backfill_reuses_captured_workflow_generation_after_descriptor_change
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      workflows = File.join(state, "workflows")
      folder = File.join(state, "stages", "1-done", "captured-generation-260724-abcd")
      FileUtils.mkdir_p([ workflows, folder ])
      descriptor = File.join(workflows, "custom.yml")
      File.write(descriptor, <<~YAML)
        id: custom
        stages:
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      File.write(File.join(folder, "done.md"), "<!-- COMPLETE -->\n")
      Hive::TaskMeta.write(
        folder, id: 1, slug: File.basename(folder), display_name: nil, workflow: "custom"
      )
      run!("git", "-C", state, "init", "-b", "hive/state", "--quiet")
      run!("git", "-C", state, "config", "user.email", "test@example.com")
      run!("git", "-C", state, "config", "user.name", "Test")
      run!("git", "-C", state, "config", "commit.gpgsign", "false")
      run!("git", "-C", state, "add", ".")
      run!("git", "-C", state, "commit", "-m", "hive: 0-work/#{File.basename(folder)} approve 0-work -> 1-done", "--quiet")
      Hive::Workflows::Project.load!(project)
      generation = Hive::Task.capture_workflow_generation(project)
      task = Hive::Task.new(folder, workflow_generation: generation)
      File.write(descriptor, <<~YAML)
        id: custom
        stages:
          - name: done
            kind: terminal
            state_file: done.md
          - name: published
            kind: terminal
            state_file: published.md
      YAML

      value = Hive::CompletedAtBackfiller.new.completed_at_for(task)

      assert value
      assert Hive::TaskMeta.read(folder)[:completed_at]
    ensure
      Hive::Workflows::Project.reset!
    end
  end

  private

  def with_archived_task
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      folder = File.join(state, "stages", "9-done", "archive-me-260719-abcd")
      FileUtils.mkdir_p(folder)
      Hive::TaskMeta.write(folder, id: 1, slug: File.basename(folder), display_name: nil)
      File.write(File.join(folder, "task.md"), "# Done\n<!-- COMPLETE -->\n")
      run!("git", "-C", state, "init", "-b", "hive/state", "--quiet")
      run!("git", "-C", state, "config", "user.email", "test@example.com")
      run!("git", "-C", state, "config", "user.name", "Test")
      run!("git", "-C", state, "config", "commit.gpgsign", "false")
      run!("git", "-C", state, "add", ".")
      with_env(
        "GIT_AUTHOR_DATE" => "2026-07-19T08:00:00Z",
        "GIT_COMMITTER_DATE" => "2026-07-19T08:00:00Z"
      ) do
        run!(
          "git", "-C", state, "commit", "-m",
          "hive: 8-finalize/#{File.basename(folder)} approve 8-finalize -> 9-done", "--quiet"
        )
      end
      yield Hive::Task.new(folder), state
    end
  ensure
    Hive::Workflows::Project.reset!
  end
end
