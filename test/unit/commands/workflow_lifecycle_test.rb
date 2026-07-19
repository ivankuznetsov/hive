require "test_helper"
require "json"
require "hive/commands/workflow/install"
require "hive/commands/workflow/list"
require "hive/commands/workflow/remove"
require "hive/workflow_package/manifest"
require "hive/workflow_package/registry_client"

class WorkflowLifecycleCommandsTest < Minitest::Test
  include HiveTestHelper

  class TTYInput < StringIO
    def tty? = true
  end

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
      assert_match(/\A[0-9a-f]{64}\z/, installed.fetch("configuration_digest"))
      assert_equal [ "stages.work" ], installed.fetch("mappings").map { |entry| entry.fetch("slot") }
      assert_equal "claude", installed.dig("mappings", 0, "agent")
      assert_equal installed, JSON.parse(install_out.string)

      listed = Hive::Commands::Workflow::List.new(
        project_root: project, json: true, stdout: StringIO.new
      ).call!
      assert_equal 2, listed.fetch("schema_version")
      row = listed.fetch("workflows").find { |entry| entry["name"] == "demo" && entry["origin"] == "managed" }
      assert_equal "selected", row.fetch("selection")
      assert_equal "verified", row.fetch("integrity")
      assert_equal "unknown_offline", row.fetch("catalog_visibility")
      assert_equal installed.fetch("configuration_digest"), row.fetch("configuration_digest")
      assert_equal installed.fetch("mappings"), row.fetch("mappings")
      assert_equal [], row.fetch("optional_inputs")

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

  def test_unbounded_install_requires_separate_escalation_acknowledgement
    with_project_and_package(permission_spec: "yolo") do |project, package, resolution|
      client = stub_client(package, resolution)
      assert_raises(Hive::Commands::Workflow::ConsentRequired) do
        Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, json: true, yes: true,
          stdout: StringIO.new, registry_client: client, committer: ->(*) { }
        ).call!
      end
      payload = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true, allow_escalation: true,
        stdout: StringIO.new, registry_client: client, committer: ->(*) { }
      ).call!
      assert_equal "installed", payload.fetch("status")
    end
  end

  def test_interactive_high_risk_install_can_decline_escalation_after_policy_disclosure
    with_project_and_package(permission_spec: "yolo") do |project, package, resolution|
      output = StringIO.new
      payload = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: false,
        stdin: TTYInput.new("yes\nno\n"), stdout: output,
        mapping_overrides: [ "stages.work=claude" ],
        registry_client: stub_client(package, resolution), committer: ->(*) { }
      ).call!

      assert_equal "cancelled", payload.fetch("status")
      assert_includes output.string, "map: stages.work -> claude"
      assert_includes output.string, "Allow high-risk execution?"
      assert_includes output.string, "high-risk install cancelled"
    end
  end

  def test_malformed_mapping_override_is_rejected
    with_project_and_package do |project, package, resolution|
      error = assert_raises(Hive::ConfigError) do
        Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, json: true, dry_run: true,
          mapping_overrides: [ "stages.work=codex,unknown=value" ],
          stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
        ).call!
      end
      assert_match(/malformed/, error.message)
    end
  end

  def test_configuration_reconciliation_requires_explicit_contract_and_profile_reconfirmation
    with_project_and_package do |_project, package, resolution|
      validated = Hive::WorkflowPackage::Validator.validate!(
        package, expected_name: resolution.name, expected_manifest_digest: resolution.manifest_digest
      )
      generation = {
        "name" => resolution.name,
        "source_commit" => resolution.source_commit,
        "manifest_digest" => resolution.manifest_digest
      }
      previous = Hive::WorkflowPackage::Configuration.build(validated.workflow, generation: generation)
      changed = Hive::Workflow.new(
        id: validated.workflow.id,
        stages: validated.workflow.stages.map do |candidate|
          candidate.name == "work" ? candidate.with(mapping_contract: "demo-work-v2") : candidate
        end
      )

      error = assert_raises(Hive::ConfigError) do
        Hive::Commands::Workflow::ConfigurationResolver.new(
          validated: validated.with(workflow: changed), resolution: resolution,
          cfg: {}, previous: previous
        )
      end
      assert_match(/mapping contract changed/, error.message)

      reconfirmed = Hive::Commands::Workflow::ConfigurationResolver.new(
        validated: validated.with(workflow: changed), resolution: resolution,
        cfg: {}, previous: previous,
        mapping_overrides: { "stages.work" => { "agent" => "claude" } }
      )
      assert_equal "demo-work-v2", reconfirmed.mappings.fetch(0).fetch("mapping_contract")

      error = assert_raises(Hive::ConfigError) do
        Hive::Commands::Workflow::ConfigurationResolver.new(
          validated: validated, resolution: resolution,
          cfg: { "agents" => { "claude" => { "bin" => "/tmp/drifted-claude" } } },
          previous: previous
        )
      end
      assert_match(/profile drifted/, error.message)
    end
  end

  def test_scoped_shell_and_unqualified_write_require_separate_escalation_acknowledgement
    [
      "{ preset: scoped, bash: true }",
      "{ preset: scoped, tools: [Read, Write] }"
    ].each do |permission_spec|
      with_project_and_package(permission_spec: permission_spec) do |project, package, resolution|
        client = stub_client(package, resolution)
        assert_raises(Hive::Commands::Workflow::ConsentRequired) do
          Hive::Commands::Workflow::Install.new(
            "honeycomb/demo", project_root: project, json: true, yes: true,
            stdout: StringIO.new, registry_client: client, committer: ->(*) { }
          ).call!
        end

        installed = Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, json: true, yes: true, allow_escalation: true,
          stdout: StringIO.new, registry_client: client, committer: ->(*) { }
        ).call!
        assert_equal "installed", installed.fetch("status")
      end
    end
  end

  def test_dry_run_discloses_explicit_per_slot_agent_model_and_effort_override
    with_project_and_package(permission_spec: "yolo") do |project, package, resolution|
      payload = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, dry_run: true,
        mapping_overrides: [ "stages.work=codex,model=gpt-5.6-sol,effort=high" ],
        stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
      ).call!
      mapping = payload.fetch("mappings").fetch(0)
      assert_equal "codex", mapping.fetch("agent")
      assert_equal "gpt-5.6-sol", mapping.fetch("model")
      assert_equal "high", mapping.fetch("effort")
      refute Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state")).selected("demo")
    end
  end

  def test_explicit_unsupported_pin_fails_before_managed_state_mutation
    pinless = Hive::AgentProfile.new(
      name: :pi,
      bin_default: "pi",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/skill:%{skill}"
    )
    Hive::AgentProfiles.register(:pi, pinless)

    with_project_and_package do |project, package, resolution|
      error = assert_raises(Hive::ConfigError) do
        Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, json: true, yes: true,
          mapping_overrides: [ "stages.work=pi,model=provider/model-v1" ],
          stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
        ).call!
      end

      assert_match(/cannot pin model/, error.message)
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
      assert_empty store.selections
      refute File.exist?(store.generation_path("demo", resolution.source_commit))
    end
  ensure
    Hive::AgentProfiles.register(:pi, Hive::AgentProfiles::PI)
  end

  def test_high_registry_risk_requires_separate_escalation_even_when_actor_is_bounded
    with_project_and_package do |project, package, resolution|
      high = resolution.with(permissions: resolution.permissions.merge("risk" => "high"))
      assert_raises(Hive::Commands::Workflow::ConsentRequired) do
        Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, json: true, yes: true,
          stdout: StringIO.new, registry_client: stub_client(package, high), committer: ->(*) { }
        ).call!
      end
      installed = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true, allow_escalation: true,
        stdout: StringIO.new, registry_client: stub_client(package, high), committer: ->(*) { }
      ).call!
      assert_equal "installed", installed.fetch("status")
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

  def test_reinstall_is_a_typed_noop_and_interactive_decline_is_cancelled
    with_project_and_package do |project, package, resolution|
      client = stub_client(package, resolution)
      command = lambda do |**options|
        Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, stdout: StringIO.new,
          registry_client: client, committer: ->(*) { }, **options
        ).call!
      end
      cancelled = command.call(json: false, yes: false, stdin: TTYInput.new("no\n"))
      assert_equal "cancelled", cancelled.fetch("status")

      command.call(json: true, yes: true)
      assert_equal "already_installed", command.call(json: true, yes: true).fetch("status")
    end
  end

  def test_same_source_install_activates_mapping_changes_and_reports_stored_configuration
    with_project_and_package do |project, package, resolution|
      client = stub_client(package, resolution)
      install = lambda do |**options|
        Hive::Commands::Workflow::Install.new(
          "honeycomb/demo", project_root: project, json: true, yes: true,
          stdout: StringIO.new, registry_client: client, committer: ->(*) { }, **options
        ).call!
      end
      original = install.call
      configured = install.call(mapping_overrides: [ "stages.work=claude,model=opus" ])
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))

      assert_equal "installed", configured.fetch("status")
      refute_equal original.fetch("configuration_digest"), configured.fetch("configuration_digest")
      assert_equal configured.fetch("configuration_digest"), store.selected("demo").fetch("configuration_digest")
      assert_equal "opus", configured.dig("mappings", 0, "model")

      noop = install.call
      assert_equal "already_installed", noop.fetch("status")
      assert_equal store.selected("demo").fetch("configuration_digest"), noop.fetch("configuration_digest")
      assert_equal "opus", noop.dig("mappings", 0, "model")
    end
  end

  def test_list_distinguishes_selected_and_task_retained_configurations_for_the_same_generation
    with_project_and_package do |project, package, resolution|
      client = stub_client(package, resolution)
      installed = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: client, committer: ->(*) { }
      ).call!
      task = File.join(project, ".hive-state", "stages", "1-inbox", "managed-260719-aaaa")
      Hive::TaskMeta.write(
        task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
        workflow_commit: resolution.source_commit,
        workflow_manifest_digest: resolution.manifest_digest,
        workflow_configuration_digest: installed.fetch("configuration_digest")
      )

      configured = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        mapping_overrides: [ "stages.work=claude,model=opus" ],
        stdout: StringIO.new, registry_client: client, committer: ->(*) { }
      ).call!
      rows = Hive::Commands::Workflow::List.new(
        project_root: project, json: true, stdout: StringIO.new
      ).call!.fetch("workflows").select { |entry| entry["name"] == "demo" }

      selected = rows.find { |entry| entry["selection"] == "selected" }
      retained = rows.find { |entry| entry["selection"] == "retained" }
      assert_equal configured.fetch("configuration_digest"), selected.fetch("configuration_digest")
      assert_equal installed.fetch("configuration_digest"), retained.fetch("configuration_digest")
      refute retained.key?("mappings")
      refute retained.key?("optional_inputs")
    end
  end

  def test_list_deduplicates_legacy_task_references_without_configuration_pins
    with_project_and_package do |project, package, resolution|
      Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
      ).call!
      hive_state = File.join(project, ".hive-state")
      2.times do |index|
        task = File.join(hive_state, "stages", "1-inbox", "legacy-#{index}-260719-aaaa")
        Hive::TaskMeta.write(
          task, id: index + 1, slug: File.basename(task), display_name: nil, workflow: "demo",
          workflow_commit: resolution.source_commit,
          workflow_manifest_digest: resolution.manifest_digest
        )
      end
      Hive::WorkflowPackage::ManagedStore.new(hive_state).remove_selection("demo")

      rows = Hive::Commands::Workflow::List.new(
        project_root: project, json: true, stdout: StringIO.new
      ).call!.fetch("workflows").select { |entry| entry["name"] == "demo" }
      assert_equal 1, rows.length
      assert_equal "retained", rows.fetch(0).fetch("selection")
      refute rows.fetch(0).key?("configuration_digest")
    end
  end

  def test_install_commit_failure_cleans_the_unselected_generation
    with_project_and_package do |project, package, resolution|
      command = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: stub_client(package, resolution),
        committer: ->(*) { raise Hive::GitError, "commit failed" }
      )

      assert_raises(Hive::GitError) { command.call! }
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
      assert_nil store.selected("demo")
      refute File.exist?(store.generation_path("demo", resolution.source_commit))
    end
  end

  def test_list_surfaces_authored_and_malformed_entries
    with_project_and_package do |project, package, resolution|
      workflows = File.join(project, ".hive-state", "workflows")
      FileUtils.mkdir_p(workflows)
      File.write(File.join(workflows, "authored.yml"), <<~YAML)
        id: authored
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      File.write(File.join(workflows, "broken.yml"), "not: [valid")
      rows = Hive::Commands::Workflow::List.new(
        project_root: project, json: true, stdout: StringIO.new
      ).call!.fetch("workflows")
      authored = rows.find { |row| row["name"] == "authored" }
      assert_equal "authored", authored.fetch("origin")
      refute authored.key?("configuration_digest")
      refute authored.key?("mappings")
      refute authored.key?("optional_inputs")
      assert_equal "malformed", rows.find { |row| row["name"] == "broken" }.fetch("integrity")

      lock = File.join(workflows, "demo", Hive::WorkflowPackage::ManagedStore::LOCK_FILE)
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "{not-json")
      row = Hive::Commands::Workflow::List.new(
        project_root: project, json: true, stdout: StringIO.new
      ).call!.fetch("workflows").find { |entry| entry["name"] == "demo" }
      assert_equal "malformed", row.fetch("integrity")
    end
  end

  def test_remove_rejects_owned_and_missing_workflows_and_project_default
    with_project_and_package do |project, package, resolution|
      assert_raises(Hive::Commands::Workflow::OwnershipError) do
        Hive::Commands::Workflow::Remove.new(
          "coding", project_root: project, json: true, yes: true, stdout: StringIO.new
        ).call!
      end
      assert_raises(Hive::Commands::Workflow::OwnershipError) do
        Hive::Commands::Workflow::Remove.new(
          "missing", project_root: project, json: true, yes: true, stdout: StringIO.new
        ).call!
      end

      Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
      ).call!
      config = Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state", "default_workflow" => "demo")
      File.write(File.join(project, ".hive-state", "config.yml"), config.to_yaml)
      assert_raises(Hive::Commands::Workflow::OwnershipError) do
        Hive::Commands::Workflow::Remove.new(
          "demo", project_root: project, json: true, yes: true, stdout: StringIO.new
        ).call!
      end
    end
  end

  def test_remove_interactive_decline_is_a_noop
    with_project_and_package do |project, package, resolution|
      Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
      ).call!
      payload = Hive::Commands::Workflow::Remove.new(
        "demo", project_root: project, json: false, yes: false,
        stdin: TTYInput.new("no\n"), stdout: StringIO.new, committer: ->(*) { }
      ).call!

      assert_equal "cancelled", payload.fetch("status")
    end
  end

  def test_install_and_remove_json_dry_runs_disclose_without_mutating
    with_project_and_package do |project, package, resolution|
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
      install = Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, dry_run: true,
        stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
      ).call!
      assert_equal "dry_run", install.fetch("status")
      assert_equal resolution.permissions, install.fetch("permissions")
      assert_nil store.selected("demo")
      refute File.exist?(store.generation_path("demo", resolution.source_commit))

      Hive::Commands::Workflow::Install.new(
        "honeycomb/demo", project_root: project, json: true, yes: true,
        stdout: StringIO.new, registry_client: stub_client(package, resolution), committer: ->(*) { }
      ).call!
      remove = Hive::Commands::Workflow::Remove.new(
        "demo", project_root: project, json: true, dry_run: true,
        stdout: StringIO.new, committer: ->(*) { }
      ).call!
      assert_equal "dry_run", remove.fetch("status")
      assert_equal [ resolution.source_commit ], remove.fetch("deletable_commits")
      assert_equal resolution.source_commit, store.selected("demo").fetch("source_commit")
      assert File.directory?(store.generation_path("demo", resolution.source_commit))
    end
  end

  private

  def with_project_and_package(permission_spec: "read-only")
    with_tmp_dir do |dir|
      project = File.join(dir, "project")
      hive_state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))
      File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      package = File.join(dir, "package")
      resolution = write_package(package, permission_spec: permission_spec)
      yield project, package, resolution
    ensure
      Hive::Workflows::Project.reset!
    end
  end

  def write_package(root, permission_spec: "read-only")
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
          permissions: #{permission_spec}
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
      source_revision: "a" * 40, manifest_digest: manifest.digest, hive_min_version: "0.4.3",
      summary: "Demo", permissions: permissions
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
