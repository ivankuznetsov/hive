require "test_helper"
require "hive/task_capabilities/plan"

class TaskCapabilitiesPlanTest < Minitest::Test
  include HiveTestHelper

  def catalog
    Hive::TaskCapabilities::Catalog.new(workflow: Hive::Workflows::Coding::DESCRIPTOR)
  end

  def plan
    Hive::TaskCapabilities::Plan.minimal(task_identity: { id: "42", slug: "task", workflow: "coding" }, catalog: catalog, source: {}, policy: {})
  end

  def test_schema_and_identity_validation_is_fail_closed
    data = plan.to_h
    [ data.merge("schema_version" => 2), data.merge("version" => 0), data.merge("extra" => true),
      data.reject { |key, _| key == "task" }, data.merge("task" => {}),
      data.merge("inputs" => { "qa" => "maybe" }), data.merge("source" => []),
      data.merge("definitions" => {}), data.merge("catalog_digest" => "bad"),
      data.merge("definitions" => [ {} ]), data.merge("bindings" => [ { "id" => "missing" } ]) ].each do |value|
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Plan.new(value) }
    end
    assert plan.frozen?
    assert plan.data.frozen?
    assert_equal Digest::SHA256.hexdigest(plan.bytes), plan.digest
  end

  def test_instruction_content_is_embedded_and_verified
    with_tmp_dir do |dir|
      File.write(File.join(dir, "instruction.md"), "Local instruction\n")
      entry = { "id" => "local", "kind" => "guidance", "stages" => [ "plan" ], "instruction" => "instruction.md" }
      configured = Hive::TaskCapabilities::Catalog.new(workflow: catalog.workflow, definitions: [ entry ], source: File.join(dir, "config.yml"))
      pinned = Hive::TaskCapabilities::Plan.minimal(task_identity: plan.to_h.fetch("task"), catalog: configured, source: {}, policy: {})
      definition = pinned.to_h.fetch("definitions").last
      assert_equal "Local instruction\n", definition.fetch("instruction_content")
      File.unlink(File.join(dir, "instruction.md"))
      assert_equal pinned.digest, Hive::TaskCapabilities::Plan.new(pinned.to_h).digest
      bad = definition.merge("instruction_content" => "changed")
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Plan.new(pinned.to_h.merge("definitions" => [ bad ])) }
    end
  end

  def test_only_selected_definitions_block_semantic_updates
    selected = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("bindings" => [ { "id" => "ui" } ]))
    assert_empty selected.incompatible_bindings(catalog, previous_workflow: catalog.workflow)
    assert_empty plan.incompatible_bindings(Hive::TaskCapabilities::Catalog.new(workflow: catalog.workflow, include_defaults: false))
    assert_equal [ "ui" ], selected.incompatible_bindings(Hive::TaskCapabilities::Catalog.new(workflow: catalog.workflow, include_defaults: false))
    changed_stage = catalog.workflow.stage_named("execute").with(agent: "codex", model: "changed")
    changed = catalog.workflow.with(stages: catalog.workflow.stages.map { |stage| stage.name == "execute" ? changed_stage : stage })
    assert_equal [ "ui" ], selected.incompatible_bindings(Hive::TaskCapabilities::Catalog.new(workflow: changed), previous_workflow: catalog.workflow)
  end

  def test_display_text_is_redacted_and_executable_targets_cannot_broaden
    secret = "ghp_#{'a' * 36}"
    value = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("waivers" => [ { "reason" => secret, "checks" => [ "all" ] } ]))
    refute_includes value.bytes, secret
    assert_includes value.bytes, "REDACTED:github_token"
    assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Plan.redact({ "targets" => [ secret ] }) }
    assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Plan.redact({ "targets" => [ "https://external" ] }) }
  end

  def test_inherited_stage_instruction_compares_content_across_generations
    with_tmp_dir do |dir|
      first = File.join(dir, "old-instruction.md")
      second = File.join(dir, "new-instruction.md")
      File.write(first, "same instructions")
      File.write(second, "same instructions")
      original = catalog.workflow
      before = original.with(stages: original.stages.map { |stage| stage.name == "plan" ? stage.with(instruction: first) : stage })
      after = original.with(stages: original.stages.map { |stage| stage.name == "plan" ? stage.with(instruction: second) : stage })
      selected = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("bindings" => [ { "id" => "ui" } ]))
      target = Hive::TaskCapabilities::Catalog.new(workflow: after)
      assert_empty selected.incompatible_bindings(target, previous_workflow: before)
      File.write(second, "changed instructions")
      assert_equal [ "ui" ], selected.incompatible_bindings(target, previous_workflow: before)
    end
  end
end
