require "test_helper"
require "hive/task_fingerprint"

class TaskFingerprintTest < Minitest::Test
  def row(**overrides)
    {
      stage: "4-execute",
      workflow: :coding,
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
    refute_equal original, Hive::TaskFingerprint.for_row(row(implementation_identity: { "provider" => "claude" }))
    assert_equal original, Hive::TaskFingerprint.for_row(row(mtime: Time.now, age_seconds: 99))
  end

  def test_hash_order_does_not_change_the_fingerprint
    reordered = row(marker_attrs: { "reason" => "done", "pass" => "1" })

    assert_equal Hive::TaskFingerprint.for_row(row), Hive::TaskFingerprint.for_row(reordered)
  end

  def test_card_digest_excludes_only_volatile_age_and_itself
    card = { "slug" => "task", "age_seconds" => 2, "lock" => { "live" => false } }
    original = Hive::TaskFingerprint.card_digest(card)

    assert_equal original, Hive::TaskFingerprint.card_digest(card.merge("age_seconds" => 30))
    refute_equal original,
                 Hive::TaskFingerprint.card_digest(card.merge("lock" => { "live" => true }))
  end
end
