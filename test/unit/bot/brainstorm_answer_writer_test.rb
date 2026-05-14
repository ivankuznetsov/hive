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

  def test_missing_answer_placeholder_returns_question_not_found
    with_brainstorm("## Round 1\n\n### Q1. First?\n") do |path|
      result = Hive::Bot::BrainstormAnswerWriter.append!(
        brainstorm_path: path,
        question_n: 1,
        answer_text: "One"
      )

      assert_equal :question_not_found, result
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
end
