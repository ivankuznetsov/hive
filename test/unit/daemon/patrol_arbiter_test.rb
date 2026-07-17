require "test_helper"
require "json"
require "hive/daemon/patrol_arbiter"

class HiveDaemonPatrolArbiterTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  class CandidateSource
    attr_accessor :items

    def initialize(items)
      @items = items
    end

    def candidates(now:)
      @items
    end
  end

  def test_alternates_per_project_only_after_spawn_is_committed
    with_tmp_dir do |dir|
      ordinary = CandidateSource.new([ { project: "p1", patrol_kind: :ordinary } ])
      architecture = CandidateSource.new([ { project: "p1", patrol_kind: :architecture, merged_at: T0.iso8601 } ])
      arbiter = Hive::Daemon::PatrolArbiter.new(
        ordinary_scheduler: ordinary,
        architecture_scheduler: architecture,
        state_path: File.join(dir, "arbiter.json")
      )

      first = arbiter.candidates(now: T0).then { |items| assert_equal(1, items.size); items.fetch(0) }
      assert_equal :architecture, first.fetch(:patrol_kind)
      assert_equal :architecture, arbiter.candidates(now: T0 + 1).fetch(0).fetch(:patrol_kind),
                   "selection alone must not consume the turn"

      arbiter.commit(first, now: T0 + 2)
      assert_equal :ordinary, arbiter.candidates(now: T0 + 3).fetch(0).fetch(:patrol_kind)

      reloaded = Hive::Daemon::PatrolArbiter.new(
        ordinary_scheduler: ordinary,
        architecture_scheduler: architecture,
        state_path: File.join(dir, "arbiter.json")
      )
      assert_equal :ordinary, reloaded.candidates(now: T0 + 4).fetch(0).fetch(:patrol_kind),
                   "the alternation cursor must survive daemon restart"
    end
  end

  def test_selects_oldest_architecture_job_and_does_not_mix_projects
    with_tmp_dir do |dir|
      ordinary = CandidateSource.new([ { project: "p2", patrol_kind: :ordinary } ])
      architecture = CandidateSource.new([
        { project: "p1", patrol_kind: :architecture, job_id: "new", merged_at: (T0 + 5).iso8601 },
        { project: "p1", patrol_kind: :architecture, job_id: "old", merged_at: T0.iso8601 }
      ])
      arbiter = Hive::Daemon::PatrolArbiter.new(
        ordinary_scheduler: ordinary,
        architecture_scheduler: architecture,
        state_path: File.join(dir, "arbiter.json")
      )

      selected = arbiter.candidates(now: T0)
      assert_equal %w[old], selected.select { |item| item[:project] == "p1" }.map { |item| item[:job_id] }
      assert_equal [ :ordinary ], selected.select { |item| item[:project] == "p2" }.map { |item| item[:patrol_kind] }
    end
  end

  def test_corrupt_or_newer_state_fails_closed
    with_tmp_dir do |dir|
      path = File.join(dir, "arbiter.json")
      File.write(path, JSON.generate("schema" => "hive-patrol-arbiter", "schema_version" => 99, "projects" => {}))
      arbiter = Hive::Daemon::PatrolArbiter.new(
        ordinary_scheduler: CandidateSource.new([]),
        architecture_scheduler: CandidateSource.new([]),
        state_path: path
      )

      assert_raises(Hive::Daemon::PatrolArbiter::StateError) { arbiter.candidates(now: T0) }
    end
  end

  def test_dry_run_never_persists_the_cursor
    with_tmp_dir do |dir|
      path = File.join(dir, "arbiter.json")
      item = { project: "p1", patrol_kind: :architecture, job_id: "job" }
      arbiter = Hive::Daemon::PatrolArbiter.new(
        ordinary_scheduler: CandidateSource.new([]),
        architecture_scheduler: CandidateSource.new([ item ]),
        state_path: path, dry_run: true
      )

      arbiter.commit(arbiter.candidates(now: T0).first, now: T0)

      refute File.exist?(path)
    end
  end

  def test_invalid_timestamp_and_project_cursor_fail_closed
    with_tmp_dir do |dir|
      path = File.join(dir, "arbiter.json")
      invalid_cursors = [
        { "" => { "last_selected" => "architecture", "updated_at" => T0.iso8601 } },
        { "p1" => { "last_selected" => "unknown", "updated_at" => T0.iso8601 } },
        { "p1" => { "last_selected" => "architecture", "updated_at" => "not-a-time" } }
      ]

      invalid_cursors.each do |projects|
        File.write(
          path,
          JSON.generate(
            "schema" => "hive-patrol-arbiter",
            "schema_version" => 1,
            "projects" => projects
          )
        )
        arbiter = Hive::Daemon::PatrolArbiter.new(
          ordinary_scheduler: CandidateSource.new([]),
          architecture_scheduler: CandidateSource.new([]),
          state_path: path
        )

        assert_raises(Hive::Daemon::PatrolArbiter::StateError) do
          arbiter.candidates(now: T0)
        end
      end
    end
  end

  def test_architecture_candidates_with_missing_or_invalid_times_sort_as_oldest
    with_tmp_dir do |dir|
      architecture = CandidateSource.new([
        { project: "p1", patrol_kind: :architecture, job_id: "dated", merged_at: T0.iso8601 },
        { project: "p1", patrol_kind: :architecture, job_id: "missing", merged_at: nil },
        { project: "p2", patrol_kind: :architecture, job_id: "invalid", merged_at: "not-a-time" }
      ])
      arbiter = Hive::Daemon::PatrolArbiter.new(
        ordinary_scheduler: nil,
        architecture_scheduler: architecture,
        state_path: File.join(dir, "arbiter.json")
      )

      selected = arbiter.candidates(now: T0)

      assert_equal "missing", selected.find { |item| item[:project] == "p1" }.fetch(:job_id)
      assert_equal "invalid", selected.find { |item| item[:project] == "p2" }.fetch(:job_id)
    end
  end

  def test_persist_tolerates_directory_fsync_not_supported
    with_tmp_dir do |dir|
      path = File.join(dir, "arbiter.json")
      item = { project: "p1", patrol_kind: :architecture, job_id: "job" }
      arbiter = Hive::Daemon::PatrolArbiter.new(
        ordinary_scheduler: CandidateSource.new([]),
        architecture_scheduler: CandidateSource.new([ item ]),
        state_path: path
      )
      original_open = File.method(:open)
      with_replaced_singleton_method(File, :open, lambda { |target, *args, **kwargs, &block|
        if File.expand_path(target) == File.expand_path(dir)
          raise Errno::EINVAL, target
        end

        original_open.call(target, *args, **kwargs, &block)
      }) do
        assert_equal item, arbiter.commit(item, now: T0)
      end

      assert File.file?(path), "the durable write succeeds even where directory fsync is unsupported"
    end
  end
end
