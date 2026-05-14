require "test_helper"
require "hive/bot/brainstorm_answer_writer"
require "hive/bot/brainstorm_parser"

class HiveBotBrainstormRoundTripTest < Minitest::Test
  include HiveTestHelper

  def test_four_question_round_writes_incrementally
    with_tmp_dir do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "slug-260514-abcd")
      FileUtils.mkdir_p(folder)
      path = File.join(folder, "brainstorm.md")
      File.write(path, <<~MARKDOWN)
        ## Round 2

        ### Q1. One?

        ### A1.

        ### Q2. Two?

        ### A2.

        ### Q3. Three?

        ### A3.

        ### Q4. Four?

        ### A4.

        <!-- WAITING -->
      MARKDOWN

      4.times do |idx|
        result = Hive::Bot::BrainstormAnswerWriter.append!(
          brainstorm_path: path,
          question_n: idx + 1,
          answer_text: "Answer #{idx + 1}"
        )
        assert_equal :written, result
        assert_equal "Answer #{idx + 1}", Hive::Bot::BrainstormParser.parse(path)[idx].answer
      end

      assert_nil Hive::Bot::BrainstormParser.next_unanswered_question(
        Hive::Bot::BrainstormParser.parse(path)
      )
    end
  end
end
