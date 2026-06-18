require "test_helper"
require "hive/dependencies"

class DependenciesTest < Minitest::Test
  Task = Struct.new(:slug, :id, :stage_index, :stage, keyword_init: true)

  def test_resolve_blocks_when_prerequisite_is_before_threshold
    result = Hive::Dependencies.resolve(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 7) ],
      threshold_stage: "8-finalize"
    )

    assert_equal true, result.blocked
    assert_equal false, result.unresolved?
    assert_equal "base-task", result.blocked_by
    assert_equal "7-artifacts", result.dependency_stage
  end

  def test_resolve_unblocks_at_and_after_threshold
    at_threshold = Hive::Dependencies.resolve(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 8) ],
      threshold_stage: "8-finalize"
    )
    after_threshold = Hive::Dependencies.resolve(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 9) ],
      threshold_stage: "8-finalize"
    )

    assert_equal false, at_threshold.blocked
    assert_equal "8-finalize", at_threshold.dependency_stage
    assert_equal false, after_threshold.blocked
    assert_equal "9-done", after_threshold.dependency_stage
  end

  def test_resolve_missing_dependency_stays_blocked_unresolved
    result = Hive::Dependencies.resolve(
      depends_on: "missing-task",
      tasks: [ task("base-task", stage_index: 8) ],
      threshold_stage: "8-finalize"
    )

    assert_equal true, result.blocked
    assert_equal true, result.unresolved?
    assert_nil result.blocked_by
    assert_nil result.dependency_stage
  end

  def test_resolve_matches_numeric_id
    result = Hive::Dependencies.resolve(
      depends_on: "42",
      tasks: [ task("base-task", id: 42, stage_index: 8) ],
      threshold_stage: "8-finalize"
    )

    assert_equal false, result.blocked
    assert_equal "base-task", result.blocked_by
  end

  def test_self_reference_stays_blocked_unresolved
    current = task("current-task", id: 42, stage_index: 4)
    result = Hive::Dependencies.resolve(
      depends_on: "current-task",
      tasks: [ current ],
      threshold_stage: "8-finalize",
      task: current
    )

    assert_equal true, result.blocked
    assert_equal true, result.unresolved?
    assert_nil result.blocked_by
    assert_nil result.dependency_stage
  end

  def test_no_dependency_is_unblocked
    result = Hive::Dependencies.resolve(
      depends_on: nil,
      tasks: [ task("base-task", stage_index: 1) ],
      threshold_stage: "8-finalize"
    )

    assert_equal false, result.blocked
    assert_equal false, result.unresolved?
    assert_nil result.blocked_by
    assert_nil result.dependency_stage
  end

  def test_base_branch_for_resolvable_dependency_returns_prerequisite_slug
    branch = Hive::Dependencies.base_branch_for(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 8) ],
      default_branch: "main"
    )

    assert_equal "base-task", branch
  end

  # Stacking is threshold-blind by design: base_branch_for returns the
  # prerequisite slug regardless of how far the prereq has progressed, so a
  # dependent worktree branches off the prereq even while the gate still
  # blocks dispatch. Pin both a below-threshold and an at/after-threshold
  # prereq to lock that contract independent of `resolve`'s gate.
  def test_base_branch_for_is_threshold_blind
    below_gate = Hive::Dependencies.base_branch_for(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 4) ],
      default_branch: "main"
    )
    after_gate = Hive::Dependencies.base_branch_for(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 9) ],
      default_branch: "main"
    )

    assert_equal "base-task", below_gate,
                 "stacking must return the prereq slug even below the gate"
    assert_equal "base-task", after_gate,
                 "stacking must return the prereq slug at/after the gate"
  end

  def test_base_branch_for_nil_missing_or_self_dependency_returns_default_branch
    current = task("current-task", id: 42, stage_index: 4)
    tasks = [ current ]

    assert_equal "main",
                 Hive::Dependencies.base_branch_for(depends_on: nil, tasks: tasks, default_branch: "main")
    assert_equal "main",
                 Hive::Dependencies.base_branch_for(depends_on: "missing", tasks: tasks, default_branch: "main")
    assert_equal "main",
                 Hive::Dependencies.base_branch_for(
                   depends_on: "current-task",
                   tasks: tasks,
                   default_branch: "main",
                   task: current
                 )
  end

  def test_threshold_stage_is_honored
    result = Hive::Dependencies.resolve(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 8) ],
      threshold_stage: "9-done"
    )

    assert_equal true, result.blocked
    assert_equal "8-finalize", result.dependency_stage
  end

  def test_hash_tasks_are_supported
    result = Hive::Dependencies.resolve(
      depends_on: "base-task",
      tasks: [ { "slug" => "base-task", "id" => "42", "stage" => "finalize" } ],
      threshold_stage: "8-finalize"
    )

    assert_equal false, result.blocked
    assert_equal "base-task", result.blocked_by
    assert_equal "8-finalize", result.dependency_stage
  end

  private

  def task(slug, id: nil, stage_index: nil, stage: nil)
    Task.new(slug: slug, id: id, stage_index: stage_index, stage: stage)
  end
end
