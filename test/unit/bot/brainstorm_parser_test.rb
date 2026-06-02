require "test_helper"
require "hive/bot/brainstorm_parser"

class HiveBotBrainstormParserTest < Minitest::Test
  FIXTURE_DIR = File.expand_path("../../fixtures/brainstorm", __dir__)

  def fixture(name)
    File.join(FIXTURE_DIR, name)
  end

  # The parser now lives at Hive::BrainstormParser (shared with the
  # daemon); Hive::Bot::BrainstormParser is a back-compat alias.
  def test_bot_namespace_is_an_alias_for_the_shared_parser
    assert_same Hive::BrainstormParser, Hive::Bot::BrainstormParser
    assert_same Hive::BrainstormParser::Question, Hive::Bot::BrainstormParser::Question
  end

  # The file is read concurrently (the bot appends answers while the
  # daemon parses to gate auto-resume), so parse must be total: invalid
  # UTF-8 / a torn mid-append read must degrade, not raise.
  def test_parse_tolerates_invalid_utf8_without_raising
    Dir.mktmpdir do |dir|
      path = File.join(dir, "brainstorm.md")
      File.binwrite(path, "## Round 1\n### Q1.\nWhat?\n### A1.\n\xFF\xFE\n")
      # If parse raised on the invalid bytes this would error the test.
      questions = Hive::BrainstormParser.parse(path)
      assert_equal 1, questions.size, "the question is still recoverable past the bad bytes"
    end
  end

  def test_parse_returns_empty_for_missing_file
    assert_empty Hive::BrainstormParser.parse("/no/such/brainstorm.md")
  end

  def test_parses_two_rounds_and_returns_first_unanswered_in_document_order
    questions = Hive::Bot::BrainstormParser.parse(fixture("round1_full_round2_partial.md"))

    assert_equal 5, questions.size
    assert_equal [ 1, 1, 2, 2, 2 ], questions.map(&:round)
    assert_equal "Which project should receive the first test idea?", questions[2].text
    assert_equal "Hive.", questions[2].answer

    next_question = Hive::Bot::BrainstormParser.next_unanswered_question(questions)
    assert_equal 2, next_question.round
    assert_equal 2, next_question.n
    assert_equal "How should long questions be handled?\nInclude the phone-screen constraint.", next_question.text
  end

  def test_complete_file_has_no_next_question
    questions = Hive::Bot::BrainstormParser.parse(fixture("complete.md"))

    assert_equal 2, questions.size
    assert_nil Hive::Bot::BrainstormParser.next_unanswered_question(questions)
  end

  def test_empty_file_returns_empty_list
    questions = Hive::Bot::BrainstormParser.parse(fixture("empty.md"))

    assert_equal [], questions
    assert_nil Hive::Bot::BrainstormParser.next_unanswered_question(questions)
  end

  def test_malformed_file_without_blocks_returns_empty_list
    assert_equal [], Hive::Bot::BrainstormParser.parse(fixture("malformed_no_blocks.md"))
  end

  def test_missing_answer_block_is_unanswered
    text = <<~MARKDOWN
      ## Round 1

      ### Q1. The question exists.
      It has more context.
    MARKDOWN

    questions = Hive::Bot::BrainstormParser.parse_text(text)

    assert_equal 1, questions.size
    assert_equal "The question exists.\nIt has more context.", questions.first.text
    assert_nil questions.first.answer
  end

  def test_crlf_line_endings_are_supported
    text = "## Round 1\r\n\r\n### Q1. First?\r\n\r\n### A1.\r\nAnswered.\r\n"

    questions = Hive::Bot::BrainstormParser.parse_text(text)

    assert_equal 1, questions.size
    assert_equal "First?", questions.first.text
    assert_equal "Answered.", questions.first.answer
  end

  def test_question_text_spans_multiple_lines
    text = <<~MARKDOWN
      ## Round 3

      ### Q7. Explain the tradeoff.
      Include latency.
      Include safety.

      ### A7.
    MARKDOWN

    question = Hive::Bot::BrainstormParser.parse_text(text).first

    assert_equal 3, question.round
    assert_equal 7, question.n
    assert_equal "Explain the tradeoff.\nInclude latency.\nInclude safety.", question.text
    assert_nil question.answer
  end

  def test_marker_after_answer_is_ignored
    questions = Hive::Bot::BrainstormParser.parse(fixture("complete.md"))

    assert_equal "Also yes.", questions.last.answer
  end

  def test_question_heading_text_embedded_inside_answer_line_does_not_split_answer
    text = <<~MARKDOWN
      ## Round 1

      ### Q1. What happened?

      ### A1.
      The phrase ### Q5. was part of the answer, not a heading.
    MARKDOWN

    questions = Hive::Bot::BrainstormParser.parse_text(text)

    assert_equal 1, questions.size
    assert_equal "The phrase ### Q5. was part of the answer, not a heading.", questions.first.answer
  end

  def test_multi_paragraph_answer_with_internal_blank_line_is_preserved
    text = <<~MARKDOWN
      ## Round 1

      ### Q1. Multi para?

      ### A1.

      First paragraph.

      Second paragraph.
    MARKDOWN

    answer = Hive::Bot::BrainstormParser.parse_text(text).first.answer

    assert_equal "First paragraph.\n\nSecond paragraph.", answer
  end

  def test_question_without_round_context_returns_nil_round
    text = <<~MARKDOWN
      ### Q1. Question without preceding round?
      Body.

      ### A1.
    MARKDOWN

    question = Hive::Bot::BrainstormParser.parse_text(text).first

    assert_equal 1, question.n
    assert_nil question.round
  end

  def test_questions_are_sorted_by_round_and_number
    text = <<~MARKDOWN
      ## Round 2

      ### Q3. Third?

      ### A3.

      ### Q2. Second?

      ### A2.
    MARKDOWN

    questions = Hive::Bot::BrainstormParser.parse_text(text)

    assert_equal [ 2, 3 ], questions.map(&:n)
    assert_equal 2, Hive::Bot::BrainstormParser.next_unanswered_question(questions).n
  end

  def test_unanswered_questions_and_question_lookup_helpers
    questions = Hive::Bot::BrainstormParser.parse_text(<<~MARKDOWN)
      ## Round 1

      ### Q1. First?

      ### A1.
      Yes.

      ### Q2. Second?

      ### A2.

      ### Q3. Third?
    MARKDOWN

    unanswered = Hive::Bot::BrainstormParser.unanswered_questions(questions)

    assert_equal [ 2, 3 ], unanswered.map(&:n)
    assert_equal "Second?", Hive::Bot::BrainstormParser.question_for(questions, 2).text
    assert_nil Hive::Bot::BrainstormParser.question_for(questions, 99)
  end

  def test_answered_predicate_reflects_presence_of_answer
    questions = Hive::Bot::BrainstormParser.parse_text(<<~MARKDOWN)
      ## Round 1

      ### Q1. First?

      ### A1.
      Yes.

      ### Q2. Second?

      ### A2.
    MARKDOWN

    assert_predicate questions.first, :answered?
    refute_predicate questions.last, :answered?
  end

  # Regression: observed 2026-05-28 on
  # `explore-the-simplest-way-to-260528-2503` — the brainstorm agent
  # emitted `### A2.` immediately after `### Q1.` for a fresh Round 2.
  # Old parser dropped the mis-numbered A line entirely (strict `current[:n]
  # == match[1].to_i`), then later flagged Q1 as unanswered after the user
  # filled the slot, which had the bot re-asking Q1 in a loop. New parser
  # accepts the first A-section under a Q as that Q's answer slot.
  def test_misnumbered_answer_header_after_question_is_treated_as_answer_slot
    questions = Hive::Bot::BrainstormParser.parse_text(<<~MARKDOWN)
      ## Round 2

      ### Q1. Identify OpenClawd.
      ### A2.
      OpenClawd.ai

      ### Q2. Which install path?
      ### A2.
      claude plugin
    MARKDOWN

    assert_equal 2, questions.size
    assert_equal "OpenClawd.ai", questions[0].answer,
                 "mis-numbered A2 after Q1 must be accepted as Q1's answer"
    assert_equal "claude plugin", questions[1].answer,
                 "the duplicate A2 after Q2 (correctly numbered) must still be accepted"
    assert_predicate questions[0], :answered?
    assert_predicate questions[1], :answered?
  end

  # The lenient rule must NOT swallow an A-section that appears BEFORE
  # any Q on the page — that would corrupt unrelated content.
  def test_answer_before_any_question_is_ignored
    questions = Hive::Bot::BrainstormParser.parse_text(<<~MARKDOWN)
      ## Round 1

      ### A99.
      orphan

      ### Q1. First?
      ### A1.
      real answer
    MARKDOWN

    assert_equal 1, questions.size
    assert_equal "real answer", questions[0].answer
  end

  # When a Q has no A-section at all (parser sees Q followed by another
  # Q or end-of-file), it stays unanswered. The lenient rule fires only
  # when an A line is actually present.
  def test_question_with_no_answer_section_stays_unanswered
    questions = Hive::Bot::BrainstormParser.parse_text(<<~MARKDOWN)
      ## Round 1

      ### Q1. First?

      ### Q2. Second?
      ### A2.
      yes
    MARKDOWN

    assert_equal 2, questions.size
    assert_nil questions[0].answer, "Q1 with no A line must stay unanswered"
    assert_equal "yes", questions[1].answer
  end
end
