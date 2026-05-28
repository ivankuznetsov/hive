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

  def test_try_append_returns_enoent_sentinel_when_write_hits_enoent
    # If the brainstorm file vanishes between lock acquisition and the
    # atomic write (Errno::ENOENT), try_append must return the
    # `:enoent` sentinel (terminal — caller short-circuits the retry
    # loop) rather than `[nil, nil]` (which the retry loop would
    # interpret as transient lock contention and poll for the full
    # 5s deadline, ending up with the misleading "Try again - another
    # run holds the lock" reply). F2 from PR #239 ce-code-review.
    with_brainstorm(sample) do |path|
      folder = File.dirname(path)
      original = Hive::Markers.method(:write_atomic)
      Hive::Markers.define_singleton_method(:write_atomic) { |*, **| raise Errno::ENOENT }
      begin
        result = Hive::Bot::BrainstormAnswerWriter.send(:try_append, folder, path, 1, "First answer.")
      ensure
        Hive::Markers.define_singleton_method(:write_atomic, original)
      end

      assert_equal [ :enoent, nil ], result,
                   "ENOENT must surface as :enoent sentinel (not transient nil) so append! " \
                   "maps it to :question_not_found instead of polling for lock contention"
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

  # Regression for the cross-round answer leak surfaced during
  # ce-code-review on PR #239 by the adversarial reviewer. Before the
  # Q-context-aware refactor of find_empty_answer_slot, the strict
  # number-scan ignored round boundaries: a Round-1 `### A1.` left
  # empty (e.g. because the agent emitted Round 2 prematurely) would
  # be selected for a Round-2 Q1 answer write, misattributing the
  # operator's reply.
  #
  # Construct a deliberately inconsistent state where R1 Q1 is
  # unanswered AND R2 Q1 has been emitted with its own empty A. The
  # parser's next_unanswered selects R1 Q1 (document order), the
  # writer must locate R1's A1 (not R2's) and write there. If a
  # future refactor reintroduces a non-Q-context-aware scan, the
  # operator's R1 answer would land in R2's A1 slot.
  def test_cross_round_q_with_same_number_writes_to_the_unanswered_one_in_document_order
    content = <<~MARKDOWN
      ## Round 1

      ### Q1. First round Q1?
      ### A1.

      ## Round 2

      ### Q1. Second round Q1?
      ### A1.

      <!-- WAITING -->
    MARKDOWN

    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "FOR_ROUND_ONE"
      )

      assert_equal :written, result
      after = File.read(path)
      # The answer must land in Round 1's slot, not Round 2's.
      r1_block, r2_block = after.split("## Round 2", 2)
      assert_includes r1_block, "FOR_ROUND_ONE",
                      "operator's answer must write to Round 1's A1 (the unanswered Q in document order)"
      refute_includes r2_block.to_s, "FOR_ROUND_ONE",
                      "operator's answer must NOT bleed into Round 2's A1 slot"

      # Round-trip via parser: Round-1 Q1 is now answered; Round-2 Q1
      # remains unanswered.
      parsed = Hive::Bot::BrainstormParser.parse(path)
      r1_q1 = parsed.find { |q| q.round == 1 && q.n == 1 }
      r2_q1 = parsed.find { |q| q.round == 2 && q.n == 1 }
      assert_equal "FOR_ROUND_ONE", r1_q1.answer
      assert_nil r2_q1.answer, "Round-2 Q1 must remain unanswered until the operator answers it"
    end
  end

  # Second-pass on the same fixture: after R1 Q1 is filled, the
  # operator answers R2 Q1. The Q-context-aware scanner must now
  # locate R2's A1 (R1's is already filled) and write there.
  def test_second_answer_after_cross_round_correctly_lands_in_round_two
    content = <<~MARKDOWN
      ## Round 1

      ### Q1. First round Q1?
      ### A1.
      done

      ## Round 2

      ### Q1. Second round Q1?
      ### A1.

      <!-- WAITING -->
    MARKDOWN

    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "FOR_ROUND_TWO"
      )

      assert_equal :written, result
      after = File.read(path)
      _r1, r2 = after.split("## Round 2", 2)
      assert_includes r2, "FOR_ROUND_TWO",
                      "with R1 filled, the writer must scan to R2's empty A1 slot"
    end
  end

  # Boundary coverage: by-position scan must STOP at a `## Round N`
  # header before any A-line, because the operator's answer belongs
  # to the prior round. F6 from PR #239 ce-code-review.
  def test_round_boundary_stops_scan_before_finding_a_slot
    content = <<~MARKDOWN
      ## Round 1

      ### Q1. First?
      ## Round 2
      ### A1.
    MARKDOWN

    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "x"
      )

      assert_equal :answer_slot_missing, result,
                   "## Round boundary between Q and A must yield answer_slot_missing"
    end
  end

  # Boundary coverage: a MARKER line (`<!-- WAITING -->`, `<!-- COMPLETE -->`)
  # between Q and any A-line must also stop the scan. F6 from PR #239.
  def test_marker_boundary_stops_scan_before_finding_a_slot
    content = "## Round 1\n\n### Q1. First?\n<!-- WAITING -->\n"

    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "x"
      )

      assert_equal :answer_slot_missing, result,
                   "<!-- WAITING --> marker between Q and A must yield answer_slot_missing"
    end
  end

  # Defensive: if parsed says Q{n} is unanswered but the raw lines no
  # longer contain that Q (e.g. brainstorm.md was rewritten between
  # `parse_text` and `lines = content.lines` — impossible under the
  # same `with_task_lock`, but the code guards it anyway), the
  # writer must return nil → caller surfaces :answer_slot_missing
  # rather than misattributing to a different line. Exercises the
  # defensive return at the end of target_question_line_index.
  def test_target_question_line_index_returns_nil_when_parsed_diverges_from_lines
    fake_parsed = [
      Hive::Bot::BrainstormParser::Question.new(round: 1, n: 1, text: "synthetic", answer: nil)
    ]
    # Lines contain NO `### Q1.` header at all — simulates a parse-vs-lines
    # divergence that would otherwise let the writer misattribute.
    lines = ["## Round 1\n", "\n", "(no Q1 line on disk)\n"]

    result = Hive::Bot::BrainstormAnswerWriter.send(:target_question_line_index, lines, fake_parsed, 1)
    assert_nil result,
               "defensive nil must fire when parsed and raw lines disagree about Q{n}"
  end

  # F2 from PR #239 ce-code-review: Errno::ENOENT in try_append used
  # to return [nil, nil], which append!'s retry loop treated as lock
  # contention. The bot then sent "Try again - another run holds the
  # lock" for a missing file, a misleading diagnosis. The :enoent
  # sentinel + :question_not_found mapping is now the correct path.
  def test_missing_brainstorm_file_returns_question_not_found_not_lock_busy
    Dir.mktmpdir("hive-enoent-test") do |dir|
      missing_path = File.join(dir, "brainstorm.md")
      # Task folder exists but brainstorm.md does not.
      refute File.exist?(missing_path)

      start = Time.now
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: missing_path,
        question_n: 1,
        answer_text: "anything"
      )
      elapsed = Time.now - start

      assert_equal :question_not_found, result,
                   "missing brainstorm.md must surface as :question_not_found, not :lock_busy"
      # Must NOT have spent the full 5-second retry deadline on a
      # deterministic failure.
      assert_operator elapsed, :<, 1.0,
                      "ENOENT path must short-circuit the retry loop (elapsed: #{elapsed}s)"
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
