require "test_helper"
require "hive/task_fingerprint"

class TaskFingerprintTest < Minitest::Test
  def row(**overrides)
    {
      stage: "4-execute",
      workflow: :coding,
      workflow_semantics: {
        "id" => "coding",
        "stages" => [ { "name" => "execute", "advance_verb" => { "name" => "develop" } } ]
      },
      marker_name: :execute_complete,
      marker_attrs: { "pass" => "1", "reason" => "done" },
      depends_on: "base-task",
      task_generation: "generation-1",
      condition_task_generation: 2,
      commit_generation: 3,
      condition_gate: { "eligible" => true },
      implementation_identity: { "provider" => "codex" }
    }.merge(overrides)
  end

  def test_semantic_inputs_change_without_using_mtime
    original = Hive::TaskFingerprint.for_row(row)

    refute_equal original, Hive::TaskFingerprint.for_row(row(marker_attrs: { "pass" => "2", "reason" => "done" }))
    refute_equal original, Hive::TaskFingerprint.for_row(row(depends_on: "other-task"))
    refute_equal original, Hive::TaskFingerprint.for_row(row(workflow: :content))
    refute_equal original,
                 Hive::TaskFingerprint.for_row(
                   row(workflow_semantics: row.fetch(:workflow_semantics).merge(
                     "stages" => [ { "name" => "execute", "advance_verb" => { "name" => "build" } } ]
                   ))
                 )
    refute_equal original, Hive::TaskFingerprint.for_row(row(implementation_identity: { "provider" => "claude" }))
    assert_equal original, Hive::TaskFingerprint.for_row(row(mtime: Time.now, age_seconds: 99))
  end

  def test_hash_order_does_not_change_the_fingerprint
    reordered = row(marker_attrs: { "reason" => "done", "pass" => "1" })

    assert_equal Hive::TaskFingerprint.for_row(row), Hive::TaskFingerprint.for_row(reordered)
  end

  def test_resolved_workflow_digest_changes_when_same_id_semantics_change
    original = workflow_with_verb("develop")
    changed = workflow_with_verb("build")

    assert_match(/\Awf1:[0-9a-f]{64}\z/, Hive::TaskFingerprint.workflow_semantics(original))
    refute_equal Hive::TaskFingerprint.workflow_semantics(original),
                 Hive::TaskFingerprint.workflow_semantics(changed)
  end

  def test_card_digest_tracks_card_semantics_without_detail_only_payloads
    card = {
      "slug" => "task", "age_seconds" => 2, "lock" => { "live" => false },
      "condition_history" => [ { "state" => "pending" } ]
    }
    original = Hive::TaskFingerprint.card_digest(card)

    assert_equal original, Hive::TaskFingerprint.card_digest(card.merge("age_seconds" => 30))
    assert_equal original,
                 Hive::TaskFingerprint.card_digest(
                   card.merge("condition_history" => [ { "state" => "passed" } ])
                 )
    refute_equal original,
                 Hive::TaskFingerprint.card_digest(card.merge("lock" => { "live" => true }))
  end


  private

  def workflow_with_verb(verb)
    Hive::Workflow.new(
      id: :coding,
      stages: [
        Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
        Hive::Workflow::Stage.new(
          name: "execute", index: 2, state_file: "task.md", kind: :execute,
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: verb)
        )
      ]
    )
  end
end
