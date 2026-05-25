require "test_helper"
require "hive/bot/title_formatter"

class HiveBotTitleFormatterTest < Minitest::Test
  def test_title_from_slug_strips_generated_suffix_and_sentence_cases
    assert_equal "We need to improve this…",
                 Hive::Bot::TitleFormatter.title_from_slug("we-need-to-improve-this-260522-db23")
    assert_equal "This kind of errors are…",
                 Hive::Bot::TitleFormatter.title_from_slug("this-kind-of-errors-are-260523-01fa")
    assert_equal "Task…",
                 Hive::Bot::TitleFormatter.title_from_slug("task-260424-aaaa")
    assert_equal "No suffix here…",
                 Hive::Bot::TitleFormatter.title_from_slug("no-suffix-here")
  end

  def test_title_from_slug_caps_prefix_at_sixty_characters
    title = Hive::Bot::TitleFormatter.title_from_slug("#{"a" * 70}-260101-abcd")

    assert_equal "#{"A" + ("a" * 59)}…", title
  end

  def test_stage_label_uses_known_stage_names
    assert_equal "Review", Hive::Bot::TitleFormatter.stage_label("6-review")
    assert_equal "Open PR", Hive::Bot::TitleFormatter.stage_label("5-open-pr")
  end

  def test_stage_label_falls_back_and_logs_unknown_stage_once
    logger = StubLogger.new

    assert_equal "Future", Hive::Bot::TitleFormatter.stage_label("99-future", logger: logger)
    assert_equal "Future", Hive::Bot::TitleFormatter.stage_label("99-future", logger: logger)

    assert_equal [ [ :unknown_stage_label, { stage: "99-future" } ] ], logger.events
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
end
