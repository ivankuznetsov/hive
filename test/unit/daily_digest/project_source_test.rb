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
      assert result.frontier.fetch("fingerprints").values.all? do |value|
        value.fetch("sha256").match?(/\A[0-9a-f]{64}\z/)
      end
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
      File.write(File.join(malformed, "task-journal.jsonl"), "not-json\n[]\n")

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

  def test_structurally_malformed_activity_is_aggregated_without_aborting_collection
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "4-execute", "bad-task")
      FileUtils.mkdir_p(task)
      malformed = activity("stage_transition", "event-bad", "transition" => "completed")
      malformed["payload"] = "broken"
      File.write(File.join(task, Hive::TaskJournal::JOURNAL_BASENAME), JSON.generate(malformed) + "\n")

      result = build_source(project, known_stage_dirs: %w[4-execute]).collect

      assert_empty result.facts
      assert_equal [ "malformed_journal" ], result.gaps.map { |gap| gap.fetch("reason_code") }
    end
  end

  def test_unchanged_fingerprints_skip_receipt_and_journal_reads
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "4-execute", "task")
      FileUtils.mkdir_p(task)
      Hive::DailyDigest::TaskCreationReceipt.write!(
        task_folder: task, project: { "project_id" => "project-1", "name" => "demo" },
        task: { "id" => 42, "slug" => "task" }, workflow: "coding", stage: "1-inbox",
        created_at: "2026-08-30T08:00:00Z"
      )
      journal = File.join(task, Hive::TaskJournal::JOURNAL_BASENAME)
      File.write(journal, JSON.generate(activity("stage_transition", "event-stage",
                                                "transition" => "completed")) + "\n")
      first = build_source(project, known_stage_dirs: %w[4-execute]).collect
      source = Hive::DailyDigest::ProjectSource.new(
        project: project_entry(project), starts_at: "2026-08-30T00:00:00Z",
        ends_at: "2026-08-31T00:00:00Z", known_stage_dirs: %w[4-execute],
        prior_frontier: first.frontier
      )
      evidence = [ journal, Hive::DailyDigest::TaskCreationReceipt.path(task) ]
      original = File.method(:binread)

      with_replaced_singleton_method(
        File, :binread,
        ->(path, *args) { evidence.include?(path) ? flunk("unchanged evidence was read") : original.call(path, *args) }
      ) do
        second = source.collect
        assert_empty second.facts
        assert_equal first.frontier.fetch("fingerprints"), second.frontier.fetch("fingerprints")
      end
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
        known_stage_dirs: %w[2-brainstorm],
        observed_at: -> { Time.iso8601("2026-08-30T12:00:00Z") }
      ).collect

      item = result.attention.fetch(0)
      assert_equal "unanswered", item.fetch("kind")
      assert_equal 93_600, item.fetch("waiting_age_seconds")
      assert_equal "2026-08-29T10:00:00.000000Z", item.fetch("waiting_since")
      assert_equal "/tasks/demo/waiting-task#task-questions", item.fetch("task_url")
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
      assert_equal 42, fact.dig("pr", "number")
      assert_equal "https://github.com/acme/demo/pull/42", fact.dig("pr", "url")
      assert_equal "/tasks/demo/pr-task", fact.fetch("task_url")
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

  def test_symlinked_known_stage_is_a_scoped_gap_and_is_not_traversed
    with_tmp_dir do |project|
      with_tmp_dir do |outside|
        stages = File.join(project, ".hive-state", "stages")
        FileUtils.mkdir_p(stages)
        FileUtils.mkdir_p(File.join(outside, "escaped-task"))
        File.symlink(outside, File.join(stages, "4-execute"))

        result = build_source(project, known_stage_dirs: %w[4-execute]).collect

        assert_empty result.facts
        assert_equal [ "unsafe_stage_path" ], result.gaps.map { |gap| gap.fetch("reason_code") }
      end
    end
  end

  def test_waiting_marker_without_a_durable_entry_transition_creates_a_boundary_gap
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "2-brainstorm", "legacy-waiting")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "brainstorm.md"), "# Brainstorm\n\n<!-- WAITING -->\n")

      result = build_source(project, known_stage_dirs: %w[2-brainstorm]).collect

      assert_empty result.attention
      assert_equal [ "boundary_history_missing" ],
                   result.gaps.map { |gap| gap.fetch("reason_code") }
    end
  end

  def test_one_collection_uses_one_observation_instant_for_gaps_and_frontier
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "4-execute", "bad-task")
      FileUtils.mkdir_p(task)
      malformed = activity("stage_transition", "bad")
      malformed["occurred_at"] = "bad"
      malformed["observed_at"] = "bad"
      File.write(File.join(task, Hive::TaskJournal::JOURNAL_BASENAME), JSON.generate(malformed) + "\n")
      calls = 0
      source = Hive::DailyDigest::ProjectSource.new(
        project: project_entry(project), starts_at: "2026-08-30T00:00:00Z",
        ends_at: "2026-08-31T00:00:00Z", known_stage_dirs: %w[4-execute],
        observed_at: lambda {
          calls += 1
          Time.iso8601("2026-08-30T12:00:00Z")
        }
      )

      result = source.collect

      assert_equal 1, calls
      assert_equal result.frontier.fetch("observed_at"), result.gaps.fetch(0).fetch("observed_at")
    end
  end

  def test_missing_unreadable_and_escaping_project_state_are_typed
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      source = build_source(project)
      assert_raises(Hive::DailyDigest::ProjectSource::SourceUnavailable) { source.collect }

      FileUtils.remove_entry(state)
      assert_raises(Hive::DailyDigest::ProjectSource::SourceUnavailable) { source.collect }

      with_tmp_dir do |outside|
        FileUtils.mkdir_p(File.join(outside, "stages"))
        escaped = Hive::DailyDigest::ProjectSource.new(
          project: project_entry(project).merge("hive_state_path" => outside),
          starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
          ends_at: Time.iso8601("2026-08-31T00:00:00Z"), known_stage_dirs: []
        )
        assert_raises(Hive::DailyDigest::ProjectSource::SourceUnavailable) { escaped.collect }
      end
    end
  end

  def test_system_failures_are_redacted_as_source_unavailable
    with_tmp_dir do |project|
      stages = File.join(project, ".hive-state", "stages")
      FileUtils.mkdir_p(stages)
      original = Dir.method(:children)
      with_replaced_singleton_method(
        Dir, :children,
        ->(path) { path == stages ? (raise Errno::EACCES, "secret path") : original.call(path) }
      ) do
        error = assert_raises(Hive::DailyDigest::ProjectSource::SourceUnavailable) do
          build_source(project).collect
        end
        assert_match(/registered project evidence is unavailable \(Errno::EACCES\)/, error.message)
        refute_includes error.message, "secret path"
      end
    end
  end

  def test_realpath_failure_is_typed_as_unavailable_state
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "stages"))
      source = build_source(project)
      original = File.method(:realpath)
      with_replaced_singleton_method(
        File, :realpath,
        ->(path) { path == state ? (raise Errno::EACCES, "denied") : original.call(path) }
      ) do
        assert_raises(Hive::DailyDigest::ProjectSource::SourceUnavailable) do
          source.send(:verified_state_root!)
        end
      end
    end
  end

  def test_stage_root_escape_and_realpath_races_fail_closed
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      stages = File.join(state, "stages")
      stage = File.join(stages, "4-execute")
      FileUtils.mkdir_p(stage)
      source = build_source(project, known_stage_dirs: %w[4-execute])
      original = File.method(:realpath)

      with_replaced_singleton_method(
        File, :realpath,
        ->(path) { path == stages ? File.join(project, "escaped-stages") : original.call(path) }
      ) do
        error = assert_raises(Hive::DailyDigest::ProjectSource::SourceUnavailable) do
          source.send(:verified_stages_root!, File.realpath(state))
        end
        assert_match(/stages escape/, error.message)
      end

      with_replaced_singleton_method(
        File, :realpath,
        ->(path) { path == stages ? (raise Errno::ENOENT, "removed") : original.call(path) }
      ) do
        assert_raises(Hive::DailyDigest::ProjectSource::SourceUnavailable) do
          source.send(:verified_stages_root!, File.realpath(state))
        end
      end

      with_replaced_singleton_method(
        File, :realpath,
        ->(path) { path == stage ? (raise Errno::EACCES, "denied") : original.call(path) }
      ) do
        refute source.send(:safe_stage_root?, stage, stages)
      end
    end
  end

  def test_symlinked_malformed_and_oversized_task_evidence_becomes_scoped_gaps
    with_tmp_dir do |project|
      stage = File.join(project, ".hive-state", "stages", "4-execute")
      FileUtils.mkdir_p(stage)
      with_tmp_dir do |outside|
        receipt_link = File.join(stage, "receipt-link")
        malformed_receipt = File.join(stage, "malformed-receipt")
        journal_link = File.join(stage, "journal-link")
        oversized = File.join(stage, "oversized")
        oversized_receipt = File.join(stage, "oversized-receipt")
        [ receipt_link, malformed_receipt, journal_link, oversized, oversized_receipt ].each do |path|
          FileUtils.mkdir_p(path)
        end
        File.write(File.join(outside, "receipt.json"), "{}")
        File.symlink(
          File.join(outside, "receipt.json"),
          Hive::DailyDigest::TaskCreationReceipt.path(receipt_link)
        )
        File.write(Hive::DailyDigest::TaskCreationReceipt.path(malformed_receipt), "not-json")
        File.write(File.join(outside, "journal.jsonl"), "{}\n")
        File.symlink(
          File.join(outside, "journal.jsonl"),
          File.join(journal_link, Hive::TaskJournal::JOURNAL_BASENAME)
        )
        large = File.join(oversized, Hive::TaskJournal::JOURNAL_BASENAME)
        File.write(large, "")
        File.truncate(large, Hive::DailyDigest::ProjectSource::MAX_JOURNAL_BYTES + 1)
        receipt = Hive::DailyDigest::TaskCreationReceipt.path(oversized_receipt)
        File.write(receipt, "")
        File.truncate(receipt, Hive::DailyDigest::ProjectSource::MAX_CREATION_RECEIPT_BYTES + 1)

        reasons = build_source(project, known_stage_dirs: %w[4-execute]).collect.gaps
                                                                       .map { |gap| gap.fetch("reason_code") }
        assert_equal %w[creation_receipt_too_large journal_too_large malformed_creation_receipt unsafe_creation_receipt unsafe_journal],
                     reasons.sort
      end
    end
  end

  def test_activity_gaps_unreadable_journals_and_unsafe_paths_are_isolated
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "4-execute", "task")
      FileUtils.mkdir_p(task)
      journal = File.join(task, Hive::TaskJournal::JOURNAL_BASENAME)
      File.write(
        journal,
        JSON.generate(activity("activity_gap", "event-gap", "reason_code" => "legacy_gap")) + "\n"
      )
      result = build_source(project, known_stage_dirs: %w[4-execute]).collect
      assert_equal [ "legacy_gap" ], result.gaps.map { |gap| gap.fetch("reason_code") }

      source = build_source(project, known_stage_dirs: %w[4-execute])
      facts = []
      gaps = []
      original = File.method(:binread)
      with_replaced_singleton_method(
        File, :binread,
        ->(path, *args) { path == journal ? (raise Errno::EACCES, "denied") : original.call(path, *args) }
      ) do
        source.send(:collect_journal, task, facts, gaps, [], {})
      end
      assert_equal [ "unreadable_journal" ], gaps.map { |gap| gap.fetch("reason_code") }
      assert_equal true, source.send(:unsafe_task_path?, File.join(task, "missing"), task)
      assert_equal false, source.send(:in_window?, "bad-time")

      original_empty = Dir.method(:empty?)
      with_replaced_singleton_method(
        Dir, :empty?, ->(path) { path == task ? (raise Errno::EACCES, "denied") : original_empty.call(path) }
      ) do
        assert_equal false, source.send(:directory_empty?, task)
      end
    end
  end

  def test_invalid_pr_documents_and_missing_check_state_create_bounded_degradation
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "5-open-pr", "pr-task")
      FileUtils.mkdir_p(task)
      File.write(File.join(task, "pr.md"), "---\ninvalid: [\n---\n")
      source = build_source(project, known_stage_dirs: %w[5-open-pr])
      assert_equal({}, source.send(:load_pr_core, task))

      File.write(File.join(task, "pr.md"), <<~MD)
        ---
        pr_url: https://github.com/acme/demo/pull/42
        pr_number: 42
        head_oid: #{"a" * 40}
        ---
      MD
      check = activity("check_observed", "event-check", "pr_state" => "open")
      File.write(File.join(task, Hive::TaskJournal::JOURNAL_BASENAME), JSON.generate(check) + "\n")
      result = source.collect

      assert_equal [ "check_observed" ], result.facts.map { |fact| fact.fetch("kind") }
      assert_equal [ "pr_evidence_incomplete" ], result.gaps.map { |gap| gap.fetch("reason_code") }
      assert_equal false, source.send(:before_boundary?, "bad-time")

      review = activity(
        "review_observed", "event-review", "pr_number" => 42,
        "pr_url" => "https://github.com/acme/demo/pull/42", "head_oid" => "a" * 40
      )
      assert source.send(:incomplete_pr_evidence?, review)
    end
  end

  def test_boundary_marker_read_errors_are_not_treated_as_attention
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "2-brainstorm", "task")
      FileUtils.mkdir_p(task)
      source = build_source(project, known_stage_dirs: %w[2-brainstorm])

      with_replaced_singleton_method(
        Hive::Markers, :current, ->(_path) { raise IOError, "marker unavailable" }
      ) do
        refute source.send(:boundary_marker?, task)
      end
    end
  end

  def test_boundary_attention_reconstructs_answers_holds_failures_and_recoveries
    with_tmp_dir do |project|
      task = File.join(project, ".hive-state", "stages", "2-brainstorm", "waiting task")
      source = build_source(project, known_stage_dirs: %w[2-brainstorm])
      rows = [
        boundary_activity("usage_observed", "invalid-time", occurred_at: "bad-time"),
        boundary_activity("question_asked", "01-question-answered", { "question_id" => "Q1" }),
        boundary_activity("answer_recorded", "02-answer", { "question_id" => "Q1" }),
        boundary_activity("question_asked", "03-question-open", { "question_id" => "Q2" }),
        boundary_activity(
          "hold_recorded", "04-hold-active", { "hold_kind" => "provider", "state" => "active" }
        ),
        boundary_activity(
          "hold_recorded", "05-hold-cleared", { "hold_kind" => "provider", "state" => "cleared" }
        ),
        boundary_activity(
          "resource_limit_observed", "06-hold-open", { "resource_kind" => "capacity", "state" => "active" }
        ),
        boundary_activity("session_finished", "07-failure-cleared", { "outcome" => "failed" }),
        boundary_activity("recovery_recorded", "08-recovered", { "outcome" => "recovered" }),
        boundary_activity("session_finished", "09-failure-open", { "health" => "unhealthy" }),
        boundary_activity(
          "resource_limit_observed", "10-hold-after-recovery",
          { "resource_kind" => "provider", "state" => "active" }
        )
      ]
      rows.each { |row| row["task"] = { "id" => "42", "slug" => "waiting task" } }

      attention = source.send(:boundary_attention, { task => rows })

      assert_equal %w[blocked failed unanswered], attention.map { |row| row.fetch("kind") }.sort
      blocked = attention.find { |row| row.fetch("kind") == "blocked" }
      assert_equal "blocked", blocked.fetch("state")
      assert_includes blocked.fetch("task_url"), "waiting%20task"
      refute_includes JSON.generate(attention), "question_id"

      completed = rows + [
        boundary_activity("session_finished", "11-success", { "outcome" => "completed" }),
        boundary_activity(
          "stage_transition", "12-done", { "transition" => "completed", "to_stage" => "9-done" }
        )
      ]
      assert_empty source.send(:boundary_attention, { task => completed })
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

  def build_source(project, known_stage_dirs: [])
    Hive::DailyDigest::ProjectSource.new(
      project: project_entry(project),
      starts_at: Time.iso8601("2026-08-30T00:00:00Z"),
      ends_at: Time.iso8601("2026-08-31T00:00:00Z"),
      known_stage_dirs: known_stage_dirs,
      observed_at: -> { Time.iso8601("2026-08-31T01:00:00Z") }
    )
  end

  def boundary_activity(kind, event_id, payload = {}, occurred_at: "2026-08-30T10:00:00Z")
    activity(kind, event_id, payload).merge("occurred_at" => occurred_at)
  end
end
