require "test_helper"
require "hive/brainstorm_suggestions/envelope"
require "hive/brainstorm_parser"
require "hive/bot/brainstorm_answer_writer"
require "hive/tui/brainstorm_answers"

class HiveBrainstormSuggestionsEnvelopeTest < Minitest::Test
  BINDING = "b" * 64

  def test_rendered_envelope_is_advisory_to_shared_parser
    envelope = Hive::BrainstormSuggestions::Envelope.render(
      binding: BINDING, text: "Use the repository adapter."
    )
    source = "## Round 1\n### Q1. Which adapter?\n### A1.\n#{envelope}<!-- WAITING -->\n"

    question = Hive::BrainstormParser.parse_text(source).first

    assert_nil question.answer
    assert_equal false, question.answered?
    assert_equal "Use the repository adapter.",
                 Hive::BrainstormSuggestions::Envelope.regions(source).first.text
  end

  def test_stripping_delimiters_adopts_only_the_body
    envelope = Hive::BrainstormSuggestions::Envelope.render(binding: BINDING, text: "Adopt me")
    adopted = envelope.lines.reject do |line|
      line.match?(Hive::BrainstormSuggestions::Envelope::DELIMITER_RE)
    end.join

    assert_equal "Adopt me\n", adopted
    source = "## Round 1\n### Q1. Choose?\n### A1.\n#{adopted}"
    assert_equal "Adopt me", Hive::BrainstormParser.parse_text(source).first.answer
  end

  def test_malformed_nested_and_unclosed_regions_are_inert_until_the_next_slot
    source = <<~MARKDOWN
      ## Round 1
      ### Q1. First?
      ### A1.
      <!-- hive-suggestion:v1 binding=#{BINDING} -->
      unsafe candidate
      <!-- hive-suggestion:v1 binding=#{"c" * 64} -->
      nested candidate
      ### Q2. Second?
      ### A2.
      operator answer
    MARKDOWN

    stripped = Hive::BrainstormSuggestions::Envelope.strip(source)
    parsed = Hive::BrainstormParser.parse_text(source)

    assert_equal true, stripped.corrupt?
    refute_includes stripped.text, "unsafe candidate"
    refute_includes stripped.text, "nested candidate"
    assert_nil parsed.first.answer
    assert_equal "operator answer", parsed.last.answer
  end

  def test_reserved_breakout_marker_cannot_make_candidate_actionable
    source = <<~MARKDOWN
      ## Round 1
      ### Q1. First?
      ### A1.
      <!-- hive-suggestion:v1 binding=#{BINDING} -->
      candidate
      <!-- /hive-suggestion:v1 -- extra -->
      <!-- WAITING -->
    MARKDOWN

    assert_nil Hive::BrainstormParser.parse_text(source).first.answer
    assert Hive::BrainstormSuggestions::Envelope.strip(source).corrupt?
  end

  def test_tui_completeness_and_writer_treat_envelope_as_an_empty_slot
    Dir.mktmpdir do |root|
      path = File.join(root, "brainstorm.md")
      envelope = Hive::BrainstormSuggestions::Envelope.render(binding: BINDING, text: "Advisory only")
      File.write(path, "## Round 1\n### Q1. Choose?\n### A1.\n#{envelope}<!-- WAITING -->\n")

      assert_equal false, Hive::Tui::BrainstormAnswers.complete?(path)
      result = Hive::Lock.with_task_lock(root, op: "test") do
        Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
          brainstorm_path: path, ordinal: 1, answer_text: "Operator choice"
        )
      end

      assert_equal :written, result
      assert_equal "Operator choice", Hive::BrainstormParser.parse(path).first.answer
      refute_includes File.read(path), "hive-suggestion:v1"
    end
  end
end
