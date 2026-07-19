require "test_helper"
require "digest"
require "hive/commands/workflow/install"
require "hive/commands/workflow/list"
require "hive/commands/workflow/remove"
require "hive/commands/workflow/update"
require "hive/task"
require "hive/web/workflow_lifecycle"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/registry_manifest"

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

  def test_web_adapter_drives_real_install_update_and_remove_commands
    with_tmp_git_repo do |registry|
      versions = {}
      publish_version(registry, versions, "1.0.0", "Inspect the task.\n")
      with_project do |project|
        lifecycle = Hive::Web::WorkflowLifecycle.new(
          registry_client_factory: lambda do
            Hive::WorkflowPackage::RegistryClient.new(repository: registry)
          end,
          committer: ->(*) { }
        )
        web_project = { "path" => project }

        install_preview = lifecycle.preview_install(web_project, source: "honeycomb/demo@1.0.0")
        installed = lifecycle.install(
          web_project,
          source: "honeycomb/demo@1.0.0",
          expected: install_preview.slice(
            "name", "version", "catalog_commit", "source_commit", "manifest_digest"
          )
        )
        assert_equal "installed", installed.fetch("status")

        publish_version(registry, versions, "1.1.0", "Inspect the task and report clearly.\n")
        update_preview = lifecycle.preview_update(web_project, name: "demo")
        updated = lifecycle.update(
          web_project,
          name: "demo",
          expected: update_preview.slice(
            "from_commit", "from_manifest_digest", "to_commit", "manifest_digest"
          ),
          allow_escalation: false
        )
        assert_equal "updated", updated.fetch("status")

        remove_preview = lifecycle.preview_remove(web_project, name: "demo")
        removed = lifecycle.remove(
          web_project,
          name: "demo",
          expected: remove_preview.slice("source_commit", "manifest_digest")
        )
        assert_equal "removed", removed.fetch("status")
        assert_nil Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state")).selected("demo")
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
    package = File.join(repository, "packages", "demo", version)
    source_revision = Digest::SHA1.hexdigest("demo-#{version}")
    manifest = write_package(package, version, instruction, source_revision: source_revision)
    run!("git", "-C", repository, "add", "packages/demo/#{version}")
    run!("git", "-C", repository, "commit", "-m", "package #{version}", "--quiet")
    review_head = run!("git", "-C", repository, "rev-parse", "HEAD").strip
    versions[version] = catalog_entry(
      version, source_revision: source_revision, review_head: review_head,
      release_sha256: manifest.fetch("release_sha256")
    )
    versions.each_value { |entry| entry["latest_version"] = version }
    catalog = {
      "schema" => "honeycomb-catalog/v2",
      "entries" => versions.values
    }
    File.binwrite(File.join(repository, "catalog.json"), Hive::WorkflowPackage::CanonicalJSON.generate(catalog))
    run!("git", "-C", repository, "add", "catalog.json")
    run!("git", "-C", repository, "commit", "-m", "catalog #{version}", "--quiet")
    catalog_commit = run!("git", "-C", repository, "rev-parse", "HEAD").strip
    { source_commit: catalog_commit, manifest_digest: manifest.fetch("release_sha256") }
  end

  def write_package(package, version, instruction, source_revision:)
    FileUtils.mkdir_p(File.join(package, "instructions"))
    File.write(File.join(package, "README.md"), "# Demo #{version}\n")
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
    prefix = "packages/demo/#{version}/"
    files = %w[README.md instructions/work.md workflow.yml].to_h do |relative|
      [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(package, relative)).hexdigest ]
    end
    manifest = {
      "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => version,
      "description" => "Demo #{version}",
      "author" => { "name" => "Test", "url" => "https://example.test/test" },
      "license" => "MIT", "hive_min_version" => "0.4.3",
      "source" => { "url" => "https://example.test/demo/#{version}", "revision" => source_revision },
      "permissions" => permissions, "files" => files
    }
    manifest["release_sha256"] = Digest::SHA256.hexdigest(
      Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest, include_release: false)
    )
    File.binwrite(File.join(package, "manifest.yml"), Hive::WorkflowPackage::CanonicalYAML.dump_manifest(manifest))
    manifest
  end

  def permissions
    {
      "risk" => "low", "capabilities" => [ "filesystem-read" ], "network_hosts" => [],
      "filesystem_read" => [ "task" ], "filesystem_write" => [], "secrets" => []
    }
  end

  def catalog_entry(version, source_revision:, review_head:, release_sha256:)
    {
      "name" => "demo", "version" => version, "latest_version" => version,
      "description" => "Demo #{version}", "release_tier" => "community", "current_tier" => "community",
      "permission_risk" => "low", "state" => "listed", "discoverable" => true,
      "exact_resolution" => "allowed", "verification" => nil, "history" => [], "advisories" => [],
      "author" => { "name" => "Test", "url" => "https://example.test/test" }, "license" => "MIT",
      "hive_min_version" => "0.4.3", "permissions" => permissions,
      "install_command" => "hive workflow install honeycomb/demo",
      "package_url" => "https://example.test/packages/demo/#{version}",
      "reviews_url" => "https://example.test/reviews/demo/#{version}", "community_reviews_url" => nil,
      "source_sha" => source_revision,
      "listing_approval" => {
        "release_sha256" => release_sha256, "head_sha" => review_head,
        "lint_checked_at" => "2026-07-17T08:00:00Z", "approved_by" => [ "reviewer" ],
        "approved_at" => "2026-07-17T09:00:00Z", "reviews" => [ {
          "reviewer" => "reviewer", "reviewed_at" => "2026-07-17T09:00:00Z",
          "review_url" => "https://example.test/review/#{version}", "evidence_digest" => "e" * 64
        } ]
      }
    }
  end
end
