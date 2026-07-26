require "test_helper"
require "hive/module_package/catalog_client"
require "hive/module_package/workflow_compatibility"
require "hive/workflow_package/configuration"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_client"

class WorkflowCompatibilityTest < Minitest::Test
  include HiveTestHelper

  def test_validates_admits_and_activates_only_in_the_legacy_workflow_store
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      package = File.join(project, "package")
      FileUtils.mkdir_p(state)
      resolution = write_package(package)
      store = Hive::WorkflowPackage::ManagedStore.new(state)
      compatibility = Hive::ModulePackage::WorkflowCompatibility.new(
        store: store,
        project_config: Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state")
      )

      candidate = compatibility.candidate(
        package_root: package, resolution: resolution
      )
      configuration = Hive::WorkflowPackage::Configuration.build(
        candidate.validated.workflow,
        generation: {
          "name" => resolution.name,
          "source_commit" => resolution.source_commit,
          "manifest_digest" => resolution.manifest_digest
        }
      )

      compatibility.activate!(
        candidate: candidate, configuration: configuration,
        expected_current: nil, commit: nil
      )

      assert_equal resolution.source_commit,
                   compatibility.selected("demo").fetch("source_commit")
      assert File.directory?(
        store.generation_path("demo", resolution.source_commit)
      )
      refute File.exist?(File.join(state, "modules", "demo"))
    end
  end

  def test_module_catalog_legacy_resolution_is_converted_without_losing_permissions
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      package = File.join(project, "package")
      FileUtils.mkdir_p(state)
      workflow_resolution = write_package(package)
      validated = Hive::WorkflowPackage::Validator.validate!(
        package, expected_name: workflow_resolution.name,
        expected_manifest_digest: workflow_resolution.manifest_digest
      )
      descriptor = Hive::ModulePackage::Normalizer.from_honeycomb(
        validated.manifest, resolution: workflow_resolution
      )
      module_resolution = Hive::ModulePackage::CatalogClient::Resolution.new(
        name: workflow_resolution.name, version: workflow_resolution.version,
        type: "workflow", source_commit: workflow_resolution.source_commit,
        catalog_commit: workflow_resolution.catalog_commit,
        source_revision: workflow_resolution.source_revision,
        manifest_digest: workflow_resolution.manifest_digest,
        summary: workflow_resolution.summary,
        package_path: "packages/demo/1.0.0", descriptor: descriptor
      )
      store = Hive::WorkflowPackage::ManagedStore.new(state)
      compatibility = Hive::ModulePackage::WorkflowCompatibility.new(
        store: store,
        project_config: Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state")
      )

      candidate = compatibility.adopt(
        package_root: package, module_resolution: module_resolution
      )

      assert candidate.descriptor.legacy_honeycomb
      assert_equal workflow_resolution.permissions, candidate.resolution.permissions
      assert_equal descriptor.hive_min_version,
                   candidate.resolution.hive_min_version
    end
  end

  private

  def write_package(root)
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.write(File.join(root, "README.md"), "# Demo\n")
    File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: 1.0.0\n")
    File.write(File.join(root, "instructions", "work.md"), "Read only.\n")
    File.write(File.join(root, "workflow.yml"), <<~YAML)
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
    permissions = {
      "tools" => [ "Read" ], "deny" => [ "Bash" ], "directories" => [],
      "commands" => [], "domains" => [], "credentials" => []
    }
    manifest = Hive::WorkflowPackage::Manifest.build(
      root,
      metadata: {
        "name" => "demo", "version" => "1.0.0", "summary" => "Demo",
        "author" => { "name" => "Test" }, "dependencies" => {},
        "permissions" => permissions
      }
    )
    File.binwrite(File.join(root, "manifest.json"), manifest.bytes)
    Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: "1.0.0", source_commit: "a" * 40,
      catalog_commit: "b" * 40, source_revision: "a" * 40,
      manifest_digest: manifest.digest, hive_min_version: "0.4.3",
      summary: "Demo", permissions: permissions
    )
  end
end
