require "test_helper"
require "hive/task_workspace/dependency_component"

class TaskWorkspaceDependencyComponentTest < Minitest::Test
  D = Hive::DependencyAdmission

  def test_returns_only_bounded_connected_ancestors_and_descendants
    indexed = context(project(tasks: [
      task("base", stage: "7-artifacts"),
      task("middle", depends_on: "base"),
      task("leaf", depends_on: "middle"),
      task("unrelated")
    ]))

    panel = component(indexed, slug: "middle").call

    assert_equal "current", panel.fetch("state")
    assert_equal %w[app:base app:leaf app:middle],
                 panel.fetch("records").map { |node| node.fetch("id") }.sort
    assert_equal 2, panel.fetch("edges").length
    assert_equal %w[app:middle app:base app:leaf].sort,
                 panel.dig("forest", "node_order").sort
    refute_includes panel.to_s, "/tmp/app"
  end

  def test_cycle_missing_and_cross_project_edges_remain_semantic_cross_references
    app = project(tasks: [
      task("root", depends_on: "data:remote"),
      task("cycle-a", depends_on: "cycle-b"),
      task("cycle-b", depends_on: "cycle-a"),
      task("missing-child", depends_on: "ghost")
    ])
    data = project(name: "data", tasks: [ task("remote", project: "data") ])
    indexed = context(app, data)

    cross = component(indexed, slug: "root").call
    assert_equal [ "scheduling" ], cross.fetch("edges").map { |edge| edge.fetch("relationship") }.uniq

    cycle = component(indexed, slug: "cycle-a").call
    assert cycle.fetch("edges").any? { |edge| edge.fetch("cycle") }
    assert_includes cycle.dig("forest", "cross_references").map { |row| row.fetch("kind") }, "cycle"
    assert_equal cycle.fetch("records").map { |node| node.fetch("id") }.uniq.length,
                 cycle.fetch("records").reject { |node| node["kind"] == "sentinel" }.length

    missing = component(indexed, slug: "missing-child").call
    assert_equal "partial", missing.fetch("state")
    assert missing.fetch("records").any? { |node| node["kind"] == "missing" }
  end

  def test_stack_expected_and_observed_identity_are_separate_and_divergent
    indexed = context(project(tasks: [ task("base"), task("child", depends_on: "base") ]))
    expected = "a" * 40
    observed = "b" * 40
    panel = component(
      indexed, slug: "child",
      git: {
        "app:child" => {
          "repository" => "github.com/acme/app", "base_branch" => "base",
          "base_oid" => expected, "observed_base_oid" => observed,
          "current_branch" => "child", "head_oid" => "c" * 40,
          "pr_number" => 42
        }
      }
    ).call

    child = panel.fetch("records").find { |node| node["id"] == "app:child" }
    assert_equal expected, child.dig("stack", "expected_base_oid")
    assert_equal observed, child.dig("stack", "observed_base_oid")
    assert_equal "divergent", child.dig("stack", "divergence")
    assert_equal "divergent", panel.fetch("edges").first.fetch("stack_divergence")
  end

  def test_numeric_dependency_targets_use_the_task_id_index
    indexed = context(project(tasks: [
      task("base", id: 101), task("child", id: 102, depends_on: "101")
    ]))

    panel = component(indexed, slug: "child").call

    assert_equal [ [ "app:child", "app:base" ] ],
                 panel.fetch("edges").map { |edge| [ edge["from"], edge["to"] ] }
  end

  def test_connected_nodes_receive_individual_stack_and_publication_observations
    indexed = context(project(tasks: [ task("base"), task("child", depends_on: "base") ]))
    observed = []
    reader = lambda do |task_snapshot, _project_snapshot|
      observed << task_snapshot.slug
      {
        "repository" => "github.com/acme/app", "base_branch" => "main",
        "base_oid" => "a" * 40, "observed_base_oid" => "a" * 40,
        "current_branch" => task_snapshot.slug, "head_oid" => "b" * 40,
        "pr_number" => task_snapshot.slug == "base" ? nil : 42
      }
    end

    panel = Hive::TaskWorkspace::DependencyComponent.new(
      context: indexed, project: "app", slug: "child",
      git_observation_reader: reader, monotonic_clock: -> { 0.0 }
    ).call

    assert_equal %w[base child], observed.sort
    base = panel.fetch("records").find { |node| node["id"] == "app:base" }
    child = panel.fetch("records").find { |node| node["id"] == "app:child" }
    assert_nil base.dig("stack", "pr_number")
    assert_equal 42, child.dig("stack", "pr_number")
    assert_equal "aligned", base.dig("stack", "divergence")
  end

  def test_publication_observations_share_the_component_deadline
    indexed = context(project(tasks: [ task("base"), task("child", depends_on: "base") ]))
    now = 0.0
    deadlines = []
    reader = lambda do |task_snapshot, _project_snapshot, deadline:|
      deadlines << [ task_snapshot.slug, deadline ]
      now = 3.0
      {}
    end
    panel = Hive::TaskWorkspace::DependencyComponent.new(
      context: indexed, project: "app", slug: "child",
      git_observation_reader: reader, monotonic_clock: -> { now },
      limits: Hive::TaskWorkspace::Limits.new(dependency_deadline_seconds: 2)
    ).call

    assert_equal 1, deadlines.length
    assert_equal 2.0, deadlines.first.last
    assert_includes panel.fetch("diagnostics").filter_map { |row| row["cap"] },
                    "dependency_deadline_seconds"
  end

  def test_node_cap_keeps_deterministic_partial_sentinel
    indexed = context(project(tasks: [
      task("a"), task("b", depends_on: "a"), task("c", depends_on: "b"),
      task("d", depends_on: "c")
    ]))
    limits = Hive::TaskWorkspace::Limits.new(dependency_nodes: 2)

    first = component(indexed, slug: "b", limits: limits).call
    second = component(indexed, slug: "b", limits: limits).call

    assert_equal first, second
    assert_equal "partial", first.fetch("state")
    assert first.fetch("truncated")
    assert first.fetch("records").any? { |node| node["id"] == "sentinel:truncated" }
    assert_includes first.fetch("diagnostics").filter_map { |row| row["cap"] }, "dependency_nodes"
  end

  def test_semantic_fingerprint_ignores_project_and_task_order_but_tracks_dependency
    one = context(project(tasks: [ task("a"), task("b", depends_on: "a") ]))
    reordered = context(project(tasks: [ task("b", depends_on: "a"), task("a") ]))
    changed = context(project(tasks: [ task("a"), task("b", depends_on: nil) ]))

    assert_equal Hive::DependencySnapshot.semantic_fingerprint(one),
                 Hive::DependencySnapshot.semantic_fingerprint(reordered)
    refute_equal Hive::DependencySnapshot.semantic_fingerprint(one),
                 Hive::DependencySnapshot.semantic_fingerprint(changed)
  end

  def test_active_snapshot_shadows_fallback_without_duplicate_noise
    fallback = context(project(tasks: [ task("base", stage: "7-artifacts") ]))
    active = D::Context.new(
      projects: [ project(tasks: [
        task("dependent", depends_on: "base"), task("base", stage: "9-done")
      ]) ],
      fallback: fallback
    )

    panel = component(active, slug: "dependent").call

    assert_equal "current", panel.fetch("state")
    assert_equal 2, panel.fetch("records").length
    assert_equal "clear",
                 panel.fetch("records").find { |node| node["id"] == "app:dependent" }
                   .dig("admission", "state")
    refute_includes panel.fetch("diagnostics").map { |row| row["reason"] }, "duplicate_task"
  end

  def test_project_order_does_not_change_component_and_byte_cap_retains_sentinel
    app = project(tasks: [ task("a"), task("b", depends_on: "data:c") ])
    data = project(name: "data", tasks: [ task("c", project: "data") ])
    first = component(context(app, data), slug: "b").call
    second = component(context(data, app), slug: "b").call

    assert_equal first, second

    limited = component(
      context(app, data), slug: "b",
      limits: Hive::TaskWorkspace::Limits.new(dependency_bytes: 900)
    ).call
    assert_equal "partial", limited.fetch("state")
    assert limited.fetch("truncated")
    assert limited.fetch("records").any? { |node| node["id"] == "sentinel:truncated" }
    assert_operator limited.fetch("observed_bytes"), :>, 900
  end

  def test_invalid_git_object_ids_remain_partial_instead_of_appearing_aligned
    indexed = context(project(tasks: [ task("base"), task("child", depends_on: "base") ]))
    panel = component(
      indexed, slug: "child",
      git: { "app:child" => { "base_oid" => "not-an-oid", "observed_base_oid" => "not-an-oid" } }
    ).call

    child = panel.fetch("records").find { |node| node["id"] == "app:child" }
    assert_equal "partial", child.dig("stack", "divergence")
    assert_nil child.dig("stack", "expected_base_oid")
    assert_nil child.dig("stack", "observed_base_oid")
  end

  def test_admission_diagnostics_do_not_expose_absolute_task_paths
    invalid = task("broken", validation_error: "snapshot changed")
    panel = component(context(project(tasks: [ invalid ])), slug: "broken").call

    refute_includes panel.to_s, "/tmp/app/broken"
    assert_equal "dependency_validation_failed",
                 panel.fetch("records").first.dig("admission", "error", "reason_code")
  end

  def test_deadline_degrades_with_exact_cap_name
    indexed = context(project(tasks: [ task("a"), task("b", depends_on: "a") ]))
    ticks = [ 0.0, 3.0, 3.1 ]
    clock = -> { ticks.shift || 3.1 }
    limits = Hive::TaskWorkspace::Limits.new(dependency_deadline_seconds: 2)

    panel = component(indexed, slug: "b", limits: limits, clock: clock).call

    assert_equal "partial", panel.fetch("state")
    assert_includes panel.fetch("diagnostics").filter_map { |row| row["cap"] },
                    "dependency_deadline_seconds"
  end

  private

  def component(indexed, slug:, git: {}, limits: Hive::TaskWorkspace::Limits.new,
                clock: -> { 0.0 })
    Hive::TaskWorkspace::DependencyComponent.new(
      context: indexed, project: "app", slug: slug,
      git_observations: git, limits: limits, monotonic_clock: clock
    )
  end

  def context(*projects)
    D::Context.new(projects: projects)
  end

  def project(name: "app", tasks: [])
    D::ProjectSnapshot.new(
      name: name, path: "/tmp/#{name}",
      repository_identity: "github.com/acme/#{name}",
      live_repository_identity: "github.com/acme/#{name}",
      dependency_gate_stage: "8-finalize", tasks: tasks,
      validation_error: nil
    )
  end

  def task(slug, project: "app", depends_on: nil, stage: "4-execute", id: nil,
           validation_error: nil)
    D::TaskSnapshot.new(
      project: project, slug: slug, id: id, stage: stage,
      workflow_stages: Hive::Stages::DIRS, depends_on: depends_on,
      metadata_status: :ok, metadata_error: nil,
      plan_status: :absent, plan_dependency: nil, plan_error: nil,
      folder: "/tmp/#{project}/#{slug}", validation_error: validation_error
    )
  end
end
