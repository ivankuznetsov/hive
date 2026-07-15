require "test_helper"
require "hive/honeycomb/catalog"

class HoneycombCatalogTest < Minitest::Test
  SHA1 = "1" * 40
  SHA2 = "1" * 39 + "2"
  DIGEST1 = "a" * 64
  DIGEST2 = "b" * 64

  def test_loads_and_resolves_latest_exact_version_digest_and_sha_prefix
    catalog = Hive::Honeycomb::Catalog.load(catalog_yaml)

    assert_equal SHA2, catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo")).sha
    assert_equal SHA1, catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo@1.0.0")).sha
    assert_equal SHA1, catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo@#{DIGEST1}")).sha
    assert_equal SHA2, catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo@#{SHA2}")).sha
    assert_equal "version", catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo@1.0.0")).selector_kind
    assert_equal "digest", catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo@#{DIGEST1}")).selector_kind
    assert_equal %w[1.0.0 1.1.0], catalog.releases_for("demo").map(&:version)
    assert_raises(Hive::Honeycomb::ResolutionError) { catalog.releases_for("missing") }
    assert_equal "f" * 40,
                 catalog.resolve("honeycomb/demo@#{'f' * 40}", allow_unknown_full_sha: true).sha
  end

  def test_resolves_one_unambiguous_sha_prefix_and_rejects_unmatched_hex
    data = catalog_hash
    data["workflows"]["demo"]["releases"][1]["sha"] = "2" * 40
    catalog = Hive::Honeycomb::Catalog.load(data.to_yaml)

    assert_equal "2" * 40, catalog.resolve("honeycomb/demo@2222222").sha
    assert_raises(Hive::Honeycomb::ResolutionError) { catalog.resolve("honeycomb/demo@abcdef0") }
  end

  def test_rejects_ambiguous_prefix_unknown_selector_and_workflow
    catalog = Hive::Honeycomb::Catalog.load(catalog_yaml)

    error = assert_raises(Hive::Honeycomb::ResolutionError) do
      catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo@1111111"))
    end
    assert_includes error.message, "ambiguous"

    assert_raises(Hive::Honeycomb::ResolutionError) do
      catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/demo@2.0.0"))
    end
    assert_raises(Hive::Honeycomb::ResolutionError) do
      catalog.resolve(Hive::Honeycomb::Reference.parse("honeycomb/missing"))
    end
  end

  def test_rejects_invalid_catalog_shapes_and_duplicate_coordinates
    invalid = [
      catalog_hash.merge("version" => 2),
      catalog_hash.merge("extra" => true),
      catalog_hash.tap { |h| h["workflows"]["demo"]["latest"] = "9.9.9" },
      catalog_hash.tap { |h| h["workflows"]["demo"]["releases"][1]["version"] = "1.0.0" },
      catalog_hash.tap { |h| h["workflows"]["demo"]["releases"][1]["digest"] = DIGEST1 },
      catalog_hash.tap { |h| h["workflows"]["demo"]["releases"][0]["unknown"] = true },
      catalog_hash.tap { |h| h["workflows"]["demo"]["releases"] = [] },
      catalog_hash.tap { |h| h["workflows"]["Bad Name"] = h["workflows"].delete("demo") },
      catalog_hash.tap { |h| h["workflows"]["demo"]["releases"][0]["tag"] = "" }
    ]

    invalid.each do |data|
      assert_raises(Hive::Honeycomb::CatalogError) { Hive::Honeycomb::Catalog.load(data.to_yaml) }
    end
  end

  private

  def catalog_yaml
    catalog_hash.to_yaml
  end

  def catalog_hash
    {
      "version" => 1,
      "workflows" => {
        "demo" => {
          "latest" => "1.1.0",
          "releases" => [
            { "version" => "1.0.0", "tag" => "demo/v1.0.0", "sha" => SHA1, "digest" => DIGEST1 },
            { "version" => "1.1.0", "tag" => "demo/v1.1.0", "sha" => SHA2, "digest" => DIGEST2 }
          ]
        }
      }
    }
  end
end
