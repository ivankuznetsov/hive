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
    # U6 characterization: coding keeps its bespoke stage labels while
    # generic/non-coding stage dirs fall through to the titleized fallback.
    expected = {
      "1-inbox" => "Inbox",
      "2-brainstorm" => "Brainstorm",
      "3-plan" => "Plan",
      "4-execute" => "Execute",
      "5-open-pr" => "Open PR",
      "6-review" => "Review",
      "7-artifacts" => "Artifacts",
      "8-finalize" => "Finalize",
      "9-done" => "Done"
    }

    expected.each do |stage_dir, label|
      assert_equal label, Hive::Bot::TitleFormatter.stage_label(stage_dir)
    end
  end

  def test_stage_label_falls_back_and_logs_unknown_stage_once
    logger = StubLogger.new
    Hive::Bot::TitleFormatter.reset_unknown_stage_log_cache!

    assert_equal "Gather", Hive::Bot::TitleFormatter.stage_label("2-gather", logger: logger)
    assert_equal "Deep Dive", Hive::Bot::TitleFormatter.stage_label("3-deep-dive", logger: logger)
    assert_equal "Gather", Hive::Bot::TitleFormatter.stage_label("2-gather", logger: logger)

    assert_equal [
      [ :unknown_stage_label, { stage: "2-gather" } ],
      [ :unknown_stage_label, { stage: "3-deep-dive" } ]
    ], logger.events
  end

  def test_reset_unknown_stage_log_cache_re_arms_logging
    logger = StubLogger.new
    Hive::Bot::TitleFormatter.reset_unknown_stage_log_cache!
    Hive::Bot::TitleFormatter.stage_label("88-mystery", logger: logger)
    Hive::Bot::TitleFormatter.stage_label("88-mystery", logger: logger)
    assert_equal 1, logger.events.size, "second call must be deduped by the cache"

    Hive::Bot::TitleFormatter.reset_unknown_stage_log_cache!
    Hive::Bot::TitleFormatter.stage_label("88-mystery", logger: logger)
    assert_equal 2, logger.events.size,
                 "after reset, the same unknown stage_dir must log again so SIGHUP / reload surfaces it"
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
