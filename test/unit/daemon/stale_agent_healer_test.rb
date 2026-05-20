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
               marker: "agent_working", action: "error")
    Row.new(
      project: project, slug: slug, stage: stage,
      marker: marker, folder: File.dirname(state_file), state_file: state_file,
      state_file_mtime: mtime,
      action: action, suggested_command: nil,
      claude_pid_alive: pid_alive, diagnostic: nil
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
