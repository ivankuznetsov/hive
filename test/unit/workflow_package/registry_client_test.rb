require "test_helper"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_client"

class WorkflowPackageRegistryClientTest < Minitest::Test
  include HiveTestHelper

  def test_fetches_bare_version_and_listed_full_sha_to_verified_package
    with_registry do |repository, source_commit, catalog_commit|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: repository)
      %W[honeycomb/demo honeycomb/demo@1.0.0 honeycomb/demo@#{source_commit}].each do |source|
        with_tmp_dir do |destination|
          resolution = client.fetch(source, destination: destination)
          assert_equal "demo", resolution.name
          assert_equal "1.0.0", resolution.version
          assert_equal source_commit, resolution.source_commit
          assert_equal catalog_commit, resolution.catalog_commit
          assert File.file?(File.join(destination, "manifest.json"))
          assert Hive::WorkflowPackage::Validator.validate!(
            destination,
            expected_name: "demo",
            expected_manifest_digest: resolution.manifest_digest
          ).valid?
        end
      end
    end
  end

  def test_rejects_external_namespace_mutable_and_unlisted_refs
    with_registry do |repository, _source_commit, _catalog_commit|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: repository)
      %w[other/demo honeycomb/demo@main honeycomb/demo@deadbeef honeycomb/demo@2.0.0].each do |source|
        with_tmp_dir do |destination|
          assert_raises(Hive::WorkflowPackage::RegistryError, source) do
            client.fetch(source, destination: destination)
          end
          assert_empty Dir.children(destination)
        end
      end
    end
  end

  def test_rejects_noncanonical_invalid_and_malformed_catalogs
    client = Hive::WorkflowPackage::RegistryClient.new
    valid = { "schema_version" => 1, "registry" => "honeycomb", "workflows" => {} }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:parse_catalog, JSON.generate(valid))
    end
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:parse_catalog, Hive::WorkflowPackage::CanonicalJSON.generate(valid.merge("registry" => "other")))
    end
    assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:parse_catalog, "{not-json") }
  end

  def test_rejects_missing_and_malformed_catalog_entries
    client = Hive::WorkflowPackage::RegistryClient.new
    empty = { "workflows" => {} }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:resolve_catalog, empty, "demo", nil, "b" * 40)
    end
    malformed = { "workflows" => { "demo" => [] } }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:resolve_catalog, malformed, "demo", nil, "b" * 40)
    end
    missing_version = { "workflows" => { "demo" => { "latest" => "1.0.0", "versions" => {} } } }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:resolve_catalog, missing_version, "demo", nil, "b" * 40)
    end

    assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:validate_version_entry!, {}) }
    entry = {
      "source_commit" => "a" * 40, "manifest_digest" => "bad",
      "summary" => "Demo", "permissions" => permissions
    }
    assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:validate_version_entry!, entry) }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:validate_version_entry!, entry.merge("manifest_digest" => "d" * 64, "permissions" => "bad"))
    end
  end

  def test_fetch_fails_when_catalog_source_is_not_ancestral
    with_registry do |repository, _source_commit, _catalog_commit|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: repository)
      client.define_singleton_method(:git_success?) { |*| false }

      with_tmp_dir do |destination|
        assert_raises(Hive::WorkflowPackage::RegistryError) do
          client.fetch("honeycomb/demo", destination: destination)
        end
      end
    end
  end

  def test_fetch_rejects_catalog_metadata_that_disagrees_with_the_manifest
    with_registry do |repository, _source_commit, _catalog_commit|
      catalog_path = File.join(repository, "catalog.json")
      catalog = JSON.parse(File.read(catalog_path))
      catalog.dig("workflows", "demo", "versions", "1.0.0")["summary"] = "Catalog-only summary"
      File.write(catalog_path, Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
      run!("git", "-C", repository, "add", "catalog.json")
      run!("git", "-C", repository, "commit", "-m", "mismatched catalog metadata", "--quiet")

      with_tmp_dir do |destination|
        error = assert_raises(Hive::WorkflowPackage::RegistryError) do
          Hive::WorkflowPackage::RegistryClient.new(repository: repository).fetch(
            "honeycomb/demo", destination: destination
          )
        end
        assert_match(/catalog metadata does not match/, error.message)
        assert_empty Dir.children(destination)
      end
    end
  end

  def test_rejects_verified_manifests_with_incomplete_catalog_metadata
    client = Hive::WorkflowPackage::RegistryClient.new
    resolution = Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: "1.0.0", source_commit: "a" * 40, catalog_commit: "b" * 40,
      manifest_digest: "d" * 64, summary: "Demo", permissions: permissions
    )
    manifest = Struct.new(:data).new({ "version" => "1.0.0", "summary" => "Demo" })

    error = assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:bind_catalog_metadata!, resolution, manifest)
    end
    assert_match(/metadata is incomplete/, error.message)
  end

  def test_materialization_rejects_incomplete_trees_and_link_records
    with_tmp_dir do |package|
      write_package(package)
      manifest_bytes = File.binread(File.join(package, "manifest.json"))
      client = Hive::WorkflowPackage::RegistryClient.new
      client.define_singleton_method(:git!) do |*args, binary: false|
        args.include?("ls-tree") ? "".b : manifest_bytes
      end
      resolution = Hive::WorkflowPackage::RegistryClient::Resolution.new(
        name: "demo", version: "1.0.0", source_commit: "a" * 40, catalog_commit: "b" * 40,
        manifest_digest: Hive::WorkflowPackage::Manifest.load(File.join(package, "manifest.json")).digest,
        summary: "Demo", permissions: permissions
      )
      assert_raises(Hive::WorkflowPackage::RegistryError) do
        client.send(:materialize, "checkout", resolution, File.join(package, "destination"))
      end
      record = "120000 blob #{'c' * 40}\tworkflows/demo/link\0"
      assert_raises(Hive::WorkflowPackage::RegistryError) do
        client.send(:parse_tree, record, "workflows/demo/")
      end
    end
  end

  def test_git_failures_are_bounded_and_typed
    client = Hive::WorkflowPackage::RegistryClient.new
    with_env("PATH" => "") do
      assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:git!, "status") }
      refute client.send(:git_success?, "status")
    end

    with_replaced_singleton_method(Timeout, :timeout, ->(_seconds, &) { raise Timeout::Error }) do
      assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:git!, "status") }
    end
  end

  private

  def with_registry
    with_tmp_git_repo do |repository|
      package = File.join(repository, "workflows", "demo")
      write_package(package)
      run!("git", "-C", repository, "add", "workflows/demo")
      run!("git", "-C", repository, "commit", "-m", "package", "--quiet")
      source_commit = run!("git", "-C", repository, "rev-parse", "HEAD").strip
      manifest_digest = Hive::WorkflowPackage::Manifest.load(File.join(package, "manifest.json")).digest
      catalog = {
        "schema_version" => 1,
        "registry" => "honeycomb",
        "workflows" => {
          "demo" => {
            "latest" => "1.0.0",
            "versions" => {
              "1.0.0" => {
                "source_commit" => source_commit,
                "manifest_digest" => manifest_digest,
                "summary" => "Demo",
                "permissions" => permissions
              }
            }
          }
        }
      }
      File.write(File.join(repository, "catalog.json"), Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
      run!("git", "-C", repository, "add", "catalog.json")
      run!("git", "-C", repository, "commit", "-m", "catalog", "--quiet")
      catalog_commit = run!("git", "-C", repository, "rev-parse", "HEAD").strip
      yield repository, source_commit, catalog_commit
    end
  end

  def write_package(package)
    FileUtils.mkdir_p(File.join(package, "instructions"))
    File.write(File.join(package, "README.md"), "# Demo\n")
    File.write(File.join(package, "honeycomb.yml"), "name: demo\nversion: 1.0.0\n")
    File.write(File.join(package, "instructions", "work.md"), "Read files only.\n")
    File.write(File.join(package, "workflow.yml"), <<~YAML)
      id: demo
      stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: work
          kind: agent
          state_file: work.md
          advance_verb: work
          instruction: instructions/work.md
          permissions: read-only
        - name: done
          kind: terminal
          state_file: done.md
          advance_verb: done
    YAML
    manifest = Hive::WorkflowPackage::Manifest.build(
      package,
      metadata: {
        "name" => "demo", "version" => "1.0.0", "summary" => "Demo",
        "author" => { "name" => "Test" }, "dependencies" => {}, "permissions" => permissions
      }
    )
    File.binwrite(File.join(package, "manifest.json"), manifest.bytes)
  end

  def permissions
    {
      "tools" => [ "Read" ], "deny" => [ "Bash", "WebFetch", "WebSearch" ],
      "directories" => [], "commands" => [], "domains" => [], "credentials" => []
    }
  end
end
