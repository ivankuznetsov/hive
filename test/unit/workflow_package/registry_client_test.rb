require "digest"
require "test_helper"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_client"

class WorkflowPackageRegistryClientTest < Minitest::Test
  include HiveTestHelper

  def test_fetches_bare_version_and_listed_full_source_sha_to_verified_package
    with_registry do |repository, source_revision, catalog_commit|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: repository)
      %W[honeycomb/demo honeycomb/demo@1.0.0 honeycomb/demo@#{source_revision}].each do |source|
        with_tmp_dir do |destination|
          resolution = client.fetch(source, destination: destination)
          assert_equal "demo", resolution.name
          assert_equal "1.0.0", resolution.version
          assert_equal catalog_commit, resolution.source_commit
          assert_equal catalog_commit, resolution.catalog_commit
          assert File.file?(File.join(destination, "manifest.yml"))
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
    with_registry do |repository, _source_revision, _catalog_commit|
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
    valid = { "schema" => "honeycomb-catalog/v2", "entries" => [] }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:parse_catalog, JSON.generate(valid))
    end
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:parse_catalog, Hive::WorkflowPackage::CanonicalJSON.generate(valid.merge("schema" => "other")))
    end
    assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:parse_catalog, "{not-json") }
  end

  def test_latest_uses_only_listed_discoverable_entries_but_exact_hidden_and_yanked_are_allowed
    entries = [
      catalog_entry(version: "1.0.0", latest_version: "1.0.0"),
      catalog_entry(version: "1.1.0", latest_version: "1.0.0", state: "soft_hidden"),
      catalog_entry(version: "1.2.0", latest_version: "1.0.0", state: "yanked")
    ]
    client = Hive::WorkflowPackage::RegistryClient.new
    catalog = { "schema" => "honeycomb-catalog/v2", "entries" => entries }

    latest = client.send(:resolve_catalog, catalog, "demo", nil, "b" * 40)
    hidden = client.send(:resolve_catalog, catalog, "demo", "1.1.0", "b" * 40)
    yanked = client.send(:resolve_catalog, catalog, "demo", "1.2.0", "b" * 40)

    assert_equal "1.0.0", latest.version
    assert_equal "1.1.0", hidden.version
    assert_equal "1.2.0", yanked.version
  end

  def test_revoked_exact_resolution_is_blocked_with_advisory_identity
    entry = catalog_entry(version: "1.3.0", latest_version: nil, state: "revoked")
    entry["advisories"] = [ {
      "id" => "HC-2026-001", "title" => "Revoked", "severity" => "high",
      "url" => "https://example.test/advisories/HC-2026-001", "published_at" => "2026-07-17T10:00:00Z"
    } ]
    catalog = { "schema" => "honeycomb-catalog/v2", "entries" => [ entry ] }

    error = assert_raises(Hive::WorkflowPackage::RegistryError) do
      Hive::WorkflowPackage::RegistryClient.new.send(:resolve_catalog, catalog, "demo", "1.3.0", "b" * 40)
    end
    assert_match(/revoked/, error.message)
    assert_match(/HC-2026-001/, error.message)
  end

  def test_rejects_missing_and_malformed_catalog_entries
    client = Hive::WorkflowPackage::RegistryClient.new
    empty = { "schema" => "honeycomb-catalog/v2", "entries" => [] }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:resolve_catalog, empty, "demo", nil, "b" * 40)
    end

    malformed = { "schema" => "honeycomb-catalog/v2", "entries" => [ catalog_entry.merge("source_sha" => "bad") ] }
    assert_raises(Hive::WorkflowPackage::RegistryError) do
      client.send(:parse_catalog, Hive::WorkflowPackage::CanonicalJSON.generate(malformed))
    end
  end

  def test_fetch_materializes_from_catalog_snapshot_not_review_head
    with_registry do |repository, _source_revision, catalog_commit|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: repository)
      with_tmp_dir do |destination|
        resolution = client.fetch("honeycomb/demo", destination: destination)
        assert_equal catalog_commit, resolution.source_commit
        assert File.file?(File.join(destination, "workflow.yml"))
      end
    end
  end

  def test_fetch_rejects_catalog_metadata_that_disagrees_with_the_manifest
    with_registry do |repository, _source_revision, _catalog_commit|
      catalog_path = File.join(repository, "catalog.json")
      catalog = JSON.parse(File.read(catalog_path))
      catalog.fetch("entries").first["description"] = "Catalog-only description"
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

  def test_fetch_rejects_catalog_hive_minimum_that_disagrees_with_the_manifest
    with_registry do |repository, _source_revision, _catalog_commit|
      catalog_path = File.join(repository, "catalog.json")
      catalog = JSON.parse(File.read(catalog_path))
      catalog.fetch("entries").first["hive_min_version"] = "0.4.2"
      File.write(catalog_path, Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
      run!("git", "-C", repository, "add", "catalog.json")
      run!("git", "-C", repository, "commit", "-m", "mismatched Hive minimum", "--quiet")

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

  def test_materialization_rejects_incomplete_trees_and_link_records
    with_tmp_dir do |package|
      manifest = write_v2_package(package, repository_root: File.dirname(File.dirname(File.dirname(package))))
      manifest_bytes = File.binread(File.join(package, "manifest.yml"))
      client = Hive::WorkflowPackage::RegistryClient.new
      client.define_singleton_method(:git!) do |*args, binary: false|
        args.include?("ls-tree") ? "".b : manifest_bytes
      end
      resolution = Hive::WorkflowPackage::RegistryClient::Resolution.new(
        name: "demo", version: "1.0.0", source_commit: "b" * 40, catalog_commit: "b" * 40,
        source_revision: "c" * 40, manifest_digest: manifest.fetch("release_sha256"),
        hive_min_version: "0.4.3", summary: "Demo", permissions: v2_permissions
      )
      assert_raises(Hive::WorkflowPackage::RegistryError) do
        client.send(:materialize, "checkout", resolution, File.join(package, "destination"))
      end
      record = "120000 blob #{'c' * 40}\tpackages/demo/1.0.0/link\0"
      assert_raises(Hive::WorkflowPackage::RegistryError) do
        client.send(:parse_tree, record, "packages/demo/1.0.0/")
      end
    end
  end

  def test_git_failures_are_bounded_and_typed
    client = Hive::WorkflowPackage::RegistryClient.new
    with_env("PATH" => "") do
      assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:git!, "status") }
    end

    with_replaced_singleton_method(Timeout, :timeout, ->(_seconds, &) { raise Timeout::Error }) do
      assert_raises(Hive::WorkflowPackage::RegistryError) { client.send(:git!, "status") }
    end
  end

  private

  def with_registry
    with_tmp_git_repo do |repository|
      package = File.join(repository, "packages", "demo", "1.0.0")
      source_revision = "c" * 40
      manifest = write_v2_package(package, repository_root: repository, source_revision: source_revision)
      run!("git", "-C", repository, "add", "packages/demo/1.0.0")
      run!("git", "-C", repository, "commit", "-m", "package", "--quiet")
      review_head = run!("git", "-C", repository, "rev-parse", "HEAD").strip
      catalog = {
        "schema" => "honeycomb-catalog/v2",
        "entries" => [ catalog_entry(
          source_sha: source_revision, review_head: review_head,
          release_sha256: manifest.fetch("release_sha256")
        ) ]
      }
      File.write(File.join(repository, "catalog.json"), Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
      run!("git", "-C", repository, "add", "catalog.json")
      run!("git", "-C", repository, "commit", "-m", "catalog", "--quiet")
      catalog_commit = run!("git", "-C", repository, "rev-parse", "HEAD").strip
      yield repository, source_revision, catalog_commit
    end
  end

  def write_v2_package(package, repository_root:, source_revision: "c" * 40)
    FileUtils.mkdir_p(File.join(package, "instructions"))
    File.write(File.join(package, "README.md"), "# Demo\n")
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
    prefix = "packages/demo/1.0.0/"
    files = %w[README.md instructions/work.md workflow.yml].to_h do |relative|
      [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(package, relative)).hexdigest ]
    end
    manifest = {
      "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => "1.0.0",
      "description" => "Demo", "author" => { "name" => "Test", "url" => "https://example.test/test" },
      "license" => "MIT", "hive_min_version" => "0.4.3",
      "source" => { "url" => "https://example.test/source", "revision" => source_revision },
      "permissions" => v2_permissions, "files" => files
    }
    manifest["release_sha256"] = Digest::SHA256.hexdigest(
      Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest, include_release: false)
    )
    File.binwrite(File.join(package, "manifest.yml"), Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest))
    manifest
  end

  def catalog_entry(version: "1.0.0", latest_version: version, state: "listed",
                    source_sha: "c" * 40, review_head: "a" * 40, release_sha256: "d" * 64)
    discoverable = state == "listed"
    {
      "name" => "demo", "version" => version, "latest_version" => latest_version,
      "description" => "Demo", "release_tier" => "community", "current_tier" => "community",
      "permission_risk" => "low", "state" => state, "discoverable" => discoverable,
      "exact_resolution" => state == "revoked" ? "blocked" : "allowed", "verification" => nil,
      "history" => [], "advisories" => [],
      "author" => { "name" => "Test", "url" => "https://example.test/test" }, "license" => "MIT",
      "hive_min_version" => "0.4.3", "permissions" => v2_permissions,
      "install_command" => "hive workflow install honeycomb/demo",
      "package_url" => "https://example.test/packages/demo/#{version}",
      "reviews_url" => "https://example.test/reviews/demo/#{version}", "community_reviews_url" => nil,
      "source_sha" => source_sha,
      "listing_approval" => {
        "release_sha256" => release_sha256, "head_sha" => review_head,
        "lint_checked_at" => "2026-07-17T08:00:00Z", "approved_by" => [ "reviewer" ],
        "approved_at" => "2026-07-17T09:00:00Z", "reviews" => [ {
          "reviewer" => "reviewer", "reviewed_at" => "2026-07-17T09:00:00Z",
          "review_url" => "https://example.test/review/1", "evidence_digest" => "e" * 64
        } ]
      }
    }
  end

  def v2_permissions
    {
      "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
      "filesystem_read" => [ "repository", "task" ], "filesystem_write" => [], "secrets" => []
    }
  end
end
