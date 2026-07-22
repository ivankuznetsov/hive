require "test_helper"
require "json"
require "hive/babysitter/events"
require "hive/babysitter/status_writer"

class BabysitterEventsTest < Minitest::Test
  include HiveTestHelper

  def project_entry(dir)
    { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def test_emit_writes_parseable_json_line
    with_tmp_dir do |dir|
      project = project_entry(dir)
      record = Hive::Babysitter::Events.emit(
        project: project,
        pr: 42,
        action: "list-prs",
        outcome: "gh-error",
        duration_ms: 12
      )

      path = File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")
      parsed = JSON.parse(File.read(path))
      assert_equal record, parsed
      assert_equal "babysitter", parsed.fetch("stage")
      assert_equal 42, parsed.fetch("pr")
    end
  end

  def test_emit_accepts_rebase_action_and_conflict_outcome
    with_tmp_dir do |dir|
      project = project_entry(dir)
      record = Hive::Babysitter::Events.emit(
        project: project,
        pr: 42,
        action: "rebase",
        outcome: "conflict",
        duration_ms: 5
      )
      assert_equal "rebase", record.fetch("action")
      assert_equal "conflict", record.fetch("outcome")
    end
  end

  def test_emit_raises_on_unknown_action_and_outcome
    with_tmp_dir do |dir|
      project = project_entry(dir)
      assert_raises(ArgumentError) do
        Hive::Babysitter::Events.emit(project: project, action: "teleport", outcome: "success")
      end
      assert_raises(ArgumentError) do
        Hive::Babysitter::Events.emit(project: project, action: "rebase", outcome: "exploded")
      end
    end
  end

  def test_status_writer_appends_summary_lines
    with_tmp_dir do |dir|
      project = project_entry(dir)
      2.times do
        Hive::Babysitter::StatusWriter.append(
          project: project,
          pr_count: 3,
          fixed: 1,
          untouched: 1,
          needs_human: 1,
          now: Time.utc(2026, 5, 26, 11, 40)
        )
      end

      body = File.read(File.join(project.fetch("hive_state_path"), "babysitter", "status.md"))
      assert_equal 2, body.scan(/babysitter pass @/).size
      assert_includes body, "3 PRs, 1 fixed, 1 untouched, 1 needs-human"
    end
  end

  def test_status_writer_resolves_relative_state_path_from_project_root
    with_tmp_dir do |dir|
      project = { "name" => "demo", "path" => dir, "hive_state_path" => "state" }

      Hive::Babysitter::StatusWriter.append(
        project: project, pr_count: 1, fixed: 0, untouched: 1, needs_human: 0
      )

      assert File.file?(File.join(dir, "state", "babysitter", "status.md"))
    end
  end
end
