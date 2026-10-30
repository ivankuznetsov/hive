require "test_helper"
require "hive/plan_review/identity"
require "tmpdir"

class PlanReviewIdentityTest < Minitest::Test
  def test_logical_identity_is_stable_and_policy_or_plan_changes_roll_it
    first = Hive::PlanReview::Identity.logical(
      task_id: "task-1", plan_generation: "plan-a", policy_fingerprint: "b" * 64
    )
    same = Hive::PlanReview::Identity.logical(
      task_id: "task-1", plan_generation: "plan-a", policy_fingerprint: "b" * 64
    )
    changed = Hive::PlanReview::Identity.logical(
      task_id: "task-1", plan_generation: "plan-c", policy_fingerprint: "b" * 64
    )

    assert_equal first, same
    refute_equal first, changed
    assert_match(/\Apr-[0-9a-f]{64}\z/, first)
  end

  def test_attempts_are_distinct_and_decisions_are_idempotently_derived
    review_id = "pr-#{'a' * 64}"
    refute_equal Hive::PlanReview::Identity.attempt(review_id),
                 Hive::PlanReview::Identity.attempt(review_id)

    first = Hive::PlanReview::Identity.decision(
      review_id:, target_fingerprint: "finding-a", action: "approve", value: "yes"
    )
    same = Hive::PlanReview::Identity.decision(
      review_id:, target_fingerprint: "finding-a", action: :approve, value: "yes"
    )
    conflict = Hive::PlanReview::Identity.decision(
      review_id:, target_fingerprint: "finding-a", action: "approve", value: "no"
    )
    assert_equal first, same
    refute_equal first, conflict
  end

  def test_task_generation_falls_back_to_the_slug_on_a_bare_task
    bare = Data.define(:slug).new(slug: "slug-260812-abcd")
    other = Data.define(:slug).new(slug: "slug-260812-beef")

    assert_match(/\A[0-9a-f]{64}\z/, Hive::PlanReview::Identity.task_generation(bare))
    assert_equal Hive::PlanReview::Identity.task_generation(bare),
                 Hive::PlanReview::Identity.task_generation(bare)
    refute_equal Hive::PlanReview::Identity.task_generation(bare),
                 Hive::PlanReview::Identity.task_generation(other)
  end

  MetaTask = Data.define(:slug, :meta_yml_path)

  def with_meta(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "meta.yml")
      File.write(path, content)
      yield MetaTask.new(slug: "slug-260812-abcd", meta_yml_path: path), path
    end
  end

  # Adopting a revised plan's dependency at promotion rewrites meta.yml; the
  # review it completes must stay current, while any other metadata change
  # still rolls the generation.
  def test_task_generation_ignores_depends_on_but_not_other_metadata
    identity = Hive::PlanReview::Identity
    with_meta("id: 1\nslug: slug-260812-abcd\n") do |task, path|
      before = identity.task_generation(task)
      legacy = identity.legacy_task_generation(task)
      File.write(path, "id: 1\nslug: slug-260812-abcd\ndepends_on:\n  - base-task\n")

      assert_equal before, identity.task_generation(task)
      refute_equal legacy, identity.legacy_task_generation(task)
      assert identity.task_generation_current?(task, before)
      refute identity.task_generation_current?(task, legacy)

      File.write(path, "id: 2\nslug: slug-260812-abcd\ndepends_on:\n  - base-task\n")
      refute identity.task_generation_current?(task, before)
    end
  end

  # Reviews recorded under the raw-bytes formula stay current until meta.yml
  # actually changes.
  def test_legacy_recorded_generation_stays_current_for_unchanged_metadata
    identity = Hive::PlanReview::Identity
    with_meta("id: 1\ndepends_on: base-task\n") do |task, _path|
      legacy = identity.legacy_task_generation(task)

      refute_equal legacy, identity.task_generation(task)
      assert identity.task_generation_current?(task, legacy)
      refute identity.task_generation_current?(task, "0" * 64)
    end
  end

  def test_unparseable_metadata_falls_back_to_raw_bytes
    identity = Hive::PlanReview::Identity
    [ "id: [1\n", "- just\n- a list\n", "a: &x 1\nb: *x\n", "ratio: .nan\n" ].each do |content|
      with_meta(content) do |task, _path|
        assert_equal identity.legacy_task_generation(task), identity.task_generation(task), content
      end
    end
  end
end
