require "test_helper"
require "hive/commands/workflow/install"
require "hive/commands/workflow/list"
require "hive/commands/workflow/remove"
require "hive/commands/workflow/update"
require "hive/task"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/manifest"

class HoneycombWorkflowLifecycleTest < Minitest::Test
  include HiveTestHelper

  def test_install_dry_run_update_task_pin_and_remove_against_immutable_git_catalog
    with_tmp_git_repo do |registry|
      versions = {}
      old = publish_version(registry, versions, "1.0.0", "Inspect the task.\n")
      with_project do |project|
        client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
        install = Hive::Commands::Workflow::Install.new(
          "honeycomb/demo@1.0.0", project_root: project, json: true, yes: true,
          stdout: StringIO.new, registry_client: client, committer: ->(*) { }
        ).call!
        assert_equal "installed", install.fetch("status")

        task = write_pinned_task(project, old)
        current = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
        before = selected_state(current)
        candidate = publish_version(registry, versions, "1.1.0", "Inspect the task and report clearly.\n")

        dry_run = update(project, client, dry_run: true)
        assert_equal "dry_run", dry_run.fetch("status")
        assert_equal before, selected_state(current)
        assert_equal [ "instructions/work.md" ], dry_run.dig("diff", "content", "instructions", "modified")

        applied = update(project, client, yes: true)
        assert_equal "updated", applied.fetch("status")
        assert_equal candidate.fetch(:source_commit), current.selected("demo").fetch("source_commit")
        assert_equal old.fetch(:source_commit), Hive::Task.new(task).workflow_commit
        assert_equal :demo, Hive::Task.new(task).workflow.id

        rows = Hive::Commands::Workflow::List.new(
          project_root: project, json: true, stdout: StringIO.new
        ).call!.fetch("workflows").select { |row| row["name"] == "demo" }
        assert_equal %w[retained selected], rows.map { |row| row.fetch("selection") }.sort

        removed = Hive::Commands::Workflow::Remove.new(
          "demo", project_root: project, json: true, yes: true,
          stdout: StringIO.new, committer: ->(*) { }
        ).call!
        assert_equal "removed", removed.fetch("status")
        assert_nil current.selected("demo")
        assert File.directory?(current.generation_path("demo", old.fetch(:source_commit)))
        refute File.exist?(current.generation_path("demo", candidate.fetch(:source_commit)))
        assert_equal :demo, Hive::Task.new(task).workflow.id
      end
    end
  end

  private

  def update(project, client, dry_run: false, yes: false)
    Hive::Commands::Workflow::Update.new(
      "demo", project_root: project, json: true, yes: yes, dry_run: dry_run,
      stdout: StringIO.new, registry_client: client, committer: ->(*) { }
    ).call!
  end

  def with_project
    with_tmp_dir do |project|
      hive_state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))
      File.write(File.join(hive_state, "config.yml"),
                 Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      yield project
    ensure
      Hive::Workflows::Project.reset!
    end
  end

  def write_pinned_task(project, version)
    task = File.join(project, ".hive-state", "stages", "1-inbox", "old-task-260715-aaaa")
    FileUtils.mkdir_p(task)
    File.write(File.join(task, "idea.md"), "Original task\n")
    Hive::TaskMeta.write(
      task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
      workflow_commit: version.fetch(:source_commit),
      workflow_manifest_digest: version.fetch(:manifest_digest)
    )
    task
  end

  def selected_state(store)
    lock = store.selected("demo")
    {
      lock: lock,
      generations: Dir.glob(File.join(store.workflows_dir, "demo", "versions", "*")).sort
    }
  end

  def publish_version(repository, versions, version, instruction)
    package = File.join(repository, "workflows", "demo")
    FileUtils.rm_rf(package)
    write_package(package, version, instruction)
    run!("git", "-C", repository, "add", "workflows/demo")
    run!("git", "-C", repository, "commit", "-m", "package #{version}", "--quiet")
    source_commit = run!("git", "-C", repository, "rev-parse", "HEAD").strip
    digest = Hive::WorkflowPackage::Manifest.load(File.join(package, "manifest.json")).digest
    versions[version] = {
      "source_commit" => source_commit,
      "manifest_digest" => digest,
      "summary" => "Demo #{version}",
      "permissions" => permissions
    }
    catalog = {
      "schema_version" => 1,
      "registry" => "honeycomb",
      "workflows" => { "demo" => { "latest" => version, "versions" => versions } }
    }
    File.binwrite(File.join(repository, "catalog.json"), Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
    run!("git", "-C", repository, "add", "catalog.json")
    run!("git", "-C", repository, "commit", "-m", "catalog #{version}", "--quiet")
    { source_commit: source_commit, manifest_digest: digest }
  end

  def write_package(package, version, instruction)
    FileUtils.mkdir_p(File.join(package, "instructions"))
    File.write(File.join(package, "README.md"), "# Demo #{version}\n")
    File.write(File.join(package, "honeycomb.yml"), "name: demo\nversion: #{version}\n")
    File.write(File.join(package, "instructions", "work.md"), instruction)
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
        "name" => "demo", "version" => version, "summary" => "Demo #{version}",
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
