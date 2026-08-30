require "test_helper"
require "hive/daily_digest/project_source"

class DailyDigestProjectSourceTest < Minitest::Test
  include HiveTestHelper

  def test_collects_creation_and_material_journal_activity_once
    with_tmp_dir do |project|
      hive_state = File.join(project, ".hive-state")
      task_folder = File.join(hive_state, "stages", "4-execute", "digest-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "task.md"), "# task\n")
      File.write(File.join(task_folder, "meta.yml"), { "id" => 42, "slug" => "digest-task" }.to_yaml)
      Hive::DailyDigest::TaskCreationReceipt.write!(
        task_folder: task_folder,
        project: { "project_id" => "project-1", "name" => "demo" },
        task: { "id" => 42, "slug" => "digest-task" },
        workflow: "coding", stage: "1-inbox",
        created_at: Time.iso8601("2026-08-30T08:00:00Z")
      )
      File.write(
        File.join(task_folder, "task-journal.jsonl"),
        JSON.generate(activity("stage_transition", "event-stage", "transition" => "completed")) + "\n" +
          JSON.generate(activity("usage_observed", "event-usage", "input" => 100)) + "\n"
      )

      result = Hive::DailyDigest::ProjectSource.new(
        project: project_entry(project),
        starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-31T00:00:00Z")
      ).collect

      assert_equal %w[stage_transition task_created], result.facts.map { |fact| fact.fetch("kind") }.sort
      assert_empty result.gaps
      assert_equal "task_journal", result.frontier.fetch("source")
      assert result.frontier.fetch("fingerprints").all? { |value| value.match?(/\A[0-9a-f]{64}\z/) }
    end
  end

  def test_unknown_stage_and_malformed_journal_are_scoped_gaps
    with_tmp_dir do |project|
      hive_state = File.join(project, ".hive-state")
      unknown = File.join(hive_state, "stages", "77-unknown", "legacy-task")
      malformed = File.join(hive_state, "stages", "4-execute", "bad-task")
      FileUtils.mkdir_p([ unknown, malformed ])
      File.write(File.join(unknown, "state.md"), "material\n")
      File.write(File.join(malformed, "task.md"), "# task\n")
      File.write(File.join(malformed, "task-journal.jsonl"), "not-json\n")

      result = Hive::DailyDigest::ProjectSource.new(
        project: project_entry(project),
        starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-31T00:00:00Z"),
        known_stage_dirs: %w[4-execute]
      ).collect

      assert_equal %w[malformed_journal unknown_stage],
                   result.gaps.map { |gap| gap.fetch("reason_code") }.sort
    end
  end

  def test_symlink_task_escape_is_rejected_without_suppressing_healthy_tasks
    with_tmp_dir do |project|
      with_tmp_dir do |outside|
        stages = File.join(project, ".hive-state", "stages", "4-execute")
        healthy = File.join(stages, "healthy-task")
        FileUtils.mkdir_p(healthy)
        File.write(File.join(healthy, "task.md"), "# task\n")
        File.symlink(outside, File.join(stages, "escaped-task"))

        result = Hive::DailyDigest::ProjectSource.new(
          project: project_entry(project),
          starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
          ends_at: Time.iso8601("2026-08-31T00:00:00Z"),
          known_stage_dirs: %w[4-execute]
        ).collect

        assert_equal [ "unsafe_task_path" ], result.gaps.map { |gap| gap.fetch("reason_code") }
      end
    end
  end

  def test_boundary_attention_uses_durable_question_transitions_without_content
    with_tmp_dir do |project|
      task_folder = File.join(project, ".hive-state", "stages", "2-brainstorm", "waiting-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "brainstorm.md"), "Question: top secret?\n")
      asked = activity("question_asked", "event-question",
                       "question_id" => "Q1", "question_fingerprint" => "f" * 64)
      asked["task"] = { "id" => "7", "slug" => "waiting-task" }
      asked["stage"] = "2-brainstorm"
      asked["occurred_at"] = "2026-08-29T10:00:00.000000Z"
      File.write(File.join(task_folder, "task-journal.jsonl"), JSON.generate(asked) + "\n")

      result = Hive::DailyDigest::ProjectSource.new(
        project: project_entry(project),
        starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-31T00:00:00Z"),
        known_stage_dirs: %w[2-brainstorm]
      ).collect

      item = result.attention.fetch(0)
      assert_equal "unanswered", item.fetch("kind")
      assert_equal 136_800, item.fetch("waiting_age_seconds")
      assert_equal "/tasks/demo/waiting-task#task-questions", item.fetch("task_path")
      refute_includes JSON.generate(item), "secret"
      refute_includes item.keys, "question"
    end
  end

  def test_pr_fact_uses_hive_owned_document_and_names_missing_required_evidence
    with_tmp_dir do |project|
      task_folder = File.join(project, ".hive-state", "stages", "5-open-pr", "pr-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/acme/demo/pull/42
        pr_number: 42
        head_oid: #{"a" * 40}
        ---
        # PR
      MD
      event = activity("pr_observed", "event-pr", "pr_state" => "draft")
      event["task"] = { "id" => "9", "slug" => "pr-task" }
      event["stage"] = "5-open-pr"
      File.write(File.join(task_folder, "task-journal.jsonl"), JSON.generate(event) + "\n")

      result = Hive::DailyDigest::ProjectSource.new(
        project: project_entry(project),
        starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-31T00:00:00Z"),
        known_stage_dirs: %w[5-open-pr]
      ).collect

      fact = result.facts.fetch(0)
      assert_equal 42, fact.dig("details", "pr_number")
      assert_equal "https://github.com/acme/demo/pull/42", fact.dig("details", "pr_url")
      assert_equal "a" * 40, fact.dig("details", "head_oid")
      assert_empty result.gaps

      File.delete(File.join(task_folder, "pr.md"))
      degraded = Hive::DailyDigest::ProjectSource.new(
        project: project_entry(project),
        starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
        ends_at: Time.iso8601("2026-08-31T00:00:00Z"),
        known_stage_dirs: %w[5-open-pr]
      ).collect
      assert_equal [ "pr_evidence_incomplete" ],
                   degraded.gaps.map { |gap| gap.fetch("reason_code") }
    end
  end

  private

  def project_entry(project)
    {
      "project_id" => "project-1", "registration_id" => "registration-1",
      "name" => "demo", "path" => project,
      "hive_state_path" => File.join(project, ".hive-state")
    }
  end

  def activity(kind, event_id, payload = {})
    {
      "schema" => "hive-task-journal", "schema_version" => 1,
      "event_id" => event_id, "event_type" => "activity_recorded",
      "occurred_at" => "2026-08-30T10:00:00.000000Z",
      "observed_at" => "2026-08-30T10:00:01.000000Z",
      "stage" => "4-execute", "attempt_id" => "attempt-1", "task_generation" => 1,
      "task" => { "id" => "42", "slug" => "digest-task" },
      "reason" => "changed", "evidence" => [],
      "provenance" => { "source" => "test" },
      "payload" => payload.merge("activity_kind" => kind, "operation_id" => "operation:#{kind}")
    }
  end
end
