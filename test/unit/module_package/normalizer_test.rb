require "test_helper"
require "hive/module_package/normalizer"

class ModulePackageNormalizerTest < Minitest::Test
  def test_adapts_a_legacy_honeycomb_without_losing_identity_or_permissions
    manifest = Struct.new(:data, :digest, :descriptor, :permissions, :file_entries).new(
      {
        "name" => "repo-brief", "version" => "1.2.3", "description" => "Repository briefing",
        "source" => { "url" => "https://example.test/source", "revision" => "b" * 40 },
        "hive_min_version" => "0.5.0", "files" => { "packages/repo-brief/1.2.3/workflow.yml" => "c" * 64 }
      },
      "d" * 64,
      "workflow.yml",
      {
        "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
        "filesystem_read" => [ "repository" ], "filesystem_write" => [], "secrets" => []
      },
      [ { "path" => "workflow.yml", "sha256" => "c" * 64 } ]
    )
    resolution = Struct.new(:catalog_commit, keyword_init: true).new(catalog_commit: "e" * 40)

    descriptor = Hive::ModulePackage::Normalizer.from_honeycomb(manifest, resolution: resolution)

    assert_equal "repo-brief", descriptor.name
    assert_equal "1.2.3", descriptor.version
    assert_equal "workflow", descriptor.type
    assert_equal [ { "id" => "repo-brief", "descriptor" => "workflow.yml" } ], descriptor.workflows
    assert_empty descriptor.hooks
    assert_equal "d" * 64, descriptor.manifest_digest
    assert_equal "e" * 40, descriptor.catalog_commit
    assert_equal [ "repository" ], descriptor.permissions.fetch("filesystem_read")
    assert_match(/\A[0-9a-f]{64}\z/, descriptor.digest)
  end
end
