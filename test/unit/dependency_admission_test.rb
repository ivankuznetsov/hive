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

  # A prerequisite archived as superseded without delivery evidence did not
  # deliver: its dependents must move to the successor, like cancellation.
  def test_undelivered_supersession_does_not_satisfy_a_dependency
    superseded = task("app", "base", stage: "9-done").with(superseded_by: "app:rails-port")
    tasks = [ task("app", "dependent", depends_on: "base"), superseded, task("app", "rails-port") ]
    ctx = context(project(tasks: tasks))

    verdict = ctx.verdict(project: "app", slug: "dependent")
    assert_error verdict, "dependency_validation_failed"
    assert_includes verdict.admission_error.safe_correction,
                    "superseded by app:rails-port without delivery; depend on app:rails-port instead"
    assert ctx.verdict(project: "app", slug: "base").clear?
    assert_nil task("app", "plain").superseded_by
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
    assert_error context(project(tasks: [ plan_only, task("app", "base") ]))
      .verdict(project: "app", slug: "plan-only"), "plan_dependency_missing"

    mismatch = task("app", "drift", depends_on: "base", plan_status: :ok, plan_dependency: "other")
    assert_error context(project(tasks: [ mismatch, task("app", "base"), task("app", "other") ]))
      .verdict(project: "app", slug: "drift"), "plan_dependency_mismatch"

    shape_mismatch = task(
      "app", "shape-drift", depends_on: "base", plan_status: :ok,
      plan_dependency: [ "base" ]
    )
    assert_error context(project(tasks: [ shape_mismatch, task("app", "base") ]))
      .verdict(project: "app", slug: "shape-drift"), "plan_dependency_mismatch"

    reverse_shape_mismatch = task(
      "app", "reverse-shape-drift", depends_on: [ "base" ], plan_status: :ok,
      plan_dependency: "base"
    )
    assert_error context(project(tasks: [ reverse_shape_mismatch, task("app", "base") ]))
      .verdict(project: "app", slug: "reverse-shape-drift"), "plan_dependency_mismatch"

    matching_list = task(
      "app", "matching-list", depends_on: %w[first second], plan_status: :ok,
      plan_dependency: %w[first second]
    )
    matching_context = context(project(tasks: [
      matching_list,
      task("app", "first", stage: "9-done"),
      task("app", "second", stage: "9-done")
    ]))
    assert matching_context.verdict(project: "app", slug: "matching-list").clear?

    # Admission itself stays exact: a plan superset is only healed by plan
    # stage adoption, and a plan that omits a meta edge is never healed.
    superset = task(
      "app", "superset", depends_on: "base", plan_status: :ok,
      plan_dependency: %w[base other]
    )
    assert_error context(project(tasks: [ superset, task("app", "base"), task("app", "other") ]))
      .verdict(project: "app", slug: "superset"), "plan_dependency_mismatch"

    omission = task(
      "app", "omission", depends_on: %w[base other], plan_status: :ok,
      plan_dependency: %w[base]
    )
    assert_error context(project(tasks: [ omission, task("app", "base"), task("app", "other") ]))
      .verdict(project: "app", slug: "omission"), "plan_dependency_mismatch"

    reordered_list = task(
      "app", "reordered-list", depends_on: %w[first second], plan_status: :ok,
      plan_dependency: %w[second first]
    )
    assert_error context(project(tasks: [ reordered_list, task("app", "first"), task("app", "second") ]))
      .verdict(project: "app", slug: "reordered-list"), "plan_dependency_mismatch"

    invalid = task("app", "bad-plan", plan_status: :invalid, plan_error: "bad frontmatter")
    assert_error context(project(tasks: [ invalid ])).verdict(project: "app", slug: "bad-plan"),
                 "plan_dependency_invalid"
  end

  def test_unresolved_plan_assertion_reports_plan_dependency_invalid_before_missing_or_mismatch
    plan_only_unknown = task("app", "plan-only", plan_status: :ok, plan_dependency: "ghost-task")
    mismatch_unknown = task(
      "app", "mismatch", depends_on: "base", plan_status: :ok, plan_dependency: %w[base ghost-task]
    )
    matching_unknown = task(
      "app", "both-missing", depends_on: "ghost-task", plan_status: :ok, plan_dependency: "ghost-task"
    )
    metadata_only_unknown = task("app", "meta-only", depends_on: "ghost-task")
    ctx = context(project(tasks: [
      task("app", "base"), plan_only_unknown, mismatch_unknown, matching_unknown, metadata_only_unknown
    ]))

    assert_error ctx.verdict(project: "app", slug: "plan-only"), "plan_dependency_invalid"
    assert_error ctx.verdict(project: "app", slug: "mismatch"), "plan_dependency_invalid"
    assert_error ctx.verdict(project: "app", slug: "both-missing"), "plan_dependency_invalid"
    assert_error ctx.verdict(project: "app", slug: "meta-only"), "dependency_task_missing"
  end

  def test_project_hint_lookup_handles_agreement_ambiguity_duplicates_and_incomplete_coverage
    agreeing = D::ProjectHintLookup.new(
      project: "app",
      complete: true,
      tasks: [
        D::HintTask.new(project: "app", slug: "f2-workspace-260923-d691", idempotency_key: "app:f2:v1"),
        D::HintTask.new(project: "app", slug: "f20-other-task", idempotency_key: "free-form")
      ]
    )
    assert_equal "f2-workspace-260923-d691", agreeing.suggest("F2")
    assert_equal "f2-workspace-260923-d691", agreeing.suggest("f2")
    assert_nil agreeing.suggest("F2", exclude_slug: "f2-workspace-260923-d691")

    ambiguous = D::ProjectHintLookup.new(
      project: "app",
      complete: true,
      tasks: [
        D::HintTask.new(project: "app", slug: "f2-active-task", idempotency_key: nil),
        D::HintTask.new(project: "app", slug: "archived-renamed-task", idempotency_key: "app:F2:v1")
      ]
    )
    assert_nil ambiguous.suggest("F2")

    duplicated = D::ProjectHintLookup.new(
      project: "app",
      complete: true,
      tasks: [ D::HintTask.new(project: "app", slug: "f2-workspace-260923-d691", idempotency_key: nil) ],
      duplicate_identities: [ [ "app", "f2-workspace-260923-d691" ] ]
    )
    assert_nil duplicated.suggest("F2")

    incomplete = D::ProjectHintLookup.new(
      project: "app",
      complete: false,
      tasks: [ D::HintTask.new(project: "app", slug: "f2-workspace-260923-d691", idempotency_key: nil) ]
    )
    assert_nil incomplete.suggest("F2")

    isolated = D::ProjectHintLookup.new(
      project: "app",
      complete: true,
      tasks: [
        D::HintTask.new(project: "other", slug: "f2-foreign-task", idempotency_key: "other:f2:v1"),
        D::HintTask.new(project: "app", slug: "unrelated", idempotency_key: "other:f2:v1")
      ]
    )
    assert_nil isolated.suggest("F2")
    assert_nil isolated.suggest("other:F2")
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

  def test_cycle_behind_an_earlier_missing_sibling_is_still_reported
    indexed = context(project(tasks: [
      task("app", "a", depends_on: %w[ghost b]),
      task("app", "b", depends_on: "a", stage: "9-done")
    ]))

    verdict = indexed.verdict(project: "app", slug: "a")

    assert_error verdict, "dependency_cycle"
    assert_equal "app:a -> app:b -> app:a", verdict.admission_error.offending_ref
  end

  def test_cycle_behind_an_unreachable_list_gate_is_still_reported
    indexed = context(project(tasks: [
      task("app", "a", depends_on: [ "b" ]),
      task(
        "app", "b", depends_on: "a", stage: "6-done",
        workflow_stages: %w[1-inbox 6-done]
      )
    ]))

    verdict = indexed.verdict(project: "app", slug: "a")

    assert_error verdict, "dependency_cycle"
    assert_equal "app:a -> app:b -> app:a", verdict.admission_error.offending_ref
  end

  def test_upstream_self_reference_reports_its_qualified_cycle_path
    indexed = context(project(tasks: [
      task("app", "a", depends_on: "b"),
      task("app", "b", depends_on: "b")
    ]))

    verdict = indexed.verdict(project: "app", slug: "a")

    assert_error verdict, "dependency_self_reference"
    assert_equal "app:b -> app:b", verdict.admission_error.offending_ref
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
    assert_match(/app:dependent/, verdict.admission_error.safe_correction)
    assert_match(%r{/tmp/app/dependent/meta\.yml}, verdict.admission_error.safe_correction)
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

  def test_shared_tail_keeps_strongest_gate_in_both_orders_and_after_finalize
    [ %w[scalar list], %w[list scalar] ].each do |root_order|
      %w[7-artifacts 8-finalize].each do |tail_stage|
        indexed = context(project(gate: "8-finalize", tasks: [
          task("app", "root", depends_on: root_order),
          task("app", "scalar", depends_on: "tail", stage: "9-done"),
          task("app", "list", depends_on: [ "tail" ], stage: "9-done"),
          task("app", "tail", stage: tail_stage)
        ]))

        verdict = indexed.verdict(project: "app", slug: "root")

        assert_equal [ "tail" ], verdict.unmet_dependencies.map(&:blocked_by)
        assert_equal [ "9-done" ], verdict.unmet_dependencies.map(&:required_gate)
      end
    end
  end

  def test_direct_blockers_precede_transitive_blockers
    indexed = context(project(tasks: [
      task("app", "root", depends_on: %w[parent direct]),
      task("app", "parent", depends_on: "tail", stage: "9-done"),
      task("app", "direct", stage: "7-artifacts"),
      task("app", "tail", stage: "3-plan")
    ]))

    verdict = indexed.verdict(project: "app", slug: "root")

    assert_equal %w[direct tail], verdict.unmet_dependencies.map(&:blocked_by)
  end

  def test_remote_transitive_blockers_are_qualified_for_the_requesting_project
    app = project(tasks: [ task("app", "root", depends_on: %w[one:done two:done]) ])
    one = project(name: "one", tasks: [
      task("one", "done", depends_on: "tail", stage: "9-done"),
      task("one", "tail", stage: "3-plan")
    ])
    two = project(name: "two", tasks: [
      task("two", "done", depends_on: "tail", stage: "9-done"),
      task("two", "tail", stage: "3-plan")
    ])

    unmet = context(app, one, two).verdict(project: "app", slug: "root").unmet_dependencies

    assert_equal %w[one:tail two:tail], unmet.map(&:reference)
    assert_equal %w[one:tail two:tail], unmet.map(&:blocked_by)
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

  def test_cycle_abort_does_not_poison_shared_acyclic_nodes_in_either_root_order
    tasks = [
      task("app", "cyclic-root", depends_on: %w[shared loop]),
      task("app", "loop", depends_on: "cyclic-root", stage: "9-done"),
      task("app", "acyclic-root", depends_on: "shared"),
      task("app", "shared", stage: "9-done")
    ]

    [ %w[cyclic-root acyclic-root], %w[acyclic-root cyclic-root] ].each do |order|
      indexed = context(project(tasks: tasks))
      verdicts = order.to_h do |slug|
        [ slug, indexed.verdict(project: "app", slug: slug) ]
      end

      assert_error verdicts.fetch("cyclic-root"), "dependency_cycle"
      assert verdicts.fetch("acyclic-root").clear?
      loop_verdict = indexed.verdict(project: "app", slug: "loop")
      assert_error loop_verdict, "dependency_cycle"
      assert_equal "app:loop -> app:cyclic-root -> app:loop",
                   loop_verdict.admission_error.offending_ref
    end
  end

  def test_cycle_derived_walk_cache_is_reused_only_while_its_anchor_is_active
    alpha = project(name: "alpha", tasks: [
      task("alpha", "a3", depends_on: "beta:b3", stage: "9-done")
    ])
    beta = project(name: "beta", tasks: [
      task("beta", "b1", depends_on: [ "alpha:a3", "b6" ]),
      task("beta", "b3", depends_on: "b6", stage: "9-done"),
      task("beta", "b5", stage: "7-artifacts"),
      task("beta", "b6", depends_on: [ "b5", "b3" ], stage: "9-done")
    ])

    verdict = context(alpha, beta).verdict(project: "beta", slug: "b1")

    assert_error verdict, "dependency_cycle"
    assert_equal "beta:b6 -> beta:b3 -> beta:b6", verdict.admission_error.offending_ref
    assert_equal [ "beta:b5" ], verdict.unmet_dependencies.map(&:blocked_by)
  end

  def test_cycle_derived_walk_cache_reuses_an_evaluation_while_its_anchor_is_active
    indexed = context(project(tasks: [
      task("app", "a", depends_on: %w[b c]),
      task("app", "b", depends_on: "c", stage: "9-done"),
      task("app", "c", depends_on: "a", stage: "9-done")
    ]))

    verdict = indexed.verdict(project: "app", slug: "a")

    assert_error verdict, "dependency_cycle"
    assert_equal "app:a -> app:b -> app:c -> app:a", verdict.admission_error.offending_ref
  end

  def test_acyclic_fan_in_is_memoized_within_one_root_walk
    tasks = [ task("app", "leaf", stage: "9-done") ]
    previous = [ "leaf" ]
    12.times do |depth|
      current = [ "left-#{depth}", "right-#{depth}" ]
      current.each do |slug|
        tasks << task("app", slug, depends_on: previous, stage: "9-done")
      end
      previous = current
    end
    tasks << task("app", "root", depends_on: previous)
    indexed = context(project(tasks: tasks))
    validations = 0
    original_validate = indexed.method(:validate_node)
    indexed.define_singleton_method(:validate_node) do |snapshot|
      validations += 1
      original_validate.call(snapshot)
    end

    assert indexed.verdict(project: "app", slug: "root").clear?
    assert_operator validations, :<=, tasks.length,
                    "each node should be expanded at most once within the root query"
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
    malformed_error = indexed.verdict(project: "app", slug: "malformed").admission_error
    repair = malformed_error.safe_correction
    assert_match(/Upgrade Hive/, upgrade)
    assert_match(/preserve every listed prerequisite/, upgrade)
    assert_match(/Repair depends_on/, repair)
    refute_match(/Upgrade Hive/, repair)
    assert_equal "[null]", malformed_error.offending_ref
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
    assert_error context(project(tasks: [ normalized_invalid, task("app", "other") ]))
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

  def test_root_attribution_for_c5_root_c6_direct_and_c7_transitive_descendants
    c5_issues = Hive::Dependencies.inspect_declaration(%w[F2 F3]).issues
    c5 = task(
      "app", "c5-root", stage: "3-plan",
      plan_status: :invalid, plan_raw_depends_on: %w[F2 F3], plan_issues: c5_issues
    )
    c6 = task("app", "c6-direct", stage: "2-brainstorm", depends_on: "c5-root")
    c7 = task("app", "c7-transitive", stage: "1-inbox", depends_on: "c6-direct")
    ctx = context(project(tasks: [ c5, c6, c7 ]))

    v5 = ctx.verdict(project: "app", slug: "c5-root")
    assert_error v5, "plan_dependency_invalid"
    assert_empty v5.dependency_repair_roots
    assert_equal "F2, F3", v5.admission_error.offending_ref

    v6 = ctx.verdict(project: "app", slug: "c6-direct")
    assert v6.wait?
    assert v6.blocked?
    assert_nil v6.admission_error
    assert_equal "c5-root", v6.blocked_by
    assert_equal "3-plan", v6.dependency_stage
    assert_equal [ "app:c5-root" ], v6.dependency_repair_roots.map(&:qualified_identity)
    assert_equal "F2, F3", v6.dependency_repair_roots.first.offending_ref
    assert_equal [ 0, 1 ], v6.dependency_repair_roots.first.issues.map(&:index)

    v7 = ctx.verdict(project: "app", slug: "c7-transitive")
    assert v7.wait?
    assert_nil v7.admission_error
    assert_equal "c6-direct", v7.blocked_by
    assert_equal "2-brainstorm", v7.dependency_stage
    assert_equal [ "app:c5-root" ], v7.dependency_repair_roots.map(&:qualified_identity)
  end

  def test_identical_missing_slug_in_plan_versus_metadata_only
    plan_root = task(
      "app", "plan-root", stage: "3-plan",
      depends_on: "ghost-slug", plan_status: :ok, plan_dependency: "ghost-slug"
    )
    plan_child = task("app", "plan-child", stage: "2-brainstorm", depends_on: "plan-root")

    meta_root = task("app", "meta-root", stage: "3-plan", depends_on: "ghost-slug")
    meta_child = task("app", "meta-child", stage: "2-brainstorm", depends_on: "meta-root")

    ctx = context(project(tasks: [ plan_root, plan_child, meta_root, meta_child ]))

    assert_error ctx.verdict(project: "app", slug: "plan-root"), "plan_dependency_invalid"
    child_verdict = ctx.verdict(project: "app", slug: "plan-child")
    assert child_verdict.wait?
    assert_nil child_verdict.admission_error
    assert_equal [ "app:plan-root" ], child_verdict.dependency_repair_roots.map(&:qualified_identity)

    assert_error ctx.verdict(project: "app", slug: "meta-root"), "dependency_task_missing"
    meta_child_verdict = ctx.verdict(project: "app", slug: "meta-child")
    assert_error meta_child_verdict, "dependency_task_missing"
    assert_empty meta_child_verdict.dependency_repair_roots
  end

  def test_diamond_and_fan_in_collect_roots_in_declaration_order_deduplicated_and_cached
    root1 = task(
      "app", "root-one", stage: "3-plan",
      plan_status: :invalid, plan_raw_depends_on: "F2",
      plan_issues: Hive::Dependencies.inspect_declaration("F2").issues
    )
    root2 = task(
      "app", "root-two", stage: "3-plan",
      plan_status: :invalid, plan_raw_depends_on: "C4",
      plan_issues: Hive::Dependencies.inspect_declaration("C4").issues
    )
    left = task("app", "left", stage: "4-execute", depends_on: %w[root-one root-two])
    right = task("app", "right", stage: "4-execute", depends_on: %w[root-two root-one])
    diamond = task("app", "diamond", stage: "2-brainstorm", depends_on: %w[left right])
    sibling_consumer = task("app", "shared-consumer", stage: "2-brainstorm", depends_on: "right")
    ctx = context(project(tasks: [ root1, root2, left, right, diamond, sibling_consumer ]))

    v_diamond = ctx.verdict(project: "app", slug: "diamond")
    assert v_diamond.wait?
    assert_nil v_diamond.blocked_by
    assert_nil v_diamond.dependency_stage
    assert_equal %w[app:root-one app:root-two], v_diamond.dependency_repair_roots.map(&:qualified_identity)

    # Reusing cached shared roots preserves exact traversal order for another consumer.
    v_shared = ctx.verdict(project: "app", slug: "shared-consumer")
    assert v_shared.wait?
    assert_equal %w[app:root-two app:root-one], v_shared.dependency_repair_roots.map(&:qualified_identity)
  end

  def test_waiting_list_sibling_preserves_unmet_edges_alongside_multi_hop_repair_root
    waiting_sibling = task("app", "waiting-sibling", stage: "4-execute")
    root = task(
      "app", "c5-root", stage: "3-plan",
      plan_status: :invalid, plan_raw_depends_on: %w[F2 F3],
      plan_issues: Hive::Dependencies.inspect_declaration(%w[F2 F3]).issues
    )
    mid = task("app", "c6-mid", stage: "4-execute", depends_on: "c5-root")
    leaf = task("app", "leaf", stage: "2-brainstorm", depends_on: %w[waiting-sibling c6-mid])
    ctx = context(project(tasks: [ waiting_sibling, root, mid, leaf ]))

    verdict = ctx.verdict(project: "app", slug: "leaf")
    assert verdict.wait?
    assert_nil verdict.blocked_by
    assert_nil verdict.dependency_stage
    assert_equal %w[waiting-sibling c6-mid], verdict.unmet_dependencies.map(&:blocked_by)
    assert_equal [ "app:c5-root" ], verdict.dependency_repair_roots.map(&:qualified_identity)
  end

  def test_repair_root_alone_causes_wait_even_when_unmet_dependencies_are_empty
    done_root = task(
      "app", "done-root", stage: "9-done",
      plan_status: :invalid, plan_raw_depends_on: "F2",
      plan_issues: Hive::Dependencies.inspect_declaration("F2").issues
    )
    child = task("app", "child", stage: "3-plan", depends_on: "done-root")
    ctx = context(project(tasks: [ done_root, child ]))

    verdict = ctx.verdict(project: "app", slug: "child")
    assert verdict.wait?
    assert verdict.blocked?
    assert_nil verdict.admission_error
    assert_empty verdict.unmet_dependencies
    assert_equal [ "app:done-root" ], verdict.dependency_repair_roots.map(&:qualified_identity)
  end

  def test_independently_broken_descendant_keeps_own_error_and_displays_inherited_roots
    root = task(
      "app", "c5-root", stage: "3-plan",
      plan_status: :invalid, plan_raw_depends_on: "F2",
      plan_issues: Hive::Dependencies.inspect_declaration("F2").issues
    )
    broken_child = task(
      "app", "c6-broken", stage: "3-plan",
      depends_on: "c5-root",
      plan_status: :invalid, plan_raw_depends_on: "F9",
      plan_issues: Hive::Dependencies.inspect_declaration("F9").issues
    )
    grandchild = task("app", "c7-grandchild", stage: "2-brainstorm", depends_on: "c6-broken")
    ctx = context(project(tasks: [ root, broken_child, grandchild ]))

    v_child = ctx.verdict(project: "app", slug: "c6-broken")
    assert_error v_child, "plan_dependency_invalid"
    assert_equal "F9", v_child.admission_error.offending_ref
    assert_equal [ "app:c5-root" ], v_child.dependency_repair_roots.map(&:qualified_identity)

    v_grandchild = ctx.verdict(project: "app", slug: "c7-grandchild")
    assert v_grandchild.wait?
    assert_nil v_grandchild.admission_error
    assert_equal %w[app:c6-broken app:c5-root], v_grandchild.dependency_repair_roots.map(&:qualified_identity)
  end

  def test_root_recovery_removes_repair_evidence_while_retaining_gate_waits
    prereq = task("app", "f2-real-task", stage: "4-execute")
    repaired_root = task(
      "app", "c5-root", stage: "3-plan",
      depends_on: "f2-real-task", plan_status: :ok, plan_dependency: "f2-real-task"
    )
    child = task("app", "c6-child", stage: "2-brainstorm", depends_on: "c5-root")
    ctx = context(project(tasks: [ prereq, repaired_root, child ]))

    v_root = ctx.verdict(project: "app", slug: "c5-root")
    assert v_root.wait?
    assert_empty v_root.dependency_repair_roots
    assert_equal "f2-real-task", v_root.blocked_by

    v_child = ctx.verdict(project: "app", slug: "c6-child")
    assert v_child.wait?
    assert_empty v_child.dependency_repair_roots
    assert_equal "c5-root", v_child.blocked_by
    assert_equal "3-plan", v_child.dependency_stage

    done_ctx = context(project(tasks: [
      task("app", "f2-real-task", stage: "9-done"),
      task("app", "c5-root", stage: "9-done", depends_on: "f2-real-task",
           plan_status: :ok, plan_dependency: "f2-real-task"),
      task("app", "c6-child", stage: "2-brainstorm", depends_on: "c5-root")
    ]))
    assert done_ctx.verdict(project: "app", slug: "c6-child").clear?
  end

  def test_noncovered_errors_and_malformed_metadata_remain_unchanged
    corrupt_root = task(
      "app", "corrupt", stage: "3-plan",
      depends_on: "other", metadata_status: :invalid, metadata_error: "bad yaml"
    )
    corrupt_child = task("app", "corrupt-child", stage: "2-brainstorm", depends_on: "corrupt")
    other = task(
      "app", "other", stage: "3-plan",
      plan_status: :invalid, plan_raw_depends_on: "F2",
      plan_issues: Hive::Dependencies.inspect_declaration("F2").issues
    )
    ctx = context(project(tasks: [ corrupt_root, corrupt_child, other ]))

    v_corrupt = ctx.verdict(project: "app", slug: "corrupt")
    assert_error v_corrupt, "dependency_metadata_invalid"
    assert_empty v_corrupt.dependency_repair_roots, "must not infer edges from malformed metadata"

    v_child = ctx.verdict(project: "app", slug: "corrupt-child")
    assert_error v_child, "dependency_metadata_invalid"
    assert_empty v_child.dependency_repair_roots
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
           plan_status: :absent, plan_dependency: nil, plan_error: nil, validation_error: nil,
           plan_raw_depends_on: nil, plan_issues: [])
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
      plan_raw_depends_on: plan_raw_depends_on,
      plan_issues: plan_issues,
      folder: "/tmp/#{project}/#{slug}",
      validation_error: validation_error
    )
  end

  def assert_error(verdict, code)
    assert verdict.error?, "expected admission error, got #{verdict.inspect}"
    assert_equal code, verdict.admission_error.reason_code
  end
end
