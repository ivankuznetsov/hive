require "test_helper"
require "hive/task_capabilities/catalog"

class TaskCapabilitiesCatalogTest < Minitest::Test
  include HiveTestHelper

  def definition(id = "accessibility", **changes)
    { "id" => id, "kind" => "verification", "stages" => [ "review" ],
      "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved-model" },
      "permissions" => "read-only", "budget_usd" => 2, "timeout_sec" => 30,
      "checks" => [ { "id" => "links", "kind" => "behavior", "claim" => "Links resolve", "command" => "ruby check.rb" } ]
    }.merge(changes.transform_keys(&:to_s))
  end

  def catalog(entries = [], workflow: Hive::Workflows::Coding::DESCRIPTOR)
    Hive::TaskCapabilities::Catalog.new(workflow: workflow, definitions: entries, source: "project.yml")
  end

  def test_builtin_and_configuration_only_verifiers_share_the_catalog
    value = catalog([ definition ])
    assert_equal %w[qa ui security accessibility], value.definitions.map(&:id)
    assert_equal "verification", value.fetch("accessibility").kind
    assert_equal "behavior", value.fetch("accessibility").checks.first.fetch("kind")
    assert_equal %w[1-inbox 2-brainstorm 3-plan 4-execute 5-open-pr 6-review 7-artifacts 8-finalize 9-done], value.workflow.stage_dirs
    assert value.to_h.frozen?
    assert_equal value.digest, catalog([ definition ]).digest
    refute_equal value.digest, catalog([ definition(timeout_sec: 31) ]).digest
  end

  def test_unknown_duplicate_dependency_conflict_and_order_errors_are_attributed
    cases = [
      [ [ definition, definition ], /duplicate/ ],
      [ [ definition(stages: [ "design" ]) ], /unknown stage/ ],
      [ [ definition(depends_on: [ "missing" ]) ], /unknown.*missing/ ],
      [ [ definition(depends_on: [ "security" ], conflicts: [ "security" ]) ], /conflict/ ],
      [ [ definition("one", depends_on: [ "two" ]), definition("two", depends_on: [ "one" ]) ], /cycl/ ],
      [ [ definition("one", before: [ "two" ]), definition("two", before: [ "one" ]) ], /order/ ]
    ]
    cases.each do |entries, expected|
      error = assert_raises(Hive::ConfigError) { catalog(entries) }
      assert_match expected, error.message
      assert_includes error.message, "project.yml"
    end
  end

  def test_descriptor_definitions_are_authoritative_and_cannot_be_overridden
    source = Hive::Workflow.new(id: :custom, stages: Hive::Workflows::Coding::DESCRIPTOR.stages,
                               task_capabilities: [ definition ])
    error = assert_raises(Hive::ConfigError) { catalog([ definition ], workflow: source) }
    assert_match(/descriptor.*authoritative/, error.message)
    assert_match(/accessibility/, error.message)
  end

  def test_selection_validates_dependencies_conflicts_and_stage_local_order
    value = catalog([ definition("links", depends_on: [ "qa" ], after: [ "qa" ]), definition("other", conflicts: [ "links" ]) ])
    assert_raises(Hive::ConfigError) { value.ordered([ "links" ], stage: "review") }
    assert_raises(Hive::ConfigError) { value.ordered(%w[qa links other], stage: "review") }
    assert_equal %w[qa links], value.ordered(%w[links qa], stage: "review").map(&:id)
    assert_empty value.ordered(%w[qa links], stage: "plan")
  end

  def test_coding_builtin_bindings_are_configured_through_project_catalog
    ui = { "id" => "ui", "kind" => "guidance", "stages" => %w[plan execute], "skill" => "/installed-ui" }
    value = catalog([ ui ])
    assert_equal %w[qa ui security], value.definitions.map(&:id)
    assert_equal "/installed-ui", value.fetch("ui").data.fetch("skill")
    assert_empty Hive::Workflows::Coding::DESCRIPTOR.task_capabilities
    [ definition("qa", kind: "guidance", checks: []), definition("security", kind: "guidance", checks: []),
      definition("custom", stages: [ "execute" ]), ui.merge("stages" => [ "plan" ]) ].each do |raw|
      assert_raises(Hive::ConfigError) { catalog([ raw ]) }
    end
  end

  def test_conflicts_cycles_unknown_selection_and_cross_stage_order_fail_closed
    [ [ definition("one", depends_on: [ "two" ]), definition("two", conflicts: [ "one" ]) ],
      [ definition("one", after: [ "ui" ]) ] ].each do |entries|
      assert_raises(Hive::ConfigError) { catalog(entries) }
    end
    assert_raises(Hive::ConfigError) { catalog("wrong") }
    assert_raises(Hive::ConfigError) { catalog.fetch("missing") }
    assert_raises(Hive::ConfigError) { catalog.ordered([ "missing" ], stage: "review") }
    source = Hive::Workflow.new(id: :custom, stages: Hive::Workflows::Coding::DESCRIPTOR.stages, task_capabilities: [ definition ])
    assert_equal [ "accessibility" ], catalog([], workflow: source).definitions.map(&:id)
    assert_raises(Hive::ConfigError) do
      Hive::Workflow.new(id: :broken, stages: [ Hive::Workflows::Coding::DESCRIPTOR.stages.first ], task_capabilities: source.task_capabilities)
    end
  end
end
