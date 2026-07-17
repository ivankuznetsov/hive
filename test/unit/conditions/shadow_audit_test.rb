require "test_helper"
require "hive/conditions/shadow_audit"

class ConditionsShadowAuditTest < Minitest::Test
  TaskStub = Struct.new(:id, :slug, keyword_init: true)
  AttemptStub = Struct.new(:attempt_id, :ownership_generation, keyword_init: true)

  def test_event_carries_structured_parity_provenance
    event = Hive::Conditions::ShadowAudit.event(
      task: TaskStub.new(id: 42, slug: "task"),
      attempt: AttemptStub.new(attempt_id: "attempt-1", ownership_generation: "owner-1"),
      task_generation: 2, commit_generation: 3, category: "commit_success",
      marker_action: "ready_to_open_pr", condition_action: "needs_input"
    )

    assert_equal "shadow_audit", event.fetch(:event_type)
    assert_equal "shadow_mismatch", event.fetch(:reason)
    assert_equal false, event.dig(:payload, "match")
    assert_raises(ArgumentError) do
      Hive::Conditions::ShadowAudit.event(
        task: TaskStub.new(id: 42, slug: "task"),
        attempt: AttemptStub.new(attempt_id: "attempt-1", ownership_generation: "owner-1"),
        task_generation: 2, commit_generation: 3, category: "unknown",
        marker_action: "x", condition_action: "x"
      )
    end
  end

  def test_readiness_requires_count_categories_zero_unexplained_empty_allow_list_and_green_fixtures
    records = 100.times.map do |index|
      category = Hive::Conditions::ShadowAudit::CATEGORIES[index % 5]
      audit_record(category: category)
    end
    ready = Hive::Conditions::ShadowAudit.summary(
      records: records, allow_list: [], fixture_status: { "task-1849" => true }
    )
    assert ready.fetch("ready")
    assert ready.fetch("parity_ready")
    assert_equal false, ready.fetch("external_fixture_evidence_required")
    assert_equal false, ready.fetch("automatic_promotion")

    variants = [
      [ records.first(99), [], { "task-1849" => true } ],
      [ records.reject { |record| record.dig("payload", "category") == "agent_loss" }, [],
        { "task-1849" => true } ],
      [ records + [ audit_record(category: "commit_success", match: false) ], [],
        { "task-1849" => true } ],
      [ records, [ "known-drift" ], { "task-1849" => true } ],
      [ records, [], { "task-1849" => false } ],
      [ records, [], {} ]
    ]
    variants.each do |candidate_records, allow_list, fixtures|
      summary = Hive::Conditions::ShadowAudit.summary(
        records: candidate_records, allow_list: allow_list, fixture_status: fixtures
      )
      refute summary.fetch("ready")
    end

    projection_only = Hive::Conditions::ShadowAudit.summary(records: records)
    assert projection_only.fetch("parity_ready")
    assert projection_only.fetch("external_fixture_evidence_required")
    refute projection_only.fetch("ready")
  end

  def test_explained_mismatch_is_reported_but_does_not_count_as_unexplained
    records = 100.times.map do |index|
      audit_record(category: Hive::Conditions::ShadowAudit::CATEGORIES[index % 5])
    end
    records << audit_record(category: "commit_success", match: false, explained: true)
    summary = Hive::Conditions::ShadowAudit.summary(
      records: records, fixture_status: { "task-1849" => true }
    )
    assert_equal 1, summary.fetch("explained_mismatches")
    assert_equal 0, summary.fetch("unexplained_mismatches")
    assert summary.fetch("ready")
  end

  private

  def audit_record(category:, match: true, explained: false)
    {
      "event_type" => "shadow_audit",
      "payload" => {
        "category" => category,
        "match" => match,
        "explained" => explained
      }
    }
  end
end
