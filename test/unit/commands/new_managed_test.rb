require "test_helper"
require "hive/commands/new"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/manifest"

class NewManagedWorkflowTest < Minitest::Test
  include HiveTestHelper

  def test_task_creation_rechecks_the_managed_selection_under_the_shared_lock
    with_tmp_dir do |dir|
      hive_state = File.join(dir, ".hive-state")
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      path = store.lock_path("demo")
      FileUtils.mkdir_p(File.dirname(path))
      package = File.join(dir, "package")
      old_resolution = write_package(package, "a" * 40)
      current_resolution = old_resolution.with(source_commit: "c" * 40, source_revision: "c" * 40)
      store.place_generation(package, old_resolution)
      store.place_generation(package, current_resolution)
      legacy_lock = {
        "schema_version" => 1, "name" => "demo", "version" => "1.1.0",
        "catalog_commit" => "b" * 40, "source_commit" => "c" * 40,
        "manifest_digest" => current_resolution.manifest_digest,
        "summary" => "Demo", "permissions" => current_resolution.permissions
      }
      File.write(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(legacy_lock.merge("source_commit" => "a" * 40))
      )
      baseline = store.selected("demo")
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(legacy_lock))
      command = Hive::Commands::New.new("project", "idea")
      workflow = Struct.new(:id).new(:demo)

      assert_raises(Hive::ConcurrentRunError) do
        command.send(
          :write_task_meta, File.join(dir, "task"), id: 1, slug: "task", depends_on: nil,
          workflow: workflow, workflow_info: { managed: baseline, pin: true }, hive_state: hive_state
        )
      end
    end
  end

  def test_managed_task_creation_reports_an_unreadable_project_config
    with_tmp_dir do |project|
      hive_state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(hive_state)
      File.write(File.join(hive_state, "config.yml"), "not: [valid")
      command = Hive::Commands::New.new("project", "idea")

      error = assert_raises(Hive::Commands::New::ProjectConfigUnreadable) do
        command.send(:managed_project_config, { "path" => project, "hive_state_path" => hive_state })
      end
      assert_includes error.message, File.join(hive_state, "config.yml")
    end
  end

  private

  def write_package(root, commit)
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.write(File.join(root, "README.md"), "# Demo\n")
    File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: 1.1.0\n")
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
        "name" => "demo", "version" => "1.1.0", "summary" => "Demo",
        "author" => { "name" => "Test" }, "dependencies" => {}, "permissions" => permissions
      }
    )
    File.binwrite(File.join(root, "manifest.json"), manifest.bytes)
    Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: "1.1.0", source_commit: commit, catalog_commit: "b" * 40,
      source_revision: commit, manifest_digest: manifest.digest, hive_min_version: "0.4.3",
      summary: "Demo", permissions: permissions
    )
  end
end
