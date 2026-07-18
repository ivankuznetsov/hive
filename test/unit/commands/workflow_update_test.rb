require "test_helper"
require "hive/commands/workflow/update"
require "hive/task"
require "hive/workflow_package/manifest"

class WorkflowUpdateCommandTest < Minitest::Test
  include HiveTestHelper

  class TTYInput < StringIO
    def tty? = true
  end

  def test_dry_run_reports_complete_diff_without_changing_selection_or_generations
    with_update_fixture do |project, store, old, candidate_root, candidate|
      before = Dir.glob(File.join(store.workflows_dir, "**", "*"), File::FNM_DOTMATCH).sort
      payload = command(project, candidate_root, candidate, dry_run: true).call!

      assert_equal "dry_run", payload.fetch("status")
      assert_equal old.source_commit, store.selected("demo").fetch("source_commit")
      assert_equal before, Dir.glob(File.join(store.workflows_dir, "**", "*"), File::FNM_DOTMATCH).sort
      assert payload.fetch("diff").key?("files")
      assert payload.fetch("diff").key?("security")
    end
  end

  def test_escalation_requires_both_ordinary_and_separate_consent
    with_update_fixture(escalation: true) do |project, store, old, candidate_root, candidate|
      assert_raises(Hive::Commands::Workflow::ConsentRequired) do
        command(project, candidate_root, candidate, yes: true).call!
      end
      assert_equal old.source_commit, store.selected("demo").fetch("source_commit")

      assert_raises(Hive::Commands::Workflow::ConsentRequired) do
        command(project, candidate_root, candidate, allow_escalation: true).call!
      end
      assert_equal old.source_commit, store.selected("demo").fetch("source_commit")

      payload = command(project, candidate_root, candidate, yes: true, allow_escalation: true).call!
      assert_equal "updated", payload.fetch("status")
      assert_equal candidate.source_commit, store.selected("demo").fetch("source_commit")
      assert payload.fetch("diff").fetch("escalation")
    end
  end

  def test_content_only_update_needs_ordinary_consent_and_preserves_old_task_pin
    with_update_fixture do |project, store, old, candidate_root, candidate|
      task = File.join(store.hive_state_path, "stages", "1-inbox", "old-task-260715-aaaa")
      Hive::TaskMeta.write(task, id: 1, slug: File.basename(task), display_name: nil, workflow: "demo",
                          workflow_commit: old.source_commit, workflow_manifest_digest: old.manifest_digest)
      payload = command(project, candidate_root, candidate, yes: true).call!

      assert_equal "updated", payload.fetch("status")
      assert_equal candidate.source_commit, store.selected("demo").fetch("source_commit")
      assert File.directory?(store.generation_path("demo", old.source_commit))
      assert_equal :demo, Hive::Task.new(task).workflow.id
    end
  end

  def test_already_current_is_a_typed_noop
    with_update_fixture do |project, store, old, _candidate_root, _candidate|
      package = store.generation_path("demo", old.source_commit)
      payload = command(project, package, old, yes: true).call!

      assert_equal "already_current", payload.fetch("status")
      assert_nil payload.fetch("diff")
    end
  end

  def test_interactive_ordinary_and_escalation_declines_are_cancelled
    with_update_fixture do |project, store, old, candidate_root, candidate|
      cancelled = command(
        project, candidate_root, candidate, json: false,
        stdin: TTYInput.new("no\n")
      ).call!
      assert_equal "cancelled", cancelled.fetch("status")
      assert_equal old.source_commit, store.selected("demo").fetch("source_commit")
    end

    with_update_fixture(escalation: true) do |project, store, old, candidate_root, candidate|
      cancelled = command(
        project, candidate_root, candidate, json: false,
        stdin: TTYInput.new("yes\nno\n")
      ).call!
      assert_equal "cancelled", cancelled.fetch("status")
      assert_equal old.source_commit, store.selected("demo").fetch("source_commit")
    end
  end

  def test_activation_failure_removes_candidate_and_preserves_previous_selection
    with_update_fixture do |project, store, old, candidate_root, candidate|
      failing = ->(*) { raise Hive::GitError, "commit failed" }

      assert_raises(Hive::GitError) do
        command(project, candidate_root, candidate, yes: true, committer: failing).call!
      end
      assert_equal old.source_commit, store.selected("demo").fetch("source_commit")
      refute File.exist?(store.generation_path("demo", candidate.source_commit))
    end
  end

  def test_browser_preview_baseline_must_still_match_before_update
    with_update_fixture do |project, store, old, candidate_root, candidate|
      stale = {
        "source_commit" => "f" * 40,
        "manifest_digest" => old.manifest_digest
      }

      assert_raises(Hive::ConcurrentRunError) do
        command(project, candidate_root, candidate, yes: true, expected_current: stale).call!
      end
      assert_equal old.source_commit, store.selected("demo").fetch("source_commit")
    end
  end

  private

  def command(project, package, resolution, yes: false, allow_escalation: false, dry_run: false,
              json: true, stdin: $stdin, committer: ->(*) { }, expected_current: nil)
    client = Object.new
    client.define_singleton_method(:fetch) do |_source, destination:|
      FileUtils.cp_r(Dir.glob(File.join(package, "*")), destination)
      resolution
    end
    Hive::Commands::Workflow::Update.new(
      "demo", project_root: project, json: json, yes: yes,
      allow_escalation: allow_escalation, dry_run: dry_run,
      stdin: stdin, stdout: StringIO.new, registry_client: client, committer: committer,
      expected_current: expected_current
    )
  end

  def with_update_fixture(escalation: false)
    with_tmp_dir do |dir|
      project = File.join(dir, "project")
      hive_state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))
      File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
      old_root = File.join(dir, "old")
      new_root = File.join(dir, "new")
      old = write_package(old_root, version: "1.0.0", commit: "a" * 40, instruction: "Read only.\n")
      tools = escalation ? %w[Read Write] : [ "Read" ]
      candidate = write_package(new_root, version: "1.1.0", commit: "c" * 40,
                                instruction: "Read carefully and report.\n", tools: tools)
      store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
      store.place_generation(old_root, old)
      store.activate(old)
      yield project, store, old, new_root, candidate
    ensure
      Hive::Workflows::Project.reset!
    end
  end

  def write_package(root, version:, commit:, instruction:, tools: [ "Read" ])
    FileUtils.mkdir_p(File.join(root, "instructions"))
    File.write(File.join(root, "README.md"), "# Demo #{version}\n")
    File.write(File.join(root, "honeycomb.yml"), "name: demo\nversion: #{version}\n")
    File.write(File.join(root, "instructions", "work.md"), instruction)
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
    permissions = { "tools" => tools, "deny" => [ "Bash" ], "directories" => [],
                    "commands" => [], "domains" => [], "credentials" => [] }
    manifest = Hive::WorkflowPackage::Manifest.build(
      root, metadata: { "name" => "demo", "version" => version, "summary" => "Demo #{version}",
                        "author" => { "name" => "Test" }, "dependencies" => {}, "permissions" => permissions }
    )
    File.binwrite(File.join(root, "manifest.json"), manifest.bytes)
    Hive::WorkflowPackage::RegistryClient::Resolution.new(
      name: "demo", version: version, source_commit: commit, catalog_commit: "b" * 40,
      source_revision: commit, manifest_digest: manifest.digest, hive_min_version: "0.4.3",
      summary: "Demo #{version}", permissions: permissions
    )
  end
end
