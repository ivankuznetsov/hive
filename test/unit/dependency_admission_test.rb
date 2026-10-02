require "test_helper"
require "hive/dependency_admission"

class DependencyAdmissionTest < Minitest::Test
  D = Hive::DependencyAdmission

  def test_no_dependency_is_clear
    verdict = context(project(tasks: [ task("app", "solo") ])).verdict(project: "app", slug: "solo")

    assert verdict.clear?
    assert_nil verdict.admission_error
  end

  def test_same_project_slug_and_numeric_refs_wait_below_gate_and_release_at_gate
    %w[base 7].each do |reference|
      below = project(tasks: [ task("app", "dependent", depends_on: reference), task("app", "base", id: 7, stage: "7-artifacts") ])
      reached = project(tasks: [ task("app", "dependent", depends_on: reference), task("app", "base", id: 7, stage: "8-finalize") ])

      assert context(below).verdict(project: "app", slug: "dependent").wait?
      assert context(reached).verdict(project: "app", slug: "dependent").clear?
    end
  end

  def test_numeric_reference_never_searches_another_project
    app = project(tasks: [ task("app", "dependent", depends_on: "7") ])
    other = project(name: "other", tasks: [ task("other", "base", id: 7, stage: "9-done") ])

    assert_error context(app, other).verdict(project: "app", slug: "dependent"), "dependency_task_missing"
  end

  def test_task_snapshot_reuses_active_then_fallback_indexes
    archived = context(project(tasks: [ task("app", "archived", id: 7) ]))
    active = D::Context.new(
      projects: [ project(tasks: [ task("app", "active", id: 1) ]) ],
      fallback: archived
    )

    assert_equal "active", active.task_snapshot(project: "app", slug: "active").slug
    assert_equal "archived", active.task_snapshot(project: "app", id: 7).slug
    assert_nil active.task_snapshot(project: "app", slug: "missing")
  end

  def test_cross_project_reference_requires_exact_project_and_repository_identity
    app = project(tasks: [ task("app", "dependent", depends_on: "data:base") ])
    data = project(name: "data", stored: "github.com/acme/data", live: "github.com/acme/data",
                   tasks: [ task("data", "base", stage: "8-finalize") ])

    assert context(app, data).verdict(project: "app", slug: "dependent").clear?

    unknown = project(tasks: [ task("app", "dependent", depends_on: "missing:base") ])
    assert_error context(unknown).verdict(project: "app", slug: "dependent"), "dependency_project_unknown"

    missing_identity = project(name: "data", stored: nil, live: nil, tasks: [ task("data", "base") ])
    assert_error context(app, missing_identity).verdict(project: "app", slug: "dependent"),
                 "dependency_repository_identity_missing"

    mismatch = project(name: "data", stored: "github.com/acme/data", live: "github.com/acme/wrong",
                       tasks: [ task("data", "base") ])
    assert_error context(app, mismatch).verdict(project: "app", slug: "dependent"),
                 "dependency_repository_mismatch"
  end

  def test_missing_self_and_complete_cross_project_cycle_fail_closed
    missing = project(tasks: [ task("app", "a", depends_on: "ghost") ])
    assert_error context(missing).verdict(project: "app", slug: "a"), "dependency_task_missing"

    self_ref = project(tasks: [ task("app", "a", depends_on: "a") ])
    assert_error context(self_ref).verdict(project: "app", slug: "a"), "dependency_self_reference"

    app = project(tasks: [ task("app", "a", depends_on: "data:b") ])
    data = project(name: "data", tasks: [ task("data", "b", depends_on: "ops:c") ])
    ops = project(name: "ops", tasks: [ task("ops", "c", depends_on: "app:a") ])
    verdict = context(app, data, ops).verdict(project: "app", slug: "a")

    assert_error verdict, "dependency_cycle"
    assert_equal "app:a -> data:b -> ops:c -> app:a", verdict.admission_error.offending_ref
  end

  def test_corrupt_upstream_and_plan_drift_fail_closed
    root = task("app", "dependent", depends_on: "base")
    corrupt = task("app", "base", metadata_status: :unreadable, metadata_error: "bad yaml")
    assert_error context(project(tasks: [ root, corrupt ])).verdict(project: "app", slug: "dependent"),
                 "dependency_metadata_unreadable"

    plan_only = task("app", "plan-only", plan_status: :ok, plan_dependency: "base")
    assert_error context(project(tasks: [ plan_only ])).verdict(project: "app", slug: "plan-only"),
                 "plan_dependency_missing"

    mismatch = task("app", "drift", depends_on: "base", plan_status: :ok, plan_dependency: "other")
    assert_error context(project(tasks: [ mismatch ])).verdict(project: "app", slug: "drift"),
                 "plan_dependency_mismatch"

    invalid = task("app", "bad-plan", plan_status: :invalid, plan_error: "bad frontmatter")
    assert_error context(project(tasks: [ invalid ])).verdict(project: "app", slug: "bad-plan"),
                 "plan_dependency_invalid"
  end

  def test_gate_unknown_and_unreachable_are_errors
    root = task("app", "dependent", depends_on: "base")
    base = task("app", "base", workflow_stages: %w[1-inbox 2-work 9-done], stage: "2-work")

    unknown = project(gate: "7-artifacts", tasks: [ root, base ])
    assert_error context(unknown).verdict(project: "app", slug: "dependent"), "dependency_gate_unknown"

    unreachable = project(gate: "8-finalize", tasks: [ root, base ])
    assert_error context(unreachable).verdict(project: "app", slug: "dependent"), "dependency_gate_unreachable"

    invalid_stage = project(tasks: [
      root,
      task(
        "app", "base", stage: "3-plan",
        workflow_stages: %w[1-inbox 8-finalize 9-done]
      )
    ])
    verdict = context(invalid_stage).verdict(project: "app", slug: "dependent")
    assert_error verdict, "dependency_gate_unreachable"
    assert_match(/current-stage metadata/, verdict.admission_error.safe_correction)
  end

  def test_configured_done_gate_waits_through_finalize
    root = task("app", "dependent", depends_on: "base")
    finalize = project(gate: "9-done", tasks: [ root, task("app", "base", stage: "8-finalize") ])
    done = project(gate: "9-done", tasks: [ root, task("app", "base", stage: "9-done") ])

    assert context(finalize).verdict(project: "app", slug: "dependent").wait?
    assert context(done).verdict(project: "app", slug: "dependent").clear?
  end

  def test_list_dependencies_require_every_direct_edge_at_done_and_report_them_in_order
    root = task("app", "dependent", depends_on: %w[first second third])
    indexed = context(project(gate: "8-finalize", tasks: [
      root,
      task("app", "first", stage: "8-finalize"),
      task("app", "second", stage: "7-artifacts"),
      task("app", "third", stage: "9-done")
    ]))

    verdict = indexed.verdict(project: "app", slug: "dependent")

    assert verdict.wait?
    assert_nil verdict.blocked_by
    assert_nil verdict.dependency_stage
    assert_equal %w[first second], verdict.unmet_dependencies.map(&:blocked_by)
    assert_equal %w[9-done 9-done], verdict.unmet_dependencies.map(&:required_gate)
  end

  def test_later_invalid_sibling_outranks_an_earlier_wait
    indexed = context(project(tasks: [
      task("app", "dependent", depends_on: %w[waiting missing]),
      task("app", "waiting", stage: "7-artifacts")
    ]))

    verdict = indexed.verdict(project: "app", slug: "dependent")

    assert_error verdict, "dependency_task_missing"
    assert_equal [ "waiting" ], verdict.unmet_dependencies.map(&:blocked_by)
  end

  def test_cycle_reachable_through_second_list_edge_has_complete_path
    indexed = context(project(tasks: [
      task("app", "a", depends_on: %w[clear b]),
      task("app", "clear", stage: "9-done"),
      task("app", "b", depends_on: "a", stage: "9-done")
    ]))

    verdict = indexed.verdict(project: "app", slug: "a")

    assert_error verdict, "dependency_cycle"
    assert_equal "app:a -> app:b -> app:a", verdict.admission_error.offending_ref
  end

  def test_list_gate_unreachable_has_list_specific_remediation
    indexed = context(project(gate: "8-finalize", tasks: [
      task("app", "dependent", depends_on: [ "fix" ]),
      task("app", "fix", workflow_stages: %w[1-inbox 6-done], stage: "6-done")
    ]))

    verdict = indexed.verdict(project: "app", slug: "dependent")

    assert_error verdict, "dependency_gate_unreachable"
    assert_match(/lists require 9-done regardless of project configuration/i,
                 verdict.admission_error.safe_correction)
    refute_match(/dependency_gate_stage/, verdict.admission_error.safe_correction)
  end

  def test_shared_tail_is_not_a_cycle_and_strongest_gate_wins_deduplication
    indexed = context(project(gate: "8-finalize", tasks: [
      task("app", "root", depends_on: %w[left right]),
      task("app", "left", depends_on: "tail", stage: "9-done"),
      task("app", "right", depends_on: [ "tail" ], stage: "9-done"),
      task("app", "tail", stage: "7-artifacts")
    ]))

    verdict = indexed.verdict(project: "app", slug: "root")

    assert verdict.wait?
    assert_equal [ "tail" ], verdict.unmet_dependencies.map(&:blocked_by)
    assert_equal [ "9-done" ], verdict.unmet_dependencies.map(&:required_gate)
  end

  def test_nine_way_fan_in_reports_the_eight_remaining_prerequisites
    references = %w[c1 c2 c3 c4 c5 c6 c9 f5 hive-pin]
    prerequisites = references.map.with_index do |slug, index|
      task("app", slug, stage: index.zero? ? "9-done" : "8-finalize")
    end
    indexed = context(project(tasks: [
      task("app", "c7", depends_on: references), *prerequisites
    ]))

    verdict = indexed.verdict(project: "app", slug: "c7")

    assert verdict.wait?
    assert_equal references.drop(1), verdict.unmet_dependencies.map(&:blocked_by)
  end

  def test_cycle_results_are_recomputed_for_each_root_path
    indexed = context(project(tasks: [
      task("app", "a", depends_on: "b"),
      task("app", "b", depends_on: "a")
    ]))

    from_a = indexed.verdict(project: "app", slug: "a")
    from_b = indexed.verdict(project: "app", slug: "b")

    assert_equal "app:a -> app:b -> app:a", from_a.admission_error.offending_ref
    assert_equal "app:b -> app:a -> app:b", from_b.admission_error.offending_ref
  end

  def test_deep_dependency_chain_is_evaluated_without_ruby_recursion
    tasks = (0...1_500).map do |index|
      dependency = index == 1_499 ? nil : "node-#{index + 1}"
      task("app", "node-#{index}", depends_on: dependency, stage: "9-done")
    end

    assert context(project(tasks: tasks)).verdict(project: "app", slug: "node-0").clear?
  end

  def test_format_skew_and_malformed_array_references_have_distinct_remediation
    newer = task(
      "app", "newer", depends_on: %w[first second], metadata_status: :invalid_reference
    )
    malformed = task(
      "app", "malformed", depends_on: [ nil ], metadata_status: :invalid_reference
    )
    indexed = context(project(tasks: [ newer, malformed ]))

    upgrade = indexed.verdict(project: "app", slug: "newer").admission_error.safe_correction
    repair = indexed.verdict(project: "app", slug: "malformed").admission_error.safe_correction
    assert_match(/Upgrade Hive/, upgrade)
    assert_match(/preserve every listed prerequisite/, upgrade)
    assert_match(/Repair depends_on/, repair)
    refute_match(/Upgrade Hive/, repair)
  end

  def test_context_copies_nested_declarations_and_freezes_blocker_collections
    declaration = [ "base" ]
    indexed = context(project(tasks: [
      task("app", "dependent", depends_on: declaration),
      task("app", "base", stage: "8-finalize")
    ]))
    declaration << "late-mutation"

    verdict = indexed.verdict(project: "app", slug: "dependent")

    assert_equal [ "base" ], indexed.projects.first.tasks.first.depends_on
    assert_predicate indexed.projects.first.tasks.first.depends_on, :frozen?
    assert_predicate verdict, :frozen?
    assert_predicate verdict.unmet_dependencies, :frozen?
    assert_predicate verdict.unmet_dependencies.first, :frozen?
  end

  def test_indexed_fallback_preserves_archived_transitive_waits_and_workflows
    archived = project(tasks: [
      task("app", "archived", stage: "9-done", depends_on: "upstream"),
      task("app", "custom", stage: "9-done", workflow_stages: %w[1-inbox 9-done])
    ])
    fallback = D::Context.new(projects: [ archived ])
    active = project(tasks: [
      task("app", "dependent", depends_on: "archived"),
      task("app", "custom-dependent", depends_on: "custom"),
      task("app", "upstream", stage: "7-artifacts")
    ])
    combined = D::Context.new(projects: [ active ], fallback: fallback)

    wait = combined.verdict(project: "app", slug: "dependent")
    assert wait.wait?
    assert_nil wait.blocked_by
    assert_nil wait.dependency_stage
    assert_equal [ "upstream" ], wait.unmet_dependencies.map(&:blocked_by)
    assert_equal [ "7-artifacts" ], wait.unmet_dependencies.map(&:dependency_stage)
    assert_error combined.verdict(project: "app", slug: "custom-dependent"),
                 "dependency_gate_unreachable"
  end

  def test_active_task_shadows_same_slug_in_fallback_context
    fallback = D::Context.new(projects: [
      project(tasks: [ task("app", "base", stage: "7-artifacts") ])
    ])
    active = project(tasks: [
      task("app", "dependent", depends_on: "base"),
      task("app", "base", stage: "9-done")
    ])

    assert D::Context.new(projects: [ active ], fallback: fallback)
      .verdict(project: "app", slug: "dependent").clear?
  end

  def test_context_indexes_projects_by_canonical_path
    one = project
    duplicate = project.with(name: "duplicate")
    indexed = context(one)

    assert_equal one.name, indexed.project_for_path("/tmp/app").name
    assert_nil context(one, duplicate).project_for_path("/tmp/app")
    assert_nil indexed.project_for_path("/tmp/missing")
  end

  def test_nested_fallback_context_resolves_without_scanning_archives
    deep = context(project(tasks: [ task("app", "base", stage: "9-done") ]))
    middle = D::Context.new(projects: [ project(tasks: []) ], fallback: deep)
    active = D::Context.new(
      projects: [ project(tasks: [ task("app", "dependent", depends_on: "base") ]) ],
      fallback: middle
    )

    assert active.verdict(project: "app", slug: "dependent").clear?
  end

  def test_context_exposes_immutable_active_first_snapshot_layers
    archived = context(project(tasks: [ task("app", "archived") ]))
    active_project = project(tasks: [ task("app", "active") ])
    indexed = D::Context.new(projects: [ active_project ], fallback: archived)

    layer_slugs = indexed.project_snapshot_layers.map do |layer|
      layer.flat_map(&:tasks).map(&:slug)
    end
    assert_equal [ [ "active" ], [ "archived" ] ], layer_slugs
    assert_equal %w[active archived], indexed.project_snapshots.flat_map(&:tasks).map(&:slug)
    assert_predicate indexed.project_snapshot_layers, :frozen?
    assert_predicate indexed.project_snapshots, :frozen?
  end

  def test_immutable_context_memoizes_shared_dependency_tails
    indexed = context(project(tasks: [
      task("app", "a", depends_on: "b"),
      task("app", "b", depends_on: "c", stage: "9-done"),
      task("app", "c", stage: "9-done")
    ]))
    original_validate = indexed.method(:validate_node)
    validations = Hash.new(0)
    indexed.define_singleton_method(:validate_node) do |snapshot|
      validations[snapshot.slug] += 1
      original_validate.call(snapshot)
    end

    assert indexed.verdict(project: "app", slug: "a").clear?
    assert indexed.verdict(project: "app", slug: "b").clear?
    assert indexed.verdict(project: "app", slug: "c").clear?
    assert_equal({ "a" => 1, "b" => 1, "c" => 1 }, validations)
  end

  def test_invalid_metadata_and_reference_shapes_fail_closed
    invalid_reference = task(
      "app", "invalid-ref", depends_on: "bad:ref:shape", metadata_status: :invalid_reference
    )
    invalid_metadata = task("app", "invalid-meta", metadata_status: :invalid)
    late_invalid_reference = task("app", "late-invalid", depends_on: "bad:ref:shape")
    normalized_invalid = task(
      "app", "normalized-invalid", depends_on: "bad:ref:shape",
      plan_status: :ok, plan_dependency: "other"
    )

    assert_error context(project(tasks: [ invalid_reference ]))
      .verdict(project: "app", slug: "invalid-ref"), "dependency_reference_invalid"
    assert_error context(project(tasks: [ invalid_metadata ]))
      .verdict(project: "app", slug: "invalid-meta"), "dependency_metadata_invalid"
    assert_error context(project(tasks: [ late_invalid_reference ]))
      .verdict(project: "app", slug: "late-invalid"), "dependency_reference_invalid"
    assert_error context(project(tasks: [ normalized_invalid ]))
      .verdict(project: "app", slug: "normalized-invalid"), "plan_dependency_mismatch"
  end

  def test_duplicate_task_resolution_and_snapshot_errors_fail_closed
    dependent = task("app", "dependent", depends_on: "base")
    duplicate_a = task("app", "base", id: 7)
    duplicate_b = task("app", "base", id: 8)
    duplicate_source = project(tasks: [ task("app", "same"), task("app", "same") ])
    cached_error = D::AdmissionError.new(
      reason_code: "dependency_metadata_invalid",
      offending_ref: "app:cached",
      safe_correction: "Repair cached metadata."
    )
    cached = task("app", "cached", validation_error: cached_error)
    generic = task("app", "generic", validation_error: "snapshot changed")

    assert_error context(project(tasks: [ dependent, duplicate_a, duplicate_b ]))
      .verdict(project: "app", slug: "dependent"), "dependency_validation_failed"
    assert_error context(duplicate_source).verdict(project: "app", slug: "same"),
                 "dependency_validation_failed"
    assert_error context(project(tasks: [ cached ])).verdict(project: "app", slug: "cached"),
                 "dependency_metadata_invalid"
    assert_error context(project(tasks: [ generic ])).verdict(project: "app", slug: "generic"),
                 "dependency_validation_failed"
  end

  def test_unknown_source_and_unexpected_validator_failure_fail_closed
    indexed = context(project(tasks: [ task("app", "known") ]))
    assert_error indexed.verdict(project: "missing", slug: "known"), "dependency_project_unknown"
    assert_error indexed.verdict(project: "app", slug: "missing"), "dependency_task_missing"

    indexed.define_singleton_method(:walk) { |_source| raise "validator exploded" }
    verdict = indexed.verdict(project: "app", slug: "known")
    assert_error verdict, "dependency_validation_failed"
    assert_match(/RuntimeError/, verdict.admission_error.safe_correction)
  end

  private

  def context(*projects)
    D::Context.new(projects: projects.flatten)
  end

  def project(name: "app", stored: "github.com/acme/#{name}", live: "github.com/acme/#{name}",
              gate: "8-finalize", tasks: [])
    D::ProjectSnapshot.new(
      name: name,
      path: "/tmp/#{name}",
      repository_identity: stored,
      live_repository_identity: live,
      dependency_gate_stage: gate,
      tasks: tasks,
      validation_error: nil
    )
  end

  def task(project, slug, id: nil, depends_on: nil, stage: "4-execute",
           workflow_stages: Hive::Stages::DIRS, metadata_status: :ok, metadata_error: nil,
           plan_status: :absent, plan_dependency: nil, plan_error: nil, validation_error: nil)
    D::TaskSnapshot.new(
      cancelled: false,
      project: project,
      slug: slug,
      id: id,
      stage: stage,
      workflow_stages: workflow_stages,
      depends_on: depends_on,
      metadata_status: metadata_status,
      metadata_error: metadata_error,
      plan_status: plan_status,
      plan_dependency: plan_dependency,
      plan_error: plan_error,
      folder: "/tmp/#{project}/#{slug}",
      validation_error: validation_error
    )
  end

  def assert_error(verdict, code)
    assert verdict.error?, "expected admission error, got #{verdict.inspect}"
    assert_equal code, verdict.admission_error.reason_code
  end
end
