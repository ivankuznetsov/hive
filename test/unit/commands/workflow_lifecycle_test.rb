require "test_helper"
require "json"
require "hive/commands/workflow/install"
require "hive/commands/workflow/list"
require "hive/commands/workflow/remove"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_client"

class WorkflowLifecycleCommandsTest < Minitest::Test
  include HiveTestHelper

  def test_install_list_and_remove_preserve_typed_provenance
    with_project_and_package do |project, package, resolution|
      client = stub_client(package, resolution)
      install_out = StringIO.new
      installed = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: install_out, registry_client: client, committer: ->(*) { }
      ).call!
      assert_equal "installed", installed.fetch("status")
      assert_equal resolution.source_commit, installed.fetch("source_commit")
      assert_equal resolution.manifest_digest, installed.fetch("manifest_digest")
      assert_equal installed, JSON.parse(install_out.string)

      listed = Hive::Commands::Workflow::List.new(
        project_root: project, json: true, stdout: StringIO.new
      ).call!
      row = listed.fetch("workflows").find { |entry| entry["name"] == "demo" && entry["origin"] == "managed" }
      assert_equal "selected", row.fetch("selection")
      assert_equal "verified", row.fetch("integrity")
      assert_equal "unknown_offline", row.fetch("catalog_visibility")

      removed = Hive::Commands::Workflow::Remove.new(
        "demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, committer: ->(*) { }
      ).call!
      assert_equal "removed", removed.fetch("status")
      assert_nil Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state")).selected("demo")
    end
  end

  def test_install_requires_noninteractive_consent_and_different_version_requires_update
    with_project_and_package do |project, package, resolution|
      client = stub_client(package, resolution)
      command = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: false,
        stdout: StringIO.new, registry_client: client, committer: ->(*) { }
      )
      assert_raises(Hive::Commands::Workflow::ConsentRequired) { command.call! }
      assert_empty Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state")).selections

      Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: client, committer: ->(*) { }
      ).call!
      different = resolution.with(source_commit: "c" * 40)
      assert_raises(Hive::Commands::Workflow::UpdateRequired) do
        Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, json: true, yes: true,
          stdout: StringIO.new, registry_client: stub_client(package, different), committer: ->(*) { }
        ).call!
      end
    end
  end

  def test_remove_retains_task_pinned_generation
    with_project_and_package do |project, package, resolution|
      client = stub_client(package, resolution)
      Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: client, committer: ->(*) { }
      ).call!
      hive_state = File.join(project, ".hive-state")
      task = File.join(hive_state, "stages", "1-inbox", "managed-260715-aaaa")
      Hive::TaskMeta.write(task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
                          workflow_commit: resolution.source_commit,
                          workflow_manifest_digest: resolution.manifest_digest)

      payload = Hive::Commands::Workflow::Remove.new(
        "demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, committer: ->(*) { }
      ).call!
      assert_equal [ resolution.source_commit ], payload.fetch("retained_commits")
      assert File.directory?(Hive::WorkflowPackage::ManagedStore.new(hive_state).generation_path("demo", resolution.source_commit))
    end
  end

  private

  def with_project_and_package
    with_tmp_dir do |dir|
      project = File.join(dir, "project")
      hive_state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))
      File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      package = File.join(dir, "package")
      resolution = write_package(package)
      yield project, package, resolution
    ensure
      Hive::Workflows::Project.reset!
    end
  end

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
    permissions = { "tools" => [ "Read" ], "deny" => [ "Bash" ], "directories" => [],
                    "commands" => [], "domains" => [], "credentials" => [] }
    manifest = Hive::WorkflowPackage::Manifest.build(
      root, metadata: { "name" => "demo", "version" => "1.0.0", "summary" => "Demo",
                        "author" => { "name" => "Test" }, "dependencies" => {}, "permissions" => permissions }
    )
    File.binwrite(File.join(root, "manifest.json"), manifest.bytes)
    Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: "1.0.0", source_commit: "a" * 40, catalog_commit: "b" * 40,
      manifest_digest: manifest.digest, summary: "Demo", permissions: permissions
    )
  end

  def stub_client(package, resolution)
    Object.new.tap do |client|
      client.define_singleton_method(:fetch) do |_source, destination:|
        FileUtils.cp_r(Dir.glob(File.join(package, "*")), destination)
        resolution
      end
    end
  end
end
