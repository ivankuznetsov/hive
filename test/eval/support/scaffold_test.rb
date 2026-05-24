require "eval/eval_helper"

class HiveEvalScaffoldTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_scenario_support_drives_status_query
    given_project(name: "hive")
    row = status_row(slug: "question-a")
    harness.status_watcher.queue(rows: [ row ])

    when_user_sends("/status")

    assert_sent_count 1
    assert_match(/1 active task/, harness.last_sent.text)
    assert_match(/hive\/question-a/, harness.last_sent.text)
  end
end
