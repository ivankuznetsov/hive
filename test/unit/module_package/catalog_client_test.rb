require "test_helper"
require "hive/module_package/catalog_client"
require "hive/workflow_package/canonical_json"

class ModulePackageCatalogClientTest < Minitest::Test
  def setup
    @client = Hive::ModulePackage::CatalogClient.new
  end

  def test_accepts_only_reviewed_catalog_source_grammar
    assert_equal [ "patrol", nil ], @client.parse_source("honeycomb/patrol")
    assert_equal [ "patrol", "1.2.3" ], @client.parse_source("honeycomb/patrol@1.2.3")
    assert_equal [ "patrol", "a" * 40 ], @client.parse_source("honeycomb/patrol@#{'a' * 40}")

    [ "https://example.test/patrol.git", "./patrol", "git@example.test:patrol", "honeycomb/patrol@main" ].each do |source|
      assert_raises(Hive::ModulePackage::CatalogError) { @client.parse_source(source) }
    end
  end

  def test_resolves_only_listed_immutable_v3_entries
    catalog = {
      "schema" => "honeycomb-catalog/v3",
      "entries" => [
        {
          "name" => "patrol", "version" => "1.0.0", "latest_version" => "1.0.0",
          "type" => "patrol", "description" => "Patrol", "state" => "listed",
          "discoverable" => true, "source_sha" => "b" * 40,
          "manifest_sha256" => "c" * 64, "package_path" => "modules/patrol/1.0.0"
        }
      ]
    }
    parsed = @client.send(:parse_catalog, Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
    resolution = @client.send(:resolve_catalog, parsed, "patrol", nil, "d" * 40)

    assert_equal "patrol", resolution.name
    assert_equal "1.0.0", resolution.version
    assert_equal "d" * 40, resolution.catalog_commit
    assert_equal "c" * 64, resolution.manifest_digest
  end

  def test_rejects_catalog_shape_and_metadata_drift
    invalid = { "schema" => "honeycomb-catalog/v3", "entries" => [ { "name" => "patrol" } ] }
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:parse_catalog, Hive::WorkflowPackage::CanonicalJSON.generate(invalid))
    end

    noncanonical = JSON.generate("schema" => "honeycomb-catalog/v3", "entries" => [])
    assert_raises(Hive::ModulePackage::CatalogError) { @client.send(:parse_catalog, noncanonical) }
  end
end
