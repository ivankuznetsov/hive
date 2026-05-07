require "test_helper"
require "hive/tui/brainstorm_answers"

# Unit-tests the brainstorm-completeness predicate directly against a
# real file on disk (no editor takeover, no BubbleModel scaffold). The
# integration is tested separately in bubble_model_test.rb.
class HiveTuiBrainstormAnswersTest < Minitest::Test
  include HiveTestHelper

  def write_md(dir, body)
    path = File.join(dir, "brainstorm.md")
    File.write(path, body)
    path
  end

  # ---- Happy path ----

  def test_complete_round_with_all_answers_filled
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        # Brainstorm

        ## Round 2
        ### Q1. Scope?
        ### A1.
        Build the smallest useful slice.
        ### Q2. Cadence?
        ### A2. Daily cron.
      MD

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_complete_when_answer_text_is_inline_after_heading
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Cadence?
        ### A1. Daily cron.
      MD

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  # ---- Empty / missing structure ----

  def test_no_round_heading_returns_false
    with_tmp_dir do |dir|
      path = write_md(dir, "# Brainstorm\n\nNothing structured yet.\n")

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_empty_file_returns_false
    with_tmp_dir do |dir|
      path = write_md(dir, "")

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_crlf_line_endings_parse_correctly
    # A brainstorm.md round-tripped through a Windows editor (or
    # touched over an SMB mount) ends up with CRLF line endings.
    # `File.readlines(chomp: true)` strips `\n` but leaves a trailing
    # `\r`; the parser must still recognize the structure.
    with_tmp_dir do |dir|
      path = File.join(dir, "brainstorm.md")
      File.binwrite(path, "## Round 1\r\n### Q1. Scope?\r\n### A1. Done.\r\n")

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_round_with_no_questions_or_answers_returns_false
    with_tmp_dir do |dir|
      path = write_md(dir, "## Round 1\n\nempty round\n")

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_orphan_question_without_matching_answer_returns_false
    # Pins (questions.keys - answers.keys).empty? guard.
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
        ### Q2. Cadence?
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_orphan_answer_without_matching_question_returns_false
    # Pins symmetric-difference check.
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### A1. orphan answer
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_partial_answer_with_empty_body_returns_false
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1.
        Answered.
        ### Q2. Cadence?
        ### A2.
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  # ---- HTML comments (`<!-- WAITING -->` etc.) ----

  def test_waiting_marker_only_answer_body_returns_false
    # Even though the agent emits `<!-- WAITING -->` as the round
    # marker, an answer body whose only content is that comment is
    # NOT a real answer. strip_comments_and_whitespace must blank it.
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1.
        <!-- WAITING -->
        ### Q2. Cadence?
        ### A2.
        <!-- WAITING -->
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_inline_html_comment_does_not_truncate_answer_body
    # Older parser stopped at `^\s*<!--` lines; that meant a real
    # answer ending after an inline comment registered as empty.
    # New parser strips comments and keeps following content.
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1.
        <!-- thinking out loud -->
        Actually: ship Tuesday.
      MD

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_trailing_waiting_marker_does_not_block_complete_round
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
        <!-- WAITING -->
      MD

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  # ---- Round selection ----

  def test_picks_round_with_highest_n_not_last_by_position
    # Stale duplicate `## Round 1` pasted below a complete `## Round 2`
    # used to dictate auto-continue under the old positional rule.
    # New parser picks max-N regardless of file position.
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.

        ## Round 2
        ### Q1. Cadence?
        ### A2. Daily.

        ## Round 1
        ### Q1. Stale paste.
      MD

      # Round 2 is malformed (Q1 with no A1 in that round → orphan
      # question check fires), so the result is false. The point is
      # that auto-continue does NOT key off the trailing Round 1.
      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_round_2_complete_with_round_1_partial_above_returns_true
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1.
        ### Q2. Cadence?
        ### A2.

        ## Round 2
        ### Q1. New direction?
        ### A1. Yes.
      MD

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_round_1_complete_followed_by_partial_round_2_returns_false
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.

        ## Round 2
        ### Q1. New direction?
        ### A1.
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  # ---- Duplicate headings within a round ----

  def test_duplicate_question_number_in_same_round_returns_false
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Done.
        ### Q1. (typo, same number)
        ### A1. Other.
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_duplicate_answer_number_in_same_round_returns_false
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. First.
        ### A1. Second.
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  # ---- Markdown shape (fenced/indented) ----

  def test_round_inside_fenced_code_block_does_not_dictate_completeness
    # Real Round 1 has Q1 with an empty A1. Without code-fence
    # awareness the older parser picked the in-fence `## Round 99`
    # as the latest round and auto-dispatched against the fence's
    # Q1/A1 pair, even though the actual answer was blank.
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1.

        ```
        ## Round 99
        ### Q1. Sample
        ### A1. answer.
        ```
      MD

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_qa_inside_fenced_code_block_is_not_counted
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Real answer.

        Example I considered:

        ```
        ### Q2. Sample question?
        ### A2. Sample answer.
        ```
      MD

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_tilde_fenced_block_also_excluded
    with_tmp_dir do |dir|
      path = write_md(dir, <<~MD)
        ## Round 1
        ### Q1. Scope?
        ### A1. Real.

        ~~~
        ## Round 99
        ### Q1. Inside tilde fence.
        ### A1. Should be ignored.
        ~~~
      MD

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_indented_4_spaces_round_is_not_a_heading
    # CommonMark: 4+ spaces of leading indent → indented code block,
    # not an ATX heading. Older parser used /^\s*##/ which let a
    # 4-space-indented `## Round` win.
    with_tmp_dir do |dir|
      path = write_md(dir, "    ## Round 99\n    ### Q1. Sample\n    ### A1. yes\n")

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  def test_3_space_indented_heading_is_still_valid
    with_tmp_dir do |dir|
      path = write_md(dir, "   ## Round 1\n### Q1. Scope?\n### A1. Done.\n")

      assert_equal true, Hive::Tui::BrainstormAnswers.complete?(path)
    end
  end

  # ---- I/O failure paths ----

  def test_missing_file_returns_false_without_raising
    assert_equal false, Hive::Tui::BrainstormAnswers.complete?("/nonexistent/brainstorm.md")
  end

  def test_directory_path_returns_false_without_raising
    with_tmp_dir do |dir|
      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(dir)
    end
  end

  def test_invalid_utf8_content_returns_false_without_raising
    with_tmp_dir do |dir|
      path = File.join(dir, "brainstorm.md")
      File.binwrite(path, "## Round 1\n### Q1. ?\n### A1. \xff\xfe broken.\n")
      result = Hive::Tui::BrainstormAnswers.complete?(path)
      # Either rescues the encoding error and returns false, or — if
      # the platform's locale tolerates the bytes — successfully parses.
      # Both are acceptable; the contract is "do not raise".
      assert_includes [ true, false ], result
    end
  end
end
