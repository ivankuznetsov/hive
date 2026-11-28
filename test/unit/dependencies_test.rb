require "test_helper"
require "hive/dependencies"

class DependenciesTest < Minitest::Test
  def test_parse_reference_accepts_same_project_slug_and_numeric_id
    slug = Hive::Dependencies.parse_reference("base-task")
    numeric = Hive::Dependencies.parse_reference(42)

    assert_equal [ nil, "base-task", false ], [ slug.project, slug.task, slug.explicit_project ]
    assert_equal [ nil, "42", false ], [ numeric.project, numeric.task, numeric.explicit_project ]
  end

  def test_parse_reference_accepts_explicit_cross_project_slug
    reference = Hive::Dependencies.parse_reference("analytics:base-task")

    assert_equal "analytics", reference.project
    assert_equal "base-task", reference.task
    assert reference.explicit_project
    assert_equal "analytics:base-task", reference.to_s
  end

  def test_parse_reference_rejects_invalid_shapes
    invalid = [ nil, "", " ", [], {}, true, "a:b:c", ":task", "project:",
                "project:42", "UPPER", "project:UPPER", "two tasks" ]

    invalid.each do |value|
      assert_raises(Hive::Dependencies::InvalidReference, "expected #{value.inspect} to be rejected") do
        Hive::Dependencies.parse_reference(value)
      end
    end
  end

  def test_parse_declaration_preserves_scalar_and_array_shape
    scalar = Hive::Dependencies.parse_declaration("base-task")
    singleton = Hive::Dependencies.parse_declaration([ "base-task" ])
    multiple = Hive::Dependencies.parse_declaration([ "base-task", 42, "api:other-task" ])

    assert_instance_of Hive::Dependencies::Reference, scalar
    assert_equal "base-task", scalar.to_s
    assert_equal [ "base-task" ], singleton.map(&:to_s)
    assert_equal [ "base-task", "42", "api:other-task" ], multiple.map(&:to_s)
  end

  def test_normalize_declaration_deduplicates_without_collapsing_array_shape
    assert_equal "42", Hive::Dependencies.normalize_declaration(42)
    assert_equal [ "base-task" ],
                 Hive::Dependencies.normalize_declaration([ "base-task", "base-task" ])
  end

  def test_display_declaration_uses_json_for_composites_and_safe_scalar_fallbacks
    assert_equal '["a",{"k":"v"}]',
                 Hive::Dependencies.display_declaration([ "a", { "k" => "v" } ])
    assert_equal "NaN", Hive::Dependencies.display_declaration(Float::NAN)
  end

  def test_parse_declaration_rejects_invalid_elements_with_their_indexes
    invalid = [ [], [ "base-task", nil ], [ [ "base-task" ] ], [ {} ], { "task" => "base-task" } ]

    invalid.each do |value|
      error = assert_raises(Hive::Dependencies::InvalidReference) do
        Hive::Dependencies.parse_declaration(value)
      end
      assert_match(/depends_on/, error.message)
    end

    error = assert_raises(Hive::Dependencies::InvalidReference) do
      Hive::Dependencies.parse_declaration([ "base-task", "BAD TASK" ])
    end
    assert_match(/element 2/, error.message)
  end

  Task = Struct.new(:slug, :id, :stage_index, :stage, keyword_init: true)

  def test_base_branch_for_resolvable_dependency_returns_prerequisite_slug
    branch = Hive::Dependencies.base_branch_for(
      depends_on: "base-task",
      tasks: [ task("base-task", stage_index: 8) ],
      default_branch: "main"
    )

    assert_equal "base-task", branch
  end

  def test_base_branch_for_lists_always_returns_the_default_branch
    tasks = [ task("base-task", stage_index: 9), task("other-task", stage_index: 9) ]

    assert_equal "main", Hive::Dependencies.base_branch_for(
      depends_on: [ "base-task" ], tasks: tasks, default_branch: "main"
    )
    assert_equal "main", Hive::Dependencies.base_branch_for(
      depends_on: %w[base-task other-task], tasks: tasks, default_branch: "main"
    )
  end

  # Stacking is threshold-blind by design: base_branch_for returns the
  # prerequisite slug regardless of how far the prereq has progressed, so a
  # dependent worktree branches off the prereq even while the gate still
  # blocks dispatch. Pin both a below-threshold and an at/after-threshold
  # prereq to lock that contract independent of admission's gate.
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

  # `blocked_label` is the single source of truth for the "⏸ blocked by …"
  # indicator both renderers share. Pin both branches directly so a
  # regression localises to the helper instead of surfacing only through
  # the two end-to-end renderer tests.
  def test_blocked_label_renders_resolved_and_unresolved_branches
    resolved = Hive::Dependencies.blocked_label(
      depends_on: "base-task", blocked_by: "base-task", dependency_stage: "7-artifacts"
    )
    unresolved = Hive::Dependencies.blocked_label(
      depends_on: "typo-task", blocked_by: nil, dependency_stage: nil
    )

    assert_equal "⏸ blocked by base-task (7-artifacts)", resolved
    assert_equal "⏸ blocked by typo-task (unresolved)", unresolved
  end

  def test_blocked_label_renders_every_unmet_dependency_without_array_inspection
    unmet = [
      { "reference" => "first", "blocked_by" => "first", "dependency_stage" => "7-artifacts" },
      { "reference" => "other:second", "blocked_by" => "other:second",
        "dependency_stage" => "8-finalize" },
      { "reference" => "missing", "blocked_by" => nil, "dependency_stage" => nil }
    ]

    label = Hive::Dependencies.blocked_label(
      depends_on: %w[first other:second], blocked_by: nil, dependency_stage: nil,
      unmet_dependencies: unmet
    )

    assert_equal "⏸ blocked by first (7-artifacts), other:second (8-finalize), " \
                 "missing (unresolved)", label
    refute_includes label, "[\""
  end

  def test_blocked_label_names_stronger_gate_and_has_a_generic_fallback
    label = Hive::Dependencies.blocked_label(
      depends_on: [ "base" ], blocked_by: nil, dependency_stage: nil,
      unmet_dependencies: [ {
        "reference" => "base", "blocked_by" => "base",
        "dependency_stage" => "8-finalize", "required_gate" => "9-done"
      } ]
    )

    assert_equal "⏸ blocked by base (8-finalize, needs 9-done)", label
    assert_equal "⏸ blocked by a task dependency", Hive::Dependencies.blocked_label(
      depends_on: [], blocked_by: nil, dependency_stage: nil
    )
    assert_equal "blocked by a task dependency", Hive::Dependencies.blocker_summary(
      depends_on: [], blocked_by: nil, dependency_stage: nil
    )
  end

  def test_blocker_names_preserves_order_deduplicates_and_uses_references
    names = Hive::Dependencies.blocker_names(
      unmet_dependencies: [
        { "reference" => "one", "blocked_by" => "one" },
        { "reference" => "remote:two", "blocked_by" => "" },
        { "reference" => "one", "blocked_by" => "one" }
      ],
      blocked_by: "fallback"
    )

    assert_equal [ "one", "remote:two" ], names
  end

  def test_same_task_matches_numeric_id_when_slugs_differ
    current = task(nil, id: 42, stage_index: 4)
    snapshot_entry = task("base-task", id: 42, stage_index: 4)

    assert Hive::Dependencies.same_task?(snapshot_entry, current)
  end

  def test_same_task_accepts_numeric_string_ids_and_warns_for_corrupt_raw_ids
    assert Hive::Dependencies.same_task?(
      { "id" => "42" }, { id: 42 }
    )

    _out, err = capture_io do
      refute Hive::Dependencies.same_task?(
        { "id" => "not-an-id" }, { id: 42 }
      )
    end
    assert_includes err, "is not an integer"
  end

  def test_same_task_warns_for_an_unrecognized_task_shape
    _out, err = capture_io do
      refute Hive::Dependencies.same_task?(Object.new, { slug: "task" })
    end

    assert_includes err, "unrecognized task shape"
  end

  def test_inspect_declaration_preserves_all_bad_elements_and_valid_siblings_with_indexes
    inspection = Hive::Dependencies.inspect_declaration([ "C4", "valid-task", "F2", "F3", [ "nested" ] ])

    refute inspection.valid?
    assert inspection.list?
    assert_nil inspection.parsed
    assert_equal [ [ 1, "valid-task" ] ],
                 inspection.entries.map { |entry| [ entry.index, entry.reference.to_s ] }
    assert_equal [ 0, 2, 3, 4 ], inspection.issues.map(&:index)
    assert_equal [ "C4", "F2", "F3", [ "nested" ] ], inspection.issues.map(&:raw_value)
    assert_equal %i[task_code_shorthand task_code_shorthand task_code_shorthand nested_element],
                 inspection.issues.map(&:code)
    assert_equal 'invalid depends_on C4, F2, F3, ["nested"]',
                 Hive::Dependencies.format_invalid_depends_on(inspection.issues)
    assert_equal "invalid depends_on F2, F3",
                 Hive::Dependencies.format_invalid_depends_on(inspection.issues[1..2])

    serialized = JSON.parse(JSON.generate(inspection.issues.map(&:to_h)))
    assert_equal 4, serialized.length
    assert_equal({
      "index" => 2, "raw_value" => "F2", "display_value" => "F2",
      "code" => "task_code_shorthand",
      "message" => "depends_on element 3 is invalid: depends_on must be a task slug, numeric id, or project:slug",
      "suggestion" => nil
    }, serialized[1])
  end

  def test_inspect_declaration_handles_empty_mapping_and_non_finite_floats_safely
    empty = Hive::Dependencies.inspect_declaration([])
    mapping = Hive::Dependencies.inspect_declaration({ "task" => "a" })
    nan_list = Hive::Dependencies.inspect_declaration([ "base-task", Float::NAN ])

    assert_equal [ :empty_list ], empty.issues.map(&:code)
    assert_equal "[]", empty.issues.first.display_value
    assert_equal [ :invalid_shape ], mapping.issues.map(&:code)
    assert_equal '{"task":"a"}', mapping.issues.first.display_value
    assert_equal [ 1 ], nan_list.issues.map(&:index)
    assert_equal "NaN", nan_list.issues.first.raw_value
    assert_match(/\A\[/, JSON.generate(nan_list.issues.map(&:to_h)))
  end

  def test_hint_matching_rules_enforce_strict_idempotency_key_and_slug_prefix_boundaries
    assert Hive::Dependencies.slug_prefix_matches?("f2-build-workspace-260923-d691", code: "F2")
    assert Hive::Dependencies.slug_prefix_matches?("c4", code: "C4")
    refute Hive::Dependencies.slug_prefix_matches?("f20-other-task", code: "F2")

    assert Hive::Dependencies.idempotency_key_matches?("app:f2:v1", project: "app", code: "F2")
    assert Hive::Dependencies.idempotency_key_matches?("app:F2:2026-10-30", project: "app", code: "f2")
    refute Hive::Dependencies.idempotency_key_matches?("other:f2:v1", project: "app", code: "F2")
    refute Hive::Dependencies.idempotency_key_matches?("APP:f2:v1", project: "app", code: "F2")
    refute Hive::Dependencies.idempotency_key_matches?("app:f2", project: "app", code: "F2")
    refute Hive::Dependencies.idempotency_key_matches?("app:f2:v1:extra", project: "app", code: "F2")
    refute Hive::Dependencies.idempotency_key_matches?("app::v1", project: "app", code: "F2")
    refute Hive::Dependencies.idempotency_key_matches?(":f2:v1", project: "app", code: "F2")
    refute Hive::Dependencies.idempotency_key_matches?("app:f2:", project: "app", code: "F2")
    refute Hive::Dependencies.idempotency_key_matches?("free-form-key", project: "app", code: "F2")

    assert_equal "F2", Hive::Dependencies.hint_code_for("F2", current_project: "app")
    assert_equal "F2", Hive::Dependencies.hint_code_for("app:F2", current_project: "app")
    assert_nil Hive::Dependencies.hint_code_for("other:F2", current_project: "app")
    assert_nil Hive::Dependencies.hint_code_for("42", current_project: "app")
    assert_nil Hive::Dependencies.hint_code_for("a:b:c", current_project: "app")
  end

  private

  def task(slug, id: nil, stage_index: nil, stage: nil)
    Task.new(slug: slug, id: id, stage_index: stage_index, stage: stage)
  end
end
