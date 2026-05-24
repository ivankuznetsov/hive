require "eval/eval_helper"
require "json"
require "open3"

class HiveEvalReporterTest < Minitest::Test
  def test_cli_writes_report_for_passing_scenario
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "s1.json")

      _out, err, status = Open3.capture3(
        { "HIVE_EVAL_NO_JUDGE" => "1" },
        "bin/hive-eval", "--scenario", "s1_status", "--no-judge", "--report", report
      )

      assert status.success?, err
      doc = JSON.parse(File.read(report))
      assert_equal "hive-eval-report", doc.fetch("schema")
      assert_equal 2, doc.fetch("scenarios").length
      assert doc.fetch("scenarios").all? { |entry| entry.fetch("status") == "pass" }
    end
  end

  def test_cli_reports_failing_scenario_and_exits_nonzero
    Dir.mktmpdir("hive-eval-report") do |dir|
      report = File.join(dir, "s3.json")

      _out, _err, status = Open3.capture3(
        "bin/hive-eval", "--scenario", "s3_noise", "--no-judge", "--report", report
      )

      refute status.success?, "scenario 3 is expected to fail against the current bot"
      doc = JSON.parse(File.read(report))
      entry = doc.fetch("scenarios").fetch(0)
      assert_equal "fail", entry.fetch("status")
      assert_match(/proactive messages violated allow-list/, entry.fetch("failures").join("\n"))
      assert entry.fetch("captured_messages").any? { |message| message.fetch("reason") == "task_finished" }
    end
  end
end
