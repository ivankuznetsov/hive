require "test_helper"
require "hive/workflow_package/semantic_diff"

class WorkflowPackageSemanticDiffTest < Minitest::Test
  def test_classifies_capability_additions_and_deny_removals_as_escalation
    old_manifest = manifest(
      "permissions" => policy("tools" => [ "Read" ], "deny" => %w[Write Bash]),
      "dependencies" => { "executables" => [ "git" ] }
    )
    new_manifest = manifest(
      "permissions" => policy("tools" => %w[Read Write], "deny" => [ "Bash" ],
                              "domains" => [ "api.example.com" ]),
      "dependencies" => { "executables" => %w[git jq] }
    )

    result = Hive::WorkflowPackage::SemanticDiff.compare(old_manifest, new_manifest)
    assert result.escalation?
    assert_equal [ "Write" ], result.security.fetch("tools").fetch("added")
    assert_equal [ "Write" ], result.security.fetch("deny").fetch("removed")
    assert_equal [ "api.example.com" ], result.security.fetch("domains").fetch("added")
    assert_equal [ "jq" ], result.dependencies.fetch("executables").fetch("added")
  end

  def test_permission_removals_and_content_changes_are_not_escalation
    old_manifest = manifest("permissions" => policy("tools" => %w[Read Write]))
    new_manifest = manifest(
      "permissions" => policy("tools" => [ "Read" ]),
      "summary" => "Changed",
      "files" => files(workflow_hash: "b" * 64, instruction_hash: "c" * 64)
    )

    result = Hive::WorkflowPackage::SemanticDiff.compare(old_manifest, new_manifest)
    refute result.escalation?
    assert_equal [ "Write" ], result.security.fetch("tools").fetch("removed")
    assert_equal({ "from" => "Demo", "to" => "Changed" }, result.metadata.fetch("summary"))
    assert result.content.fetch("descriptor").fetch("changed")
    assert_equal [ "instructions/work.md" ], result.content.dig("instructions", "modified")
  end

  def test_justification_and_scalar_dependency_changes_are_reported_as_escalation
    old_manifest = manifest(
      "permissions" => policy("shell_justification" => "old"),
      "dependencies" => { "hive" => ">= 0.4.2" }
    )
    new_manifest = manifest(
      "permissions" => policy("shell_justification" => "new"),
      "dependencies" => { "hive" => ">= 0.5.0" }
    )

    result = Hive::WorkflowPackage::SemanticDiff.compare(old_manifest, new_manifest)
    assert_equal({ "from" => "old", "to" => "new" }, result.security.fetch("shell_justification"))
    assert_equal({ "from" => ">= 0.4.2", "to" => ">= 0.5.0" }, result.dependencies.fetch("hive"))
    assert_includes result.escalation_reasons, "dependencies.hive.changed"
  end

  def test_registry_v2_hash_maps_and_permission_risk_are_compared_without_legacy_projection
    old_manifest = registry_manifest("permissions" => registry_policy)
    new_manifest = registry_manifest(
      "description" => "Changed",
      "permissions" => registry_policy(
        "risk" => "moderate", "capabilities" => %w[filesystem-read filesystem-write],
        "filesystem_write" => [ "repository/docs/**" ]
      ),
      "files" => {
        "packages/demo/1.0.0/instructions/work.md" => "c" * 64,
        "packages/demo/1.0.0/workflow.yml" => "b" * 64
      }
    )

    result = Hive::WorkflowPackage::SemanticDiff.compare(old_manifest, new_manifest)
    assert result.escalation?
    assert_includes result.escalation_reasons, "permissions.risk.increased"
    assert_includes result.escalation_reasons, "permissions.filesystem_write.added"
    assert_equal({ "from" => "Demo", "to" => "Changed" }, result.metadata.fetch("summary"))
    assert_equal [ "instructions/work.md" ], result.content.dig("instructions", "modified")
  end

  private

  def manifest(overrides = {})
    {
      "name" => "demo", "version" => "1.0.0", "summary" => "Demo",
      "author" => { "name" => "Test" }, "descriptor" => "workflow.yml",
      "dependencies" => {}, "permissions" => policy,
      "files" => files
    }.merge(overrides)
  end

  def files(workflow_hash: "a" * 64, instruction_hash: "b" * 64)
    [
      { "path" => "instructions/work.md", "sha256" => instruction_hash, "size" => 1 },
      { "path" => "workflow.yml", "sha256" => workflow_hash, "size" => 1 }
    ]
  end

  def policy(overrides = {})
    { "tools" => [ "Read" ], "deny" => [ "Bash" ], "directories" => [],
      "commands" => [], "domains" => [], "credentials" => [] }.merge(overrides)
  end

  def registry_manifest(overrides = {})
    {
      "name" => "demo", "version" => "1.0.0", "description" => "Demo",
      "author" => { "name" => "Test", "url" => "https://example.test/test" },
      "hive_min_version" => "0.4.3", "permissions" => registry_policy,
      "files" => {
        "packages/demo/1.0.0/instructions/work.md" => "b" * 64,
        "packages/demo/1.0.0/workflow.yml" => "a" * 64
      }
    }.merge(overrides)
  end

  def registry_policy(overrides = {})
    {
      "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
      "filesystem_read" => %w[repository task], "filesystem_write" => [], "secrets" => []
    }.merge(overrides)
  end
end
