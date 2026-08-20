require "test_helper"
require "json"
require "hive/patrol_fix/inbox_report"
require "hive/patrol_fix/fix_report"

class PatrolFixReportsTest < Minitest::Test
  def test_inbox_report_accepts_only_the_closed_semantic_shape
    report = Hive::PatrolFix::InboxReport.parse(JSON.generate(
      "schema" => "hive-patrol-fix-inbox-report", "schema_version" => 1,
      "route" => "fix", "rationale" => "Current code still reproduces the defect.",
      "evidence" => [ "Focused test fails at the cited boundary." ],
      "blocker_owner" => "inbox_gate"
    ))
    assert_equal "fix", report.route

    assert_raises(Hive::PatrolFix::InboxReport::InvalidReport) do
      Hive::PatrolFix::InboxReport.parse(JSON.generate(report.to_h.merge("task" => "replace-me")))
    end
  end

  def test_fix_report_keeps_agent_selected_commands_structured_and_bounded
    report = Hive::PatrolFix::FixReport.parse(JSON.generate(
      "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
      "status" => "fixed", "summary" => "Fixed the root cause and committed it.",
      "validation_commands" => [
        { "identity" => "focused-test", "command" => "bundle exec ruby test/focused_test.rb" }
      ]
    ))

    assert_equal "focused-test", report.validation_commands.first.fetch("identity")
    assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
      Hive::PatrolFix::FixReport.parse(JSON.generate(report.to_h.merge(
        "publication" => { "url" => "https://example.test/pr/1" }
      )))
    end
  end
end
