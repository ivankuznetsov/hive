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
