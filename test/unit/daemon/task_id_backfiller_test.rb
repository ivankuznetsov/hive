require "test_helper"
require "tmpdir"
require "hive/task_meta"
require "hive/daemon/task_id_backfiller"
require "hive/daemon/status_consumer"

# Backfiller's job: for tasks whose meta.yml has no id (created outside
# `hive new`), allocate the next id, write it into the meta, and commit —
# exactly once per task, bounded by max_per_tick, logging-without-writing
# under dry_run, and never raising out of #backfill. These tests inject a
# fake allocator and commit hook so no real task counter or git repo is
# touched.
class HiveDaemonTaskIdBackfillerTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row

  class FakeLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end

  # Hands back monotonically increasing ids so assignment is observable
  # without a real TaskCounter; records how many times it was called.
  class FakeAllocator
    attr_reader :calls
    def initialize(start: 100, return_nil: false)
      @next = start
      @calls = 0
      @return_nil = return_nil
    end

    def call
      @calls += 1
      return nil if @return_nil

      id = @next
      @next += 1
      id
    end
  end

  def setup
    @logger = FakeLogger.new
    @committed = []
  end

  def teardown
    Array(@dirs).each { |d| FileUtils.remove_entry(d) if File.directory?(d) }
  end

  # `id: nil` writes a meta with no id — the pre-`hive new` shape this
  # backfiller targets. Pass an Integer to simulate an already-assigned task.
  def make_task_folder(id:, slug: "my-slug")
    dir = Dir.mktmpdir("hive-id-backfill")
    @dirs ||= []
    @dirs << dir
    Hive::TaskMeta.write(dir, id: id, slug: slug, display_name: "Name")
    dir
  end

  def make_row(folder, project: "p", slug: "s", stage: "2-brainstorm")
    Row.new(
      project: project, slug: slug, stage: stage,
      marker: "waiting", marker_attrs: {}, folder: folder,
      state_file: File.join(folder, "task.md"), state_file_mtime: Time.now,
      action: "ready_to_plan", suggested_command: nil,
      claude_pid_alive: false, live_task_lock: nil, diagnostic: nil
    )
  end

  def backfiller(allocate:, dry_run: false, max_per_tick: 5)
    Hive::Daemon::TaskIdBackfiller.new(
      logger: @logger, dry_run: dry_run, max_per_tick: max_per_tick,
      allocate: allocate, commit: ->(row) { @committed << row.slug }
    )
  end

  def backfill_events
    @logger.events.select { |name, _| name == :task_id_backfill }
  end

  def fatal_events
    @logger.events.select { |name, _| name == :fatal }
  end

  def test_assigns_id_to_task_with_missing_id
    folder = make_task_folder(id: nil)
    alloc = FakeAllocator.new(start: 100)

    backfiller(allocate: alloc).backfill([ make_row(folder, slug: "s1") ])

    assert_equal 100, Hive::TaskMeta.read(folder)[:id], "the allocated id must be written to meta"
    assert_equal [ "s1" ], @committed, "the assigned id must be committed on hive/state"
    assert_equal 1, backfill_events.size
    assert_equal 100, backfill_events.first[1][:id]
  end

  def test_preserves_other_meta_fields_when_assigning_id
    folder = make_task_folder(id: nil, slug: "keep-me")
    Hive::TaskMeta.write(folder, id: nil, slug: "keep-me", display_name: "Keep Me", depends_on: "42")

    backfiller(allocate: FakeAllocator.new(start: 7)).backfill([ make_row(folder) ])

    meta = Hive::TaskMeta.read(folder)
    assert_equal 7, meta[:id]
    assert_equal "keep-me", meta[:slug]
    assert_equal "Keep Me", meta[:display_name], "display_name must survive id assignment"
    assert_equal "42", meta[:depends_on], "depends_on must survive id assignment"
  end

  def test_skips_task_that_already_has_an_id
    folder = make_task_folder(id: 55)
    alloc = FakeAllocator.new(start: 100)

    backfiller(allocate: alloc).backfill([ make_row(folder) ])

    assert_equal 55, Hive::TaskMeta.read(folder)[:id], "an existing id must not be overwritten"
    assert_equal 0, alloc.calls, "no allocation for a task that already has an id"
    assert_empty @committed
    assert_empty backfill_events
  end

  def test_dry_run_logs_without_allocating_or_writing
    folder = make_task_folder(id: nil)
    alloc = FakeAllocator.new(start: 100)

    backfiller(allocate: alloc, dry_run: true).backfill([ make_row(folder) ])

    assert_nil Hive::TaskMeta.read(folder)[:id], "dry_run must not write an id"
    assert_equal 0, alloc.calls, "dry_run must not allocate"
    assert_empty @committed, "dry_run must not commit"
    assert_equal 1, backfill_events.size
    assert backfill_events.first[1][:dry_run], "dry_run event must be flagged"
  end

  def test_max_per_tick_bounds_assignments
    folders = Array.new(4) { |i| make_task_folder(id: nil, slug: "s#{i}") }
    rows = folders.each_with_index.map { |f, i| make_row(f, slug: "s#{i}") }

    backfiller(allocate: FakeAllocator.new(start: 100), max_per_tick: 2).backfill(rows)

    assigned = folders.count { |f| !Hive::TaskMeta.read(f)[:id].nil? }
    assert_equal 2, assigned, "no more than max_per_tick ids assigned in one tick"
    assert_equal 2, @committed.size
  end

  def test_allocator_returning_nil_assigns_nothing
    folder = make_task_folder(id: nil)

    backfiller(allocate: FakeAllocator.new(return_nil: true)).backfill([ make_row(folder) ])

    assert_nil Hive::TaskMeta.read(folder)[:id], "a nil allocation must leave the id unset"
    assert_empty @committed
    assert_empty backfill_events
  end

  def test_does_not_resurrect_a_vanished_folder
    missing = File.join(Dir.tmpdir, "hive-id-backfill-gone-#{Process.pid}-#{rand(1_000_000)}")
    FileUtils.rm_rf(missing)
    alloc = FakeAllocator.new(start: 100)

    backfiller(allocate: alloc).backfill([ make_row(missing, slug: "gone") ])

    refute File.exist?(missing), "a row whose folder vanished must not be recreated by id assignment"
    assert_equal 0, alloc.calls, "no id allocated for a vanished folder"
    assert_empty @committed
    assert_empty backfill_events
  end

  def test_never_raises_on_bad_row_and_keeps_processing
    good = make_task_folder(id: nil, slug: "good")
    rows = [ Object.new, make_row(good, slug: "good") ] # first row has no #folder

    # The contract is that #backfill never raises; a bad row is skipped and
    # the rest of the set still processes.
    backfiller(allocate: FakeAllocator.new(start: 100)).backfill(rows)

    assert_equal 100, Hive::TaskMeta.read(good)[:id], "a bad row must not block the rest of the set"
  end
end
