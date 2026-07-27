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

  def test_claude_completion_fallback_event_is_allowed
    with_tmp_dir do |dir|
      Hive::Events.emit(
        task_folder: dir,
        slug: "event-test-260522-aaaa",
        stage: "6-review",
        agent: "phase=fix pass=01",
        event_type: :claude_completion_fallback,
        message: "phase=fix pass=01 reason=turn_ended_without_stop_hook"
      )

      parsed = JSON.parse(File.read(File.join(dir, "events.jsonl")).lines.first)
      assert_equal "claude_completion_fallback", parsed.fetch("event_type")
      assert_equal "phase=fix pass=01", parsed.fetch("agent")
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
      assert_includes status, "Stage:         6-review"
      assert_includes status, "Last event:    round_complete #{Hive::Events::EM_DASH} pass done"
      assert_includes status, "Current agent: #{Hive::Events::EM_DASH}"
      assert_includes status, "agent_start  reviewer-a pass=1  reviewing"
    end
  end

  def test_current_agent_survives_past_recent_events_tail
    with_tmp_dir do |dir|
      # Open agent_start that lands well outside STATUS_TAIL_LINES (20).
      # The recent-events display ends up showing only the closing tail,
      # but the wider current-agent walk still finds the unclosed start.
      Hive::Events.emit(task_folder: dir, slug: "tail-test", stage: "6-review",
                        agent: "long-runner", event_type: :agent_start, message: "starting")
      30.times do |idx|
        Hive::Events.emit(task_folder: dir, slug: "tail-test", stage: "6-review",
                          agent: "noise-#{idx}", event_type: :stage_enter,
                          message: "noise #{idx}")
      end

      status = File.read(File.join(dir, "status.md"))
      assert_includes status, "Current agent: long-runner",
                      "current_agent must survive past STATUS_TAIL_LINES via the wider CURRENT_AGENT_WALK_LINES window"
    end
  end

  # Drives the SystemCallError rescue inside emit by making the task
  # folder unwritable instead of monkey-patching File.open. The earlier
  # form aliased File.singleton_class#open, which is process-global and
  # races against any sibling test that happens to call File.open during
  # the patched window. Stripping write permissions on the dir is fully
  # local to this test — FileUtils.mkdir_p on the pre-existing dir
  # short-circuits, then File.open(events.jsonl, WRONLY|APPEND|CREAT)
  # raises Errno::EACCES (a SystemCallError subclass) which the emit
  # rescue absorbs into a warn + nil return.
  def test_emit_swallow_system_call_errors_and_warns
    skip "root bypasses dir-write permission and would mask the EACCES path" if Process.uid.zero?
    with_tmp_dir do |dir|
      File.chmod(0o500, dir) # readable but not writable: blocks events.jsonl creation
      begin
        err = capture_io do
          assert_nil Hive::Events.emit(task_folder: dir, slug: "event-test-260522-aaaa",
                                       stage: "2-brainstorm", event_type: :stage_enter)
        end.last
        assert_includes err, "[hive.events]"
        refute File.exist?(File.join(dir, "events.jsonl"))
      ensure
        # Restore write permission so with_tmp_dir's FileUtils.rm_rf
        # cleanup can descend the directory.
        File.chmod(0o755, dir)
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
  def test_truncate_message_preserves_utf8_boundary_and_suffix
    message = "ø" * Hive::Events::MAX_MESSAGE_BYTES

    truncated = Hive::Events.truncate_message(message)

    assert truncated.valid_encoding?
    assert truncated.end_with?(Hive::Events::MESSAGE_TRUNCATION_SUFFIX)
    assert_operator truncated.bytesize, :<=, Hive::Events::MAX_MESSAGE_BYTES
  end

  def test_render_status_body_handles_empty_event_list
    body = Hive::Events.render_status_body(
      {
        "slug" => "empty-events",
        "stage" => "2-brainstorm",
        "ts" => "2026-05-25T00:00:00Z",
        "event_type" => "stage_enter",
        "message" => nil
      },
      []
    )

    assert_includes body, "- (no events yet)"
    assert_includes body, "Current agent: #{Hive::Events::EM_DASH}"
  end

  def test_read_recent_events_skips_malformed_lines_and_handles_read_errors
    with_tmp_dir do |dir|
      path = File.join(dir, "events.jsonl")
      File.write(path, "not-json\n#{JSON.generate('event_type' => 'stage_enter')}\n")

      events = Hive::Events.read_recent_events(path, 10)
      assert_equal [ "stage_enter" ], events.map { |event| event.fetch("event_type") }

      with_replaced_singleton_method(File, :open, ->(*_args) { raise Errno::EACCES }) do
        assert_equal [], Hive::Events.read_recent_events(path, 10)
      end
    end
  end

  def test_write_atomic_tolerates_fsync_unsupported
    with_tmp_dir do |dir|
      path = File.join(dir, "status.md")
      original_open = File.method(:open)
      File.define_singleton_method(:open) do |*args, **kwargs, &block|
        if block && args.first.to_s.include?(".status.md.tmp")
          original_open.call(*args, **kwargs) do |file|
            file.define_singleton_method(:fsync) { raise Errno::EINVAL }
            block.call(file)
          end
        else
          original_open.call(*args, **kwargs, &block)
        end
      end

      Hive::Events.write_atomic(path, "body\n")
      assert_equal "body\n", File.read(path)
    ensure
      File.define_singleton_method(:open, original_open) if original_open
    end
  end
end
