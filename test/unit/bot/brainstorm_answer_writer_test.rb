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
      File.write(
        File.join(folder, "meta.yml"),
        { "id" => 42, "slug" => "slug-260514-abcd" }.to_yaml
      )
      database = prepare_runtime_project(
        state_home: dir, name: "brainstorm", path: dir,
        state_root_path: File.join(dir, ".hive-state")
      )
      timestamp = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      project_id = database.read { |db| db[:projects].where(name: "brainstorm").get(:project_id) }
      database.transaction do |db|
        db[:task_subjects].insert(
          task_id: "42", project_id: project_id, workflow_id: "coding",
          task_slug: "slug-260514-abcd", observed_path: folder,
          source_fingerprint: "brainstorm-source", generation: 0,
          created_at: timestamp, last_observed_at: timestamp
        )
      end
      prior_repository = Hive::Lock.task_lease_repository
      Hive::Lock.task_lease_repository = Hive::RuntimeControlPlane::TaskLeaseRepository.new(
        database: database,
        process_start_time: Hive::Lock.method(:process_start_time),
        process_alive: Hive::Lock.method(:process_identity_alive?)
      )
      path = File.join(folder, "brainstorm.md")
      File.write(path, content)
      yield(path)
    ensure
      Hive::Lock.task_lease_repository = prior_repository if defined?(prior_repository)
      database&.disconnect
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
      assert_equal "## Round 1\n\n### Q1. First?\n\n" \
                   "#{Hive::BrainstormParser.encoded_answer_header(1)}\nOne\n",
                   File.read(path)
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

  # #269: Q1 present with NO `### A` line at all — the writer now CREATES
  # the slot at the end of the Q-block and writes the answer, instead of
  # dead-ending with :answer_slot_missing (which, with the daemon's
  # answers-pending gate, held the task indefinitely).
  def test_q_present_no_a_line_creates_slot_and_writes
    with_brainstorm("## Round 1\n\n### Q1. First?\n") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "One"
      )

      assert_equal :written, result
      assert_includes File.read(path), "### A1."
      parsed = Hive::Bot::BrainstormParser.parse(path)
      assert_equal "One", parsed[0].answer, "the created slot must round-trip as Q1's answer"
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
      assert_includes after,
                      "### Q1. Identify OpenClawd.\n#{Hive::BrainstormParser.encoded_answer_header(2)}\nOpenClawd.ai\n",
                      "answer must be written into the mis-numbered A-slot that " \
                      "follows Q1 (the by-position fallback)"
      # Round-trip verify: the parser must read back the answer as Q1's.
      parsed = Hive::Bot::BrainstormParser.parse(path)
      assert_equal "OpenClawd.ai", parsed[0].answer,
                   "parser must accept the mis-numbered A2 under Q1 as Q1's answer"
    end
  end

  # #269: when the next block (Q/Round/marker) comes before any A-line,
  # the writer creates Q1's slot WITHIN Q1's block — i.e. before the next
  # Q's header — so the answer never leaks into a later question.
  def test_creates_slot_within_block_when_next_q_comes_first
    with_brainstorm("## Round 1\n\n### Q1. First?\n### Q2. Second?\n### A2.\n") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "One"
      )

      assert_equal :written, result
      after = File.read(path)
      assert_includes after,
                      "### Q1. First?\n#{Hive::BrainstormParser.encoded_answer_header(1)}\nOne\n### Q2. Second?",
                      "the created A1 slot must sit between Q1 and Q2"
      parsed = Hive::Bot::BrainstormParser.parse(path)
      assert_equal "One", parsed[0].answer
      assert_nil parsed[1].answer, "Q2 must remain unanswered"
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
      assert_includes File.read(path),
                      "#{Hive::BrainstormParser.encoded_answer_header(2)}\nFilled\n"
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

  def test_write_at_ordinal_under_existing_lock_targets_later_same_number
    content = <<~MARKDOWN
      ## Round 1
      ### Q1. Earlier?
      ### A1.
      ## Round 2
      ### Q1. Later?
      ### A1.
      <!-- WAITING -->
    MARKDOWN

    with_brainstorm(content) do |path|
      result = Hive::Lock.with_task_lock(File.dirname(path), op: "test") do
        Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
          brainstorm_path: path, ordinal: 2, answer_text: "later only"
        )
      end

      assert_equal :written, result
      parsed = Hive::BrainstormParser.parse(path)
      assert_nil parsed.fetch(0).answer
      assert_equal "later only", parsed.fetch(1).answer
    end
  end

  def test_exact_writer_rejects_invalid_ordinals_and_missing_raw_question_positions
    with_brainstorm(sample) do |path|
      assert_equal :question_not_found,
                   Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
                     brainstorm_path: path, ordinal: Object.new, answer_text: "never written"
                   )
    end

    lines = [ "## Round 1\n", "### Q1. Only question?\n" ]
    assert_nil Hive::Bot::BrainstormAnswerWriter.send(
      :question_line_index_for_ordinal, lines, 2
    )
  end

  # Boundary coverage (#269): the slot-creation scan must STOP at a
  # `## Round N` header before any A-line — the created A1 slot belongs to
  # Round 1's Q1, so it is inserted BEFORE the Round 2 boundary, never
  # routed into Round 2's stray `### A1.`. F6 from PR #239 ce-code-review.
  def test_round_boundary_keeps_created_slot_in_prior_round
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

      assert_equal :written, result
      assert_includes File.read(path),
                      "### Q1. First?\n#{Hive::BrainstormParser.encoded_answer_header(1)}\nx\n## Round 2",
                      "the created A1 slot must sit before the Round 2 boundary"
    end
  end

  # Boundary coverage (#269): a MARKER line (`<!-- WAITING -->`) also stops
  # the scan, so the created slot is inserted before the marker. F6 / #239.
  def test_marker_boundary_keeps_created_slot_before_marker
    content = "## Round 1\n\n### Q1. First?\n<!-- WAITING -->\n"

    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "x"
      )

      assert_equal :written, result
      assert_includes File.read(path),
                      "### Q1. First?\n#{Hive::BrainstormParser.encoded_answer_header(1)}\nx\n<!-- WAITING -->",
                      "the created A1 slot must sit before the WAITING marker"
    end
  end

  # #269: creating a slot for a Round-2 question (Round 1 fully answered)
  # must place the new A inside Round 2's block, not Round 1's.
  def test_creates_slot_for_later_round_question
    content = "## Round 1\n### Q1. A?\n### A1.\nyes\n## Round 2\n### Q1. B?\n<!-- WAITING -->\n"
    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path, question_n: 1, answer_text: "no"
      )

      assert_equal :written, result
      parsed = Hive::Bot::BrainstormParser.parse(path)
      r1 = parsed.find { |q| q.round == 1 && q.n == 1 }
      r2 = parsed.find { |q| q.round == 2 && q.n == 1 }
      assert_equal "yes", r1.answer, "Round 1 answer untouched"
      assert_equal "no", r2.answer, "the created slot belongs to Round 2's Q1"
    end
  end

  # #269: creating a slot when the question is the final line with NO
  # trailing newline — the writer must newline-terminate it first so the
  # new `### A` header isn't glued onto the question text.
  def test_creates_slot_when_question_has_no_trailing_newline
    with_brainstorm("## Round 1\n\n### Q1. First?") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path, question_n: 1, answer_text: "One"
      )

      assert_equal :written, result
      assert_includes File.read(path),
                      "### Q1. First?\n#{Hive::BrainstormParser.encoded_answer_header(1)}\nOne\n",
                      "the question line must be newline-terminated before the created A header"
      assert_equal "One", Hive::Bot::BrainstormParser.parse(path)[0].answer
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
    lines = [ "## Round 1\n", "\n", "(no Q1 line on disk)\n" ]

    result = Hive::Bot::BrainstormAnswerWriter.send(:target_question_line_index, lines, fake_parsed, 1)
    assert_nil result,
               "defensive nil must fire when parsed and raw lines disagree about Q{n}"
  end

  # F2 from PR #239 ce-code-review: when try_append returns :enoent
  # (because brainstorm.md vanished mid-write), append!'s retry loop
  # must short-circuit and map the sentinel to :question_not_found
  # with a logged :answer_lock_contention event describing the
  # cause. Exercises lines 73-78 of brainstorm_answer_writer.rb —
  # the elsif result == :enoent branch.
  def test_append_maps_enoent_sentinel_to_question_not_found_with_logged_cause
    with_brainstorm(sample) do |path|
      # Force Hive::Markers.write_atomic to raise ENOENT so try_append
      # returns the :enoent sentinel.
      original = Hive::Markers.method(:write_atomic)
      Hive::Markers.define_singleton_method(:write_atomic) { |*, **| raise Errno::ENOENT }

      logger = StubLogger.new
      begin
        result = Hive::Bot::BrainstormAnswerWriter.append!(
          brainstorm_path: path,
          question_n: 1,
          answer_text: "x",
          logger: logger
        )
      ensure
        Hive::Markers.define_singleton_method(:write_atomic, original)
      end

      assert_equal :question_not_found, result,
                   ":enoent must map to :question_not_found, not :lock_busy"
      lock_event = logger.events.find { |(name, _)| name == :answer_lock_contention }
      refute_nil lock_event, "the missing-file path must log answer_lock_contention with the cause"
      holder = lock_event[1][:holder]
      assert_equal({ reason: "brainstorm.md missing" }, holder,
                   "the holder field must name the cause so operators can grep bot.log")
    end
  end

  # File simply doesn't exist at all (vs. exists-but-deleted-mid-write).
  # try_append reads "" via File.exist?-then-File.read guard; parse
  # returns []; the writer reports :question_not_found directly.
  # Distinct from the :enoent sentinel path tested above.
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

      # The core first-write-wins invariant: exactly one of the 8
      # concurrent writers actually wrote, and the saved answer is
      # one of theirs.
      assert_equal 1, outcomes.count(:written),
                   "exactly one concurrent writer should win, got #{outcomes.tally}"

      # The other 7 writers must lose, but the specific loss shape
      # depends on timing under heavy contention:
      #   - :already_answered — the winner finished first; the loser
      #     saw the answer present.
      #   - :lock_busy — the loser couldn't acquire within the 5s
      #     retry deadline (Hive::Lock has no fairness guarantee).
      #   - :question_not_found / :answer_slot_missing — TOCTOU race
      #     in `File.exist? ? File.read : ""` when the winner's
      #     atomic rename briefly desyncs the directory entry; the
      #     loser reads "" and parses zero questions. Rare but not
      #     impossible on heavily-loaded CI.
      # All of these preserve first-write-wins (no double-write); the
      # test's job here is to assert that invariant, not to pin the
      # specific timing-derived loss shape.
      non_winners = outcomes.count { |o| o != :written }
      assert_equal 7, non_winners,
                   "the other 7 writers must NOT have written (got #{outcomes.tally})"

      saved = Hive::Bot::BrainstormParser.parse(path).first.answer
      assert_match(/Answer from thread/, saved)
    end
  end

  def test_structural_answer_lines_are_reversibly_neutralized
    answer = <<~TEXT.rstrip
      ### Q99. Not a slot
      ### A99.
      ## Round 99
      <!-- COMPLETE -->
      Inline <!-- ERROR reason=spoofed --> marker
      \\### Q7. Preserve slash
      \\&lt;!-- COMPLETE --> preserve entity
    TEXT
    with_brainstorm(sample) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path, question_n: 1, answer_text: answer
      )

      assert_equal :written, result
      assert_equal 2, Hive::BrainstormParser.parse(path).length
      assert_equal answer, Hive::BrainstormParser.parse(path).first.answer
      assert_equal :waiting, Hive::Markers.current(path).name
      raw = File.read(path)
      assert_includes raw, Hive::BrainstormParser::ANSWER_ESCAPE_PREFIX
      refute_includes raw, "\n### Q99. Not a slot\n"
      refute_includes raw, "\n<!-- COMPLETE -->\n"
    end
  end

  def test_exact_writer_maps_ordinals_in_lone_cr_files
    content = "## Round 1\r### Q1. First?\r### A1.\r### Q2. Second?\r### A2.\r<!-- WAITING -->\r"
    with_brainstorm(content) do |path|
      result = Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
        brainstorm_path: path, ordinal: 2, answer_text: "second answer"
      )

      assert_equal :written, result
      assert_equal [ nil, "second answer" ], Hive::BrainstormParser.parse(path).map(&:answer)
    end
  end

  def test_marker_answer_without_a_real_stage_marker_does_not_forge_one
    with_brainstorm("## Round 1\n### Q1. Marker?\n### A1.\n") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path, question_n: 1, answer_text: "<!-- COMPLETE -->"
      )

      assert_equal :written, result
      assert_equal "<!-- COMPLETE -->", Hive::BrainstormParser.parse(path).first.answer
      assert_equal :none, Hive::Markers.current(path).name
    end
  end

  def test_exact_writer_scrubs_invalid_utf8_before_parsing
    with_brainstorm(sample) do |path|
      bytes = File.binread(path).sub("First question?", "First \xFF question?".b)
      File.binwrite(path, bytes)

      result = Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
        brainstorm_path: path, ordinal: 1, answer_text: "still writable"
      )

      assert_equal :written, result
      assert_equal "still writable", Hive::BrainstormParser.parse(path).first.answer
    end
  end

  def test_answer_and_marker_writers_share_the_marker_sidecar_lock
    10.times do
      with_brainstorm(sample) do |path|
        answer_thread = Thread.new do
          Hive::Bot::BrainstormAnswerWriter.append!(
            brainstorm_path: path, question_n: 1, answer_text: "kept answer"
          )
        end
        marker_thread = Thread.new { Hive::Markers.set(path, :error, reason: "test") }

        assert_equal :written, answer_thread.value
        marker_thread.value
        assert_equal "kept answer", Hive::BrainstormParser.parse(path).first.answer
        assert_equal :error, Hive::Markers.current(path).name
      end
    end
  end

  def test_exact_writer_does_not_mask_unexpected_type_errors
    with_brainstorm(sample) do |path|
      replacement = ->(*_args) { raise TypeError, "unexpected writer failure" }
      with_replaced_singleton_method(Hive::Markers, :write_atomic, replacement) do
        error = assert_raises(TypeError) do
          Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
            brainstorm_path: path, ordinal: 1, answer_text: "answer"
          )
        end
        assert_match(/unexpected writer failure/, error.message)
      end
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
      held_holder = Hive::Lock.acquire_task_lock(
        task_folder, op: "approve", slug: "slug-260514-abcd", host: "test-host"
      )

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
      Hive::Lock.release_task_lock(task_folder, lock_id: held_holder["lock_id"]) if held_holder
    end
  end

  def test_holder_propagates_when_deadline_expires_before_the_first_retry
    # Timing-free companion to the test above. That one leans on a 0.1s
    # deadline outlasting one try_append, which is not a guarantee on a
    # loaded runner: when try_append itself takes longer than the budget the
    # loop breaks on its first pass. A zero deadline pins that exact pass
    # deterministically, so the holder-capture ordering is covered without a
    # race against the clock.
    with_brainstorm(sample) do |path|
      task_folder = File.dirname(path)
      held_holder = Hive::Lock.acquire_task_lock(
        task_folder, op: "approve", slug: "slug-260514-abcd"
      )

      logger = StubLogger.new
      with_deadline(0) do
        assert_equal :lock_busy, Hive::Bot::BrainstormAnswerWriter.append!(
          brainstorm_path: path,
          question_n: 1,
          answer_text: "Reply blocked by the live lock holder",
          logger: logger
        )
      end

      payload = logger.events.find { |name, _| name == :answer_lock_contention }&.last
      refute_nil payload, "writer must emit :answer_lock_contention when the deadline expires"
      refute_nil payload[:holder],
                 "holder observed on the deadline-crossing pass must still reach the event"
      assert_equal Process.pid, payload[:holder]["pid"]
      assert_equal "approve", payload[:holder]["op"]
    ensure
      Hive::Lock.release_task_lock(task_folder, lock_id: held_holder["lock_id"]) if held_holder
    end
  end

  def with_short_deadline(&block)
    with_deadline(0.1, &block)
  end

  def with_deadline(seconds)
    original = Hive::Bot::BrainstormAnswerWriter::LOCK_RETRY_DEADLINE_SEC
    Hive::Bot::BrainstormAnswerWriter.send(:remove_const, :LOCK_RETRY_DEADLINE_SEC)
    Hive::Bot::BrainstormAnswerWriter.const_set(:LOCK_RETRY_DEADLINE_SEC, seconds)
    yield
  ensure
    Hive::Bot::BrainstormAnswerWriter.send(:remove_const, :LOCK_RETRY_DEADLINE_SEC)
    Hive::Bot::BrainstormAnswerWriter.const_set(:LOCK_RETRY_DEADLINE_SEC, original)
  end
end
