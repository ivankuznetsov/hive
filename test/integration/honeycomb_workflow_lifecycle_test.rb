require "test_helper"
require "digest"
require "hive/commands/workflow/install"
require "hive/commands/workflow/list"
require "hive/commands/workflow/remove"
require "hive/commands/workflow/update"
require "hive/task"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/canonical_yaml"
require "hive/workflow_package/registry_manifest"

class HoneycombWorkflowLifecycleTest < Minitest::Test
  include HiveTestHelper

  class TTYInput < StringIO
    def tty? = true
  end

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

        task = write_pinned_task(
          project, old, configuration_digest: install.fetch("configuration_digest")
        )
        managed_task = Hive::Task.new(task)
        prompt_assets = managed_task.managed_runtime_context("stages.work").fetch(:prompt_assets)
        assert_equal [ "rubric.md" ], prompt_assets.map { |path| File.basename(path) }
        assert_includes managed_task.managed_prompt_preamble("stages.work"), prompt_assets.fetch(0)
        assert_includes managed_task.managed_prompt_preamble("stages.work"), "GSC_INPUT=unavailable"
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

  def test_install_discloses_same_name_optional_input_without_persisting_or_printing_its_value
    with_tmp_git_repo do |registry|
      versions = {}
      publish_version(registry, versions, "1.0.0", "Inspect the task.\n")
      secret = "install-secret-canary-#{Process.pid}"

      with_env("GSC_INPUT" => secret) do
        with_project do |project|
          client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
          json_out = StringIO.new
          dry_run = Hive::Commands::Workflow::Install.new(
            "honeycomb/demo@1.0.0", project_root: project, json: true, dry_run: true,
            stdout: json_out, registry_client: client, committer: ->(*) { }
          ).call!
          input = dry_run.fetch("optional_inputs").fetch(0)

          assert_equal "GSC_INPUT", input.fetch("name")
          assert_equal [ "stages.work" ], input.fetch("authorized_slots")
          assert_equal "GSC_INPUT", input.fetch("binding")
          assert input.fetch("available")
          assert_equal dry_run, JSON.parse(json_out.string)
          refute_includes json_out.string, secret

          human_out = StringIO.new
          installed = Hive::Commands::Workflow::Install.new(
            "honeycomb/demo@1.0.0", project_root: project, json: false,
            stdin: TTYInput.new("yes\nyes\n"), stdout: human_out,
            registry_client: client, committer: ->(*) { }
          ).call!

          assert_equal "installed", installed.fetch("status")
          disclosure = "optional input: GSC_INPUT; binding: GSC_INPUT; " \
                       "authorized slots: stages.work; available; value: [redacted]"
          assert_includes human_out.string, disclosure
          assert_operator human_out.string.index(disclosure), :<,
                          human_out.string.index("Install honeycomb/demo@1.0.0")
          refute_includes human_out.string, secret

          list_out = StringIO.new
          listed = Hive::Commands::Workflow::List.new(
            project_root: project, json: true, stdout: list_out
          ).call!
          selected = listed.fetch("workflows").find do |row|
            row["name"] == "demo" && row["selection"] == "selected"
          end
          assert_equal installed.fetch("configuration_digest"), selected.fetch("configuration_digest")
          assert_equal installed.fetch("mappings"), selected.fetch("mappings")
          assert_equal [ {
            "name" => "GSC_INPUT", "authorized_slots" => [ "stages.work" ],
            "binding" => "GSC_INPUT", "available" => true
          } ], selected.fetch("optional_inputs")
          assert_equal listed, JSON.parse(list_out.string)
          refute_includes list_out.string, secret

          store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
          selected = store.selected("demo")
          configuration = store.configuration("demo", selected.fetch("configuration_digest"))
          assert_equal "GSC_INPUT", configuration.data.dig("input_bindings", "GSC_INPUT")
          refute_includes configuration.bytes, secret
          Dir.glob(File.join(project, ".hive-state", "**", "*"), File::FNM_DOTMATCH).each do |path|
            refute_includes File.binread(path), secret if File.file?(path)
          end
        end
      end
    end
  end

  def test_update_preserves_prior_optional_input_binding_and_discloses_rebinding_before_consent
    with_tmp_git_repo do |registry|
      versions = {}
      old = publish_version(registry, versions, "1.0.0", "Inspect the task.\n")
      suggested_secret = "suggested-secret-canary-#{Process.pid}"
      prior_secret = "prior-secret-canary-#{Process.pid}"
      rebound_secret = "rebound-secret-canary-#{Process.pid}"

      with_env(
        "GSC_INPUT" => suggested_secret,
        "HIVE_TEST_GSC_PREVIOUS" => prior_secret,
        "HIVE_TEST_GSC_REBOUND" => rebound_secret
      ) do
        with_project do |project|
          client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
          Hive::Commands::Workflow::Install.new(
            "honeycomb/demo@1.0.0", project_root: project, json: true, yes: true,
            input_bindings: [ "GSC_INPUT=HIVE_TEST_GSC_PREVIOUS" ],
            stdout: StringIO.new, registry_client: client, committer: ->(*) { }
          ).call!
          publish_version(registry, versions, "1.1.0", "Inspect the task and report clearly.\n")

          json_out = StringIO.new
          dry_run = update(project, client, dry_run: true, stdout: json_out)
          input = dry_run.fetch("optional_inputs").fetch(0)
          assert_equal "HIVE_TEST_GSC_PREVIOUS", input.fetch("binding")
          assert input.fetch("available")
          refute dry_run.dig("diff", "input_bindings_changed")
          refute_includes json_out.string, suggested_secret
          refute_includes json_out.string, prior_secret

          human_out = StringIO.new
          cancelled = update(
            project, client, json: false, stdin: TTYInput.new("no\n"), stdout: human_out,
            input_bindings: [ "GSC_INPUT=HIVE_TEST_GSC_REBOUND" ]
          )
          disclosure = "optional input: GSC_INPUT; binding: HIVE_TEST_GSC_REBOUND; " \
                       "authorized slots: stages.work; available; value: [redacted]"

          assert_equal "cancelled", cancelled.fetch("status")
          assert cancelled.dig("diff", "input_bindings_changed")
          assert_includes human_out.string, disclosure
          assert_operator human_out.string.index(disclosure), :<,
                          human_out.string.index("Update honeycomb/demo 1.0.0 -> 1.1.0?")
          [ suggested_secret, prior_secret, rebound_secret ].each do |secret|
            refute_includes human_out.string, secret
          end
          store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
          assert_equal old.fetch(:source_commit), store.selected("demo").fetch("source_commit")
          configuration = store.configuration("demo", store.selected("demo").fetch("configuration_digest"))
          assert_equal "HIVE_TEST_GSC_PREVIOUS",
                       configuration.data.dig("input_bindings", "GSC_INPUT")
          refute_includes configuration.bytes, rebound_secret
        end
      end
    end
  end

  def test_same_source_update_activates_input_rebinding_and_noop_discloses_stored_binding
    with_tmp_git_repo do |registry|
      versions = {}
      installed_version = publish_version(registry, versions, "1.0.0", "Inspect the task.\n")
      secret = "same-source-secret-canary-#{Process.pid}"

      with_env("HIVE_TEST_GSC_REBOUND" => secret) do
        with_project do |project|
          client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
          Hive::Commands::Workflow::Install.new(
            "honeycomb/demo@1.0.0", project_root: project, json: true, yes: true,
            stdout: StringIO.new, registry_client: client, committer: ->(*) { }
          ).call!
          store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
          before = store.selected("demo").fetch("configuration_digest")

          configured = update(
            project, client, yes: true,
            input_bindings: [ "GSC_INPUT=HIVE_TEST_GSC_REBOUND" ]
          )
          input = configured.fetch("optional_inputs").fetch(0)
          assert_equal "updated", configured.fetch("status")
          assert_equal installed_version.fetch(:source_commit), configured.fetch("from_commit")
          assert_equal installed_version.fetch(:source_commit), configured.fetch("to_commit")
          refute_equal before, configured.fetch("configuration_digest")
          assert_equal configured.fetch("configuration_digest"), store.selected("demo").fetch("configuration_digest")
          assert_equal "HIVE_TEST_GSC_REBOUND", input.fetch("binding")
          assert input.fetch("available")
          refute_includes JSON.generate(configured), secret

          noop = update(project, client, yes: true)
          assert_equal "already_current", noop.fetch("status")
          assert_equal store.selected("demo").fetch("configuration_digest"), noop.fetch("configuration_digest")
          assert_equal configured.fetch("optional_inputs"), noop.fetch("optional_inputs")
          refute_includes JSON.generate(noop), secret
        end
      end
    end
  end

  private

  def update(project, client, dry_run: false, yes: false, json: true, stdin: $stdin,
             stdout: StringIO.new, input_bindings: [])
    Hive::Commands::Workflow::Update.new(
      "demo", project_root: project, json: json, yes: yes, dry_run: dry_run,
      stdin: stdin, stdout: stdout, input_bindings: input_bindings,
      registry_client: client, committer: ->(*) { }
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

  def write_pinned_task(project, version, configuration_digest: nil)
    task = File.join(project, ".hive-state", "stages", "1-inbox", "old-task-260715-aaaa")
    FileUtils.mkdir_p(task)
    File.write(File.join(task, "idea.md"), "Original task\n")
    Hive::TaskMeta.write(
      task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
      workflow_commit: version.fetch(:source_commit),
      workflow_manifest_digest: version.fetch(:manifest_digest),
      workflow_configuration_digest: configuration_digest
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
    FileUtils.mkdir_p(File.join(package, "assets"))
    File.write(File.join(package, "README.md"), "# Demo #{version}\n")
    File.write(File.join(package, "assets", "rubric.md"), "# Rubric\n")
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
          mapping_role: development
          mapping_contract: demo-work-v1
        - name: done
          kind: terminal
          state_file: done.md
          advance_verb: done
    YAML
    prefix = "packages/demo/#{version}/"
    files = %w[README.md assets/rubric.md instructions/work.md workflow.yml].to_h do |relative|
      [ "#{prefix}#{relative}", Digest::SHA256.file(File.join(package, relative)).hexdigest ]
    end
    manifest = {
      "schema" => "honeycomb-manifest/v1", "name" => "demo", "version" => version,
      "description" => "Demo #{version}",
      "author" => { "name" => "Test", "url" => "https://example.test/test" },
      "license" => "MIT", "hive_min_version" => "0.4.3",
      "source" => { "url" => "https://example.test/demo/#{version}", "revision" => source_revision },
      "permissions" => permissions, "files" => files,
      "x-hive" => {
        "optional_inputs" => [
          { "name" => "GSC_INPUT", "authorized_slots" => [ "stages.work" ] }
        ],
        "prompt_assets" => [ { "path" => "assets/rubric.md" } ],
        "tools" => []
      }
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
