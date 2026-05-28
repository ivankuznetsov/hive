require "test_helper"
require "hive/task"
require "hive/bot/brainstorm_answer_writer"
require "hive/bot/brainstorm_parser"

class HiveBotBrainstormAnswerWriterTest < Minitest::Test
  include HiveTestHelper

  def with_brainstorm(content)
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "slug-260514-abcd")
      FileUtils.mkdir_p(folder)
      path = File.join(folder, "brainstorm.md")
      File.write(path, content)
      yield(path)
    end
  end

  def sample
    <<~MARKDOWN
      ## Round 1

      ### Q1. First?

      ### A1.

      ### Q2. Second?

      ### A2.

      <!-- WAITING -->
    MARKDOWN
  end

  def test_try_append_returns_nil_pair_when_write_hits_enoent
    # If the brainstorm file vanishes between lock acquisition and the atomic
    # write (Errno::ENOENT), try_append must degrade to [nil, nil] so
    # append!'s retry loop treats it like a transient miss instead of
    # crashing the poll/answer path.
    with_brainstorm(sample) do |path|
      folder = File.dirname(path)
      original = Hive::Markers.method(:write_atomic)
      Hive::Markers.define_singleton_method(:write_atomic) { |*, **| raise Errno::ENOENT }
      begin
        result = Hive::Bot::BrainstormAnswerWriter.send(:try_append, folder, path, 1, "First answer.")
      ensure
        Hive::Markers.define_singleton_method(:write_atomic, original)
      end

      assert_equal [ nil, nil ], result
    end
  end

  def test_append_writes_answer_into_empty_slot_and_keeps_marker
    with_brainstorm(sample) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "First answer."
      )

      assert_equal :written, result
      parsed = Hive::Bot::BrainstormParser.parse(path)
      assert_equal "First answer.", parsed.first.answer
      assert_includes File.read(path), "<!-- WAITING -->"
    end
  end

  def test_append_adds_newline_when_answer_slot_is_final_line
    with_brainstorm("## Round 1\n\n### Q1. First?\n\n### A1.") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "One"
      )

      assert_equal :written, result
      assert_equal "One", Hive::Bot::BrainstormParser.parse(path).first.answer
      assert_equal "## Round 1\n\n### Q1. First?\n\n### A1.\nOne\n", File.read(path)
    end
  end

  def test_sequential_writes_land_in_their_own_slots
    with_brainstorm(sample) do |path|
      Hive::Bot::BrainstormAnswerWriter.append!(brainstorm_path: path, question_n: 1, answer_text: "One")
      Hive::Bot::BrainstormAnswerWriter.append!(brainstorm_path: path, question_n: 2, answer_text: "Two")

      parsed = Hive::Bot::BrainstormParser.parse(path)
      assert_equal [ "One", "Two" ], parsed.map(&:answer)
    end
  end

  def test_first_write_wins_when_answer_already_present
    with_brainstorm(sample) do |path|
      first = Hive::Bot::BrainstormAnswerWriter.append!(brainstorm_path: path, question_n: 1, answer_text: "One")
      second = Hive::Bot::BrainstormAnswerWriter.append!(brainstorm_path: path, question_n: 1, answer_text: "Two")

      assert_equal :written, first
      assert_equal :already_answered, second
      assert_equal "One", Hive::Bot::BrainstormParser.parse(path).first.answer
    end
  end

  def test_question_not_found
    with_brainstorm(sample) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 99,
        answer_text: "Missing"
      )

      assert_equal :question_not_found, result
    end
  end

  # Q1 present, no A-line at all → answer_slot_missing (NOT
  # question_not_found, which is now reserved for "Q{n} truly absent").
  # The supervisor renders a distinct message for this so the operator
  # knows the question IS in the file and the brainstorm.md needs repair.
  def test_q_present_no_a_line_returns_answer_slot_missing
    with_brainstorm("## Round 1\n\n### Q1. First?\n") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "One"
      )

      assert_equal :answer_slot_missing, result
    end
  end

  # Regression: observed 2026-05-28 on
  # `explore-the-simplest-way-to-260528-2503` — the brainstorm agent
  # emitted `### A2.` immediately after `### Q1.` for a fresh Round 2.
  # Old writer's strict `match[1].to_i == question_n` returned no slot,
  # then the supervisor said "Question 1 was not found" — misleading
  # because Q1 IS in the file. New writer falls back to "first empty
  # A-section after Q{n}" so the operator's answer lands cleanly.
  def test_misnumbered_empty_answer_slot_is_filled_via_by_position_fallback
    content = <<~MARKDOWN
      ## Round 2

      ### Q1. Identify OpenClawd.
      ### A2.
      ### Q2. Which install path?
      ### A3.

      <!-- WAITING -->
    MARKDOWN

    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "OpenClawd.ai"
      )

      assert_equal :written, result
      after = File.read(path)
      assert_includes after, "### Q1. Identify OpenClawd.\n### A2.\nOpenClawd.ai\n",
                      "answer must be written into the mis-numbered A-slot that " \
                      "follows Q1 (the by-position fallback)"
      # Round-trip verify: the parser must read back the answer as Q1's.
      parsed = Hive::Bot::BrainstormParser.parse(path)
      assert_equal "OpenClawd.ai", parsed[0].answer,
                   "parser must accept the mis-numbered A2 under Q1 as Q1's answer"
    end
  end

  # The by-position fallback must NOT cross block boundaries. If the
  # next block (Q, round, or marker) appears before any A line, no slot.
  def test_no_slot_when_next_block_comes_before_any_a_line
    with_brainstorm("## Round 1\n\n### Q1. First?\n### Q2. Second?\n### A2.\n") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "One"
      )

      assert_equal :answer_slot_missing, result
    end
  end

  # The by-position fallback must skip past non-boundary prose lines
  # between Q{n} and the first A-section. Covers the `scan += 1`
  # increment that earlier branch tests didn't reach.
  def test_by_position_fallback_skips_prose_before_finding_answer_slot
    content = <<~MARKDOWN
      ## Round 2

      ### Q1. Multi-line question?
      Extra context that the agent added below the question heading.
      And more prose that isn't an A-line, a Q, a round, or a marker.
      ### A2.

      <!-- WAITING -->
    MARKDOWN

    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "Filled"
      )

      assert_equal :written, result, "by-position fallback must skip prose lines"
      assert_includes File.read(path), "### A2.\nFilled\n"
    end
  end

  def test_missing_task_folder_raises_invalid_task_path
    path = "/tmp/hive-missing-task/brainstorm.md"

    assert_raises(Hive::InvalidTaskPath) do
      Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "One"
      )
    end
  end

  def test_concurrent_threads_first_write_wins
    with_brainstorm(sample) do |path|
      results = Array.new(8) { Queue.new }
      threads = 8.times.map do |i|
        Thread.new do
          result = Hive::Bot::BrainstormAnswerWriter.append!(
            brainstorm_path: path,
            question_n: 1,
            answer_text: "Answer from thread #{i}"
          )
          results[i] << result
        end
      end
      threads.each(&:join)

      outcomes = results.map(&:pop)
      assert_equal 1, outcomes.count(:written), "exactly one concurrent writer should win"
      assert_equal 7, outcomes.count(:already_answered), "all other writers should see already_answered"

      saved = Hive::Bot::BrainstormParser.parse(path).first.answer
      assert_match(/Answer from thread/, saved)
    end
  end

  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end

  def test_lock_busy_emits_answer_lock_contention_with_holder_metadata
    # When a competing run holds the per-task lock for longer than the
    # retry deadline, the writer must emit :answer_lock_contention with
    # the holder's metadata so operators can grep the bot log and identify
    # the culprit (daemon dispatch, hive run, hive approve, etc).
    with_brainstorm(sample) do |path|
      task_folder = File.dirname(path)
      # Plant a held lock with this test process's PID so the stale-lock
      # check sees the holder as live (Process.kill(0, pid) succeeds) and
      # leaves the lock file in place. Without a live PID the writer would
      # treat the lock as stale, delete it, and succeed — masking the
      # contention path we're trying to exercise.
      held_holder = { "pid" => Process.pid, "op" => "approve", "slug" => "slug-260514-abcd",
                       "host" => "test-host", "started_at" => Time.utc(2026, 5, 26).iso8601 }
      File.write(File.join(task_folder, ".lock"), held_holder.to_yaml)

      logger = StubLogger.new
      # Stub the deadline to fail-fast (no need to sleep the real 5s).
      with_short_deadline do
        result = Hive::Bot::BrainstormAnswerWriter.append!(
          brainstorm_path: path,
          question_n: 1,
          answer_text: "Reply blocked by the live lock holder",
          logger: logger
        )
        assert_equal :lock_busy, result
      end

      event = logger.events.find { |name, _| name == :answer_lock_contention }
      refute_nil event, "writer must emit :answer_lock_contention when giving up on the lock"

      payload = event.last
      assert_equal task_folder, payload[:task_folder]
      assert_equal 1, payload[:question_n]
      refute_nil payload[:holder], "holder metadata from the rescued ConcurrentRunError must propagate to the event"
      assert_equal Process.pid, payload[:holder]["pid"]
      assert_equal "approve", payload[:holder]["op"]
      assert_equal "slug-260514-abcd", payload[:holder]["slug"]
    ensure
      File.delete(File.join(task_folder, ".lock")) if task_folder && File.exist?(File.join(task_folder, ".lock"))
    end
  end

  def with_short_deadline
    original = Hive::Bot::BrainstormAnswerWriter::LOCK_RETRY_DEADLINE_SEC
    Hive::Bot::BrainstormAnswerWriter.send(:remove_const, :LOCK_RETRY_DEADLINE_SEC)
    Hive::Bot::BrainstormAnswerWriter.const_set(:LOCK_RETRY_DEADLINE_SEC, 0.1)
    yield
  ensure
    Hive::Bot::BrainstormAnswerWriter.send(:remove_const, :LOCK_RETRY_DEADLINE_SEC)
    Hive::Bot::BrainstormAnswerWriter.const_set(:LOCK_RETRY_DEADLINE_SEC, original)
  end
end
