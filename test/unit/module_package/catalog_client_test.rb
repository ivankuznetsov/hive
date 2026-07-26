require "test_helper"
require_relative "../../support/module_helpers"
require "hive/module_package/catalog_client"
require "hive/workflow_package/canonical_json"

class ModulePackageCatalogClientTest < Minitest::Test
  include HiveTestHelper
  include HiveModuleTestHelper

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

  def test_fetches_a_reviewed_v3_package_and_cleans_failed_destinations
    with_module_catalog do |repository, source_revision|
      with_tmp_dir do |root|
        destination = File.join(root, "installed")
        resolution = Hive::ModulePackage::CatalogClient.new(repository: repository).fetch(
          "honeycomb/demo@#{source_revision}", destination: destination
        )

        assert_equal "demo", resolution.name
        assert_equal "1.0.0", resolution.version
        assert_equal source_revision, resolution.source_revision
        assert_equal "demo", resolution.descriptor.name
        assert_equal "# demo\n", File.read(File.join(destination, "README.md"))
        assert_equal 0o600, File.stat(File.join(destination, "README.md")).mode & 0o777
      end

      catalog_path = File.join(repository, "catalog.json")
      catalog = JSON.parse(File.read(catalog_path))
      catalog.fetch("entries").first["description"] = "catalog drift"
      File.write(catalog_path, Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
      run!("git", "-C", repository, "add", "catalog.json")
      run!("git", "-C", repository, "commit", "-qm", "drift")

      with_tmp_dir do |root|
        destination = File.join(root, "failed")
        assert_raises(Hive::ModulePackage::CatalogError) do
          Hive::ModulePackage::CatalogClient.new(repository: repository).fetch(
            "honeycomb/demo", destination: destination
          )
        end
        assert File.directory?(destination)
        assert_empty Dir.children(destination)
      end
    end
  end

  def test_fetch_rejects_a_populated_destination_and_delegates_v2_catalogs
    with_tmp_dir do |destination|
      File.write(File.join(destination, "keep"), "present")
      assert_raises(Hive::ModulePackage::CatalogError) do
        @client.fetch("honeycomb/demo", destination: destination)
      end
    end

    legacy = Object.new
    client = Hive::ModulePackage::CatalogClient.new(repository: "unused")
    client.define_singleton_method(:git!) do |*args, binary: false|
      if args.include?("rev-parse")
        "a" * 40
      elsif args.include?("show")
        Hive::WorkflowPackage::CanonicalJSON.generate(
          "schema" => Hive::WorkflowPackage::RegistryClient::CATALOG_SCHEMA,
          "entries" => []
        )
      else
        ""
      end
    end
    client.define_singleton_method(:fetch_legacy) do |source, destination|
      [ source, destination, legacy ]
    end
    with_tmp_dir do |root|
      destination = File.join(root, "legacy")
      assert_equal [ "honeycomb/demo", destination, legacy ],
                   client.fetch("honeycomb/demo", destination: destination)
    end
  end

  def test_legacy_fetch_normalizes_the_existing_workflow_contract
    legacy_resolution = Struct.new(
      :name, :version, :source_commit, :catalog_commit, :source_revision,
      :manifest_digest, :summary, keyword_init: true
    ).new(
      name: "demo", version: "1.0.0", source_commit: "a" * 40,
      catalog_commit: "a" * 40, source_revision: "b" * 40,
      manifest_digest: "c" * 64, summary: "Demo"
    )
    manifest = Object.new
    validation = Struct.new(:manifest).new(manifest)
    descriptor = Object.new
    registry = Object.new
    registry.define_singleton_method(:fetch) { |_source, destination:| legacy_resolution }
    test = self

    with_replaced_singleton_method(
      Hive::WorkflowPackage::RegistryClient, :new, ->(**_options) { registry }
    ) do
      with_replaced_singleton_method(
        Hive::WorkflowPackage::Validator, :validate!, ->(*_args, **_options) { validation }
      ) do
        with_replaced_singleton_method(
          Hive::ModulePackage::Normalizer, :from_honeycomb,
          lambda do |candidate, resolution:|
            test.assert_same manifest, candidate
            test.assert_same legacy_resolution, resolution
            descriptor
          end
        ) do
          resolution = @client.send(:fetch_legacy, "honeycomb/demo", "/tmp/unused-destination")
          assert_equal "workflow", resolution.type
          assert_equal "packages/demo/1.0.0", resolution.package_path
          assert_same descriptor, resolution.descriptor
        end
      end
    end
  end

  def test_catalog_parser_and_entry_validation_fail_closed_at_each_boundary
    assert_raises(Hive::ModulePackage::CatalogError) { @client.send(:catalog_schema, "{bad") }
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:catalog_schema, Hive::WorkflowPackage::CanonicalJSON.generate("entries" => []))
    end
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(
        :parse_catalog,
        Hive::WorkflowPackage::CanonicalJSON.generate("schema" => "future", "entries" => [])
      )
    end
    assert_raises(Hive::ModulePackage::CatalogError) { @client.send(:parse_catalog, "\xFF".b) }

    duplicate = catalog_entry
    catalog = { "schema" => "honeycomb-catalog/v3", "entries" => [ duplicate, duplicate.dup ] }
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:parse_catalog, Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
    end

    cases = [
      ->(entry) { entry.delete("description") },
      ->(entry) { entry["name"] = "INVALID" },
      ->(entry) { entry["latest_version"] = "latest" },
      ->(entry) { entry["discoverable"] = false },
      ->(entry) { entry["source_sha"] = "short" },
      ->(entry) { entry["package_path"] = "elsewhere" }
    ]
    cases.each do |mutate|
      entry = catalog_entry
      mutate.call(entry)
      assert_raises(Hive::ModulePackage::CatalogError) { @client.send(:validate_entry!, entry) }
    end
  end

  def test_exact_resolution_honors_versions_full_shas_and_lifecycle
    listed = catalog_entry
    hidden = catalog_entry(
      version: "1.1.0", latest_version: "1.0.0", state: "soft_hidden",
      discoverable: false, source_sha: "d" * 40
    )
    revoked = catalog_entry(
      version: "2.0.0", latest_version: "1.0.0", state: "revoked",
      discoverable: false, source_sha: "e" * 40
    )
    catalog = { "schema" => "honeycomb-catalog/v3", "entries" => [ listed, hidden, revoked ] }

    assert_equal "1.0.0", @client.send(:resolve_catalog, catalog, "patrol", nil, "f" * 40).version
    assert_equal "1.1.0", @client.send(:resolve_catalog, catalog, "patrol", "1.1.0", "f" * 40).version
    assert_equal "1.1.0", @client.send(:resolve_catalog, catalog, "patrol", "d" * 40, "f" * 40).version
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:resolve_catalog, catalog, "patrol", "2.0.0", "f" * 40)
    end
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:resolve_catalog, catalog, "missing", nil, "f" * 40)
    end

    ambiguous = { "schema" => "honeycomb-catalog/v3", "entries" => [ listed, hidden.merge("source_sha" => listed["source_sha"]) ] }
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:resolve_catalog, ambiguous, "patrol", listed.fetch("source_sha"), "f" * 40)
    end
  end

  def test_materialization_tree_metadata_and_git_errors_are_typed
    resolution = Hive::ModulePackage::CatalogClient::Resolution.new(
      name: "demo", version: "1.0.0", type: "patrol", source_commit: "a" * 40,
      catalog_commit: "a" * 40, source_revision: "b" * 40,
      manifest_digest: "c" * 64, summary: "Demo", package_path: "modules/demo/1.0.0",
      descriptor: nil
    )
    empty = Hive::ModulePackage::CatalogClient.new
    empty.define_singleton_method(:git!) { |*_args, **_options| "".b }
    with_tmp_dir do |root|
      assert_raises(Hive::ModulePackage::CatalogError) do
        empty.send(:materialize, "checkout", resolution, File.join(root, "destination"))
      end
    end

    valid_tree = "100644 blob #{'d' * 40}\tmodules/demo/1.0.0/README.md\0"
    assert_equal [ { "path" => "README.md", "mode" => "100644" } ],
                 @client.send(:parse_tree, valid_tree, "modules/demo/1.0.0/")
    invalid_tree = "120000 blob #{'d' * 40}\tmodules/demo/1.0.0/link\0"
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:parse_tree, invalid_tree, "modules/demo/1.0.0/")
    end

    manifest = Struct.new(:name, :version, :type, :summary, :data, :digest).new(
      "other", "1.0.0", "patrol", "Demo", { "source" => { "revision" => "b" * 40 } }, "c" * 64
    )
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:bind_catalog_metadata!, resolution, manifest)
    end
    assert_raises(Hive::ModulePackage::CatalogError) do
      @client.send(:validate_full_sha!, "short", "catalog commit")
    end

    with_env("PATH" => "") do
      assert_raises(Hive::ModulePackage::CatalogError) { @client.send(:git!, "status") }
    end
    with_replaced_singleton_method(Timeout, :timeout, ->(_seconds, &) { raise Timeout::Error }) do
      assert_raises(Hive::ModulePackage::CatalogError) { @client.send(:git!, "status") }
    end
    failure = Object.new
    failure.define_singleton_method(:success?) { false }
    with_replaced_singleton_method(Open3, :capture3, ->(*_args) { [ "", "fatal: denied", failure ] }) do
      error = assert_raises(Hive::ModulePackage::CatalogError) { @client.send(:git!, "status") }
      assert_match(/fatal: denied/, error.message)
    end
  end

  private

  def catalog_entry(version: "1.0.0", latest_version: "1.0.0", state: "listed",
                    discoverable: true, source_sha: "b" * 40, manifest_sha256: "c" * 64,
                    name: "patrol", type: "patrol", description: "Patrol")
    {
      "name" => name, "version" => version, "latest_version" => latest_version,
      "type" => type, "description" => description, "state" => state,
      "discoverable" => discoverable, "source_sha" => source_sha,
      "manifest_sha256" => manifest_sha256,
      "package_path" => "modules/#{name}/#{version}"
    }
  end

  def with_module_catalog
    with_tmp_git_repo do |repository|
      source_revision = "b" * 40
      resolution, = write_module_package(
        File.join(repository, "modules", "demo", "1.0.0"), commit: source_revision
      )
      catalog = {
        "schema" => "honeycomb-catalog/v3",
        "entries" => [ catalog_entry(
          name: "demo", source_sha: source_revision,
          manifest_sha256: resolution.manifest_digest, description: "demo module"
        ) ]
      }
      File.write(File.join(repository, "catalog.json"), Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
      run!("git", "-C", repository, "add", ".")
      run!("git", "-C", repository, "commit", "-qm", "catalog")
      yield repository, source_revision
    end
  end
end
