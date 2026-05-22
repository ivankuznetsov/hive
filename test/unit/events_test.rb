require "test_helper"
require "hive/events"

class EventsTest < Minitest::Test
  include HiveTestHelper

  def test_emit_writes_parseable_json_line_with_contract_keys
    with_tmp_dir do |dir|
      record = Hive::Events.emit(
        task_folder: dir,
        slug: "event-test-260522-aaaa",
        stage: "4-execute",
        agent: "claude execute-impl",
        event_type: :agent_start,
        message: "started"
      )

      assert_equal "event-test-260522-aaaa", record.fetch("slug")
      lines = File.readlines(File.join(dir, "events.jsonl"), chomp: true)
      assert_equal 1, lines.size
      parsed = JSON.parse(lines.first)
      assert_equal %w[ts slug stage agent event_type message], parsed.keys
      assert_equal "4-execute", parsed.fetch("stage")
      assert_equal "agent_start", parsed.fetch("event_type")
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, parsed.fetch("ts"))
    end
  end

  def test_sequential_emits_append_distinct_lines
    with_tmp_dir do |dir|
      Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "2-brainstorm",
                        event_type: :stage_enter, message: "enter")
      Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "2-brainstorm",
                        event_type: :round_waiting, message: "waiting")

      lines = File.readlines(File.join(dir, "events.jsonl"), chomp: true)
      assert_equal 2, lines.size
      assert_equal %w[stage_enter round_waiting], lines.map { |line| JSON.parse(line).fetch("event_type") }
    end
  end

  def test_unknown_event_type_raises
    with_tmp_dir do |dir|
      assert_raises(ArgumentError) do
        Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "2-brainstorm",
                          event_type: :bogus)
      end
    end
  end

  def test_status_md_rerenders_latest_event_and_recent_tail
    with_tmp_dir do |dir|
      Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "6-review",
                        agent: "reviewer-a pass=1", event_type: :agent_start, message: "reviewing")
      Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "6-review",
                        agent: "reviewer-a pass=1", event_type: :agent_end, message: "done")
      Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "6-review",
                        event_type: :round_complete, message: "pass done")

      status = File.read(File.join(dir, "status.md"))
      assert_includes status, "# Status: event-test-260522-aaaa"
      assert_includes status, "Stage:        6-review"
      assert_includes status, "Last event:   round_complete - pass done"
      assert_includes status, "Current agent: -"
      assert_includes status, "agent_start  reviewer-a pass=1  reviewing"
    end
  end

  def test_emit_swallow_system_call_errors_and_warns
    with_tmp_dir do |dir|
      File.singleton_class.alias_method(:__hive_events_test_open, :open)
      File.define_singleton_method(:open) { |*| raise Errno::ENOSPC, "full" }
      err = capture_io do
        assert_nil Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "2-brainstorm",
                                     event_type: :stage_enter)
      end.last
      assert_includes err, "[hive.events]"
      refute File.exist?(File.join(dir, "events.jsonl"))
    ensure
      if File.singleton_class.method_defined?(:__hive_events_test_open)
        File.singleton_class.alias_method(:open, :__hive_events_test_open)
        File.singleton_class.remove_method(:__hive_events_test_open)
      end
    end
  end

  def test_concurrent_emits_keep_every_line_parseable
    with_tmp_dir do |dir|
      threads = 5.times.map do |idx|
        Thread.new do
          10.times do |n|
            Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa", stage: "6-review",
                              agent: "agent-#{idx}", event_type: :agent_start, message: "event #{n}")
          end
        end
      end
      threads.each(&:join)

      lines = File.readlines(File.join(dir, "events.jsonl"), chomp: true)
      assert_equal 50, lines.size
      lines.each { |line| assert_kind_of Hash, JSON.parse(line) }
    end
  end
end
