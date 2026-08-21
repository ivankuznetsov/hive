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

  def test_fix_report_rejects_each_untrusted_file_and_document_boundary
    valid = {
      "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
      "status" => "fixed", "summary" => "fixed",
      "validation_commands" => [ { "identity" => "test", "command" => "ruby test.rb" } ]
    }
    invalid = [
      valid.merge("schema" => "other"),
      valid.merge("status" => "unknown"),
      valid.merge("summary" => ""),
      valid.merge("validation_commands" => "bad"),
      valid.merge("validation_commands" => [ { "identity" => "test" } ]),
      valid.merge("validation_commands" => [ { "identity" => "bad\n", "command" => "test" } ])
    ]
    invalid.each do |document|
      assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
        Hive::PatrolFix::FixReport.parse(JSON.generate(document))
      end
    end
    assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
      Hive::PatrolFix::FixReport.parse("{")
    end
    assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
      Hive::PatrolFix::FixReport.parse("\xFF".b)
    end
    assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
      Hive::PatrolFix::FixReport.parse("x" * (Hive::PatrolFix::FixReport::MAX_BYTES + 1))
    end

    Dir.mktmpdir("fix-report") do |dir|
      missing = File.join(dir, "missing.json")
      assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
        Hive::PatrolFix::FixReport.read(missing)
      end
      directory = File.join(dir, "directory")
      FileUtils.mkdir_p(directory)
      assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
        Hive::PatrolFix::FixReport.read(directory)
      end
      oversized = File.join(dir, "oversized.json")
      File.write(oversized, "x" * (Hive::PatrolFix::FixReport::MAX_BYTES + 1))
      assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
        Hive::PatrolFix::FixReport.read(oversized)
      end
    end
  end

  def test_shared_report_reader_rejects_route_and_text_contract_drift
    valid = {
      "schema" => "hive-patrol-fix-inbox-report", "schema_version" => 1,
      "route" => "fix", "rationale" => "because", "evidence" => [ "proof" ],
      "blocker_owner" => "controller"
    }
    invalid = [
      [], valid.merge("schema" => "other"), valid.merge("schema_version" => 2),
      valid.merge("route" => "publish"), valid.merge("rationale" => ""),
      valid.merge("blocker_owner" => "bad\n"), valid.merge("evidence" => []),
      valid.merge("evidence" => [ "bad\n" ])
    ]
    invalid.each do |document|
      assert_raises(Hive::PatrolFix::InboxReport::InvalidReport) do
        Hive::PatrolFix::InboxReport.parse(JSON.generate(document))
      end
    end
    assert_raises(Hive::PatrolFix::InboxReport::InvalidReport) do
      Hive::PatrolFix::InboxReport.parse("{")
    end
    assert_raises(Hive::PatrolFix::InboxReport::InvalidReport) do
      Hive::PatrolFix::ReportReader.normalize_routes!(
        %w[fix fix], Hive::PatrolFix::InboxReport::ROUTES,
        Hive::PatrolFix::InboxReport::InvalidReport
      )
    end
  end

  def test_report_readers_translate_symlink_loop_and_io_failures
    errors = [ Errno::ELOOP.new("loop"), IOError.new("closed") ]
    errors.each do |failure|
      original = File.method(:open)
      File.define_singleton_method(:open, ->(*) { raise failure })
      begin
        assert_raises(Hive::PatrolFix::FixReport::InvalidReport) do
          Hive::PatrolFix::FixReport.read("ignored")
        end
        assert_raises(Hive::PatrolFix::InboxReport::InvalidReport) do
          Hive::PatrolFix::InboxReport.read("ignored")
        end
      ensure
        File.define_singleton_method(:open, original)
      end
    end


    assert_raises(Hive::PatrolFix::InboxReport::InvalidReport) do
      Hive::PatrolFix::InboxReport.read(File.join(Dir.tmpdir, "missing-patrol-fix-report"))
    end
  end
end
