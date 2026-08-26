require "test_helper"
require "json"
require "open3"
require "hive/task"
require "hive/stages/patrol_fix/fix"

class PatrolFixFixStageTest < Minitest::Test
  include HiveTestHelper

  def test_creates_one_local_generation_and_records_only_a_clean_committed_fix
    with_fix_task do |task, worktree_root|
      captured = nil
      runner = lambda do |**kwargs|
        captured = kwargs
        worktree = kwargs.fetch(:cwd)
        File.write(File.join(worktree, "app.rb"), "puts :fixed\n")
        PatrolFixStageFixture.git(worktree, "add", "app.rb")
        PatrolFixStageFixture.git(worktree, "commit", "-m", "Fix defect")
        File.write(kwargs.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Fixed and committed the root cause.",
          "validation_commands" => [ { "identity" => "focused", "command" => "ruby -c app.rb" } ]
        ))
        { status: :ok, custody: :clean }
      end

      result = with_replaced_singleton_method(
        Hive::Stages::ManagedAgentCustody, :launch_agent, runner
      ) do
        Hive::Stages::PatrolFix::Fix.run!(task, {}, worktree_root: worktree_root)
      end
      assert_equal :complete, result.fetch(:status)
      assert_equal "patrol_fix", captured.fetch(:actor)
      assert_equal "stages.fix", captured.fetch(:slot)
      assert_equal [ captured.fetch(:cwd), task.folder ], captured.fetch(:add_dirs)
      assert_equal "fix", captured.fetch(:stage)
      assert_equal "patrol-fix-fix", captured.fetch(:log_label)
      receipt = result.fetch(:receipt)
      assert_equal "fix", receipt.fetch("kind")
      assert_equal "agent", receipt.dig("payload", "validation_commands", 0, "provenance")

      replay = Hive::Stages::PatrolFix::Fix.run!(
        task, {}, agent_runner: ->(**) { flunk "must not respawn" }, worktree_root: worktree_root
      )
      assert_equal receipt, replay.fetch(:receipt)
    end
  end

  def test_dirty_owned_worktree_is_preserved_as_a_recovery_blocker
    with_fix_task do |task, worktree_root|
      runner = lambda do |**kwargs|
        worktree = kwargs.fetch(:owner).fetch("worktree")
        File.write(File.join(worktree, "app.rb"), "puts :partial\n")
        File.write(kwargs.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Partial local work.", "validation_commands" => []
        ))
        { status: :ok, custody: :clean }
      end
      assert_raises(Hive::PatrolFix::WorktreeReceipt::InvalidWorktree) do
        Hive::Stages::PatrolFix::Fix.run!(task, {}, agent_runner: runner, worktree_root: worktree_root)
      end
      owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      ).read
      assert File.exist?(File.join(owner.fetch("worktree"), "app.rb"))
    end
  end

  def test_first_generation_uses_exact_origin_base_instead_of_inbox_local_head
    PatrolFixStageFixture.with_task(stage: "2-fix") do |task, root, manifest|
      PatrolFixStageFixture.add_origin(task.project_root, root)
      File.write(File.join(task.project_root, "local-only.rb"), "puts :unrelated\n")
      git(task.project_root, "add", "local-only.rb")
      git(task.project_root, "commit", "-m", "Unrelated local work")
      local_head = git(task.project_root, "rev-parse", "HEAD").strip
      remote_head = manifest.fetch("target_revision")
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(
          manifest, "fix", head_revision: local_head
        )
      )
      runner = lambda do |**kwargs|
        worktree = kwargs.fetch(:owner).fetch("worktree")
        refute File.exist?(File.join(worktree, "local-only.rb"))
        File.write(File.join(worktree, "app.rb"), "puts :fixed\n")
        git(worktree, "add", "app.rb")
        git(worktree, "commit", "-m", "Fix defect")
        File.write(kwargs.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Fixed from the remote base.",
          "validation_commands" => []
        ))
        { status: :ok, custody: :clean }
      end

      result = Hive::Stages::PatrolFix::Fix.run!(
        task, { "default_branch" => "main" }, agent_runner: runner,
        worktree_root: File.join(root, "worktrees")
      )

      assert_equal remote_head, result.dig(:receipt, "payload", "base_revision")
      assert_equal remote_head,
                   git(task.project_root, "rev-parse", "refs/remotes/origin/main").strip
      refute_equal local_head, result.dig(:receipt, "payload", "base_revision")
    end
  end

  def test_first_generation_has_no_local_fallback_when_origin_is_unavailable
    with_fix_task do |task, worktree_root|
      git(task.project_root, "remote", "remove", "origin")

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Fix.run!(
          task, { "default_branch" => "main" },
          agent_runner: ->(**) { flunk "must not launch without an exact remote base" },
          worktree_root: worktree_root
        )
      end

      assert_match(/strict worktree requires exactly one origin remote/, error.message)
    end
  end

  def test_fix_requires_current_controller_authorization
    store = Struct.new(:rows) { def read_all = rows }.new([])
    manifest = {
      "task" => { "slug" => "repair-one", "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 }
    }

    error = assert_raises(Hive::StageError) do
      Hive::Stages::PatrolFix::Fix.send(:fix_authorization, store, manifest)
    end

    assert_match(/requires a current inbox fix/, error.message)
  end

  def test_rework_rejects_custody_from_an_older_generation
    with_fix_task do |task, worktree_root|
      owner = Hive::PatrolFix::WorktreeReceipt.new(
        task_folder: task.folder, project_root: task.project_root, slug: task.slug,
        worktree_root: worktree_root
      )
      owner.prepare!(
        generation: 1, evidence_digest: "a" * 64,
        base_revision: git(task.project_root, "rev-parse", "HEAD").strip
      )
      manifest_store = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder)
      manifest = JSON.parse(JSON.generate(manifest_store.read))
      manifest.fetch("task")["generation"] = 2
      manifest.fetch("evidence_revision")["generation"] = 2
      manifest.fetch("evidence_revision")["digest"] = "b" * 64
      manifest_store.write!(manifest)

      with_replaced_singleton_method(
        Hive::Stages::PatrolFix::Fix, :fix_authorization, ->(*) { true }
      ) do
        error = assert_raises(Hive::StageError) do
          Hive::Stages::PatrolFix::Fix.run!(task, {}, worktree_root: worktree_root)
        end
        assert_match(/does not bind the current generation/, error.message)
      end
    end
  end

  private

  def with_fix_task
    PatrolFixStageFixture.with_task(stage: "2-fix") do |task, root, manifest|
      PatrolFixStageFixture.add_origin(task.project_root, root)
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(
        PatrolFixStageFixture.decision_receipt(manifest, "fix")
      )
      yield task, File.join(root, "worktrees")
    end
  end

  def git(path, *args) = PatrolFixStageFixture.git(path, *args)
end

module PatrolFixStageFixture
  module_function
  def with_task(stage:)
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      git(repo, "init", "-b", "main"); git(repo, "config", "user.email", "test@example.com"); git(repo, "config", "user.name", "Test")
      File.write(File.join(repo, "app.rb"), "puts :broken\n"); git(repo, "add", "app.rb"); git(repo, "commit", "-m", "Initial")
      head = git(repo, "rev-parse", "HEAD").strip
      folder = File.join(repo, ".hive-state", "stages", stage, "repair-one")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), { "slug" => "repair-one", "workflow" => "patrol-fix" }.to_yaml)
      manifest = { "schema" => "hive-patrol-fix-task-manifest", "schema_version" => 1,
        "task" => { "slug" => "repair-one", "generation" => 1 }, "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 }, "target_revision" => head,
        "sources" => [ { "engine" => "ordinary_patrol", "identity" => "finding-1", "target_revision" => head,
          "evidence" => [ "bug" ], "affected_code" => [ "app.rb" ], "reproduction_guidance" => "touch /tmp/never-from-prose",
          "discovery_run" => "run-1", "semantic_lineage" => [ "root-1" ] } ], "aliases" => [], "relations" => { "successor" => nil, "issues" => [] } }
      Hive::PatrolFix::TaskManifest.new(task_folder: folder).write!(manifest)
      yield Hive::Task.new(folder), dir, manifest
    end
  end
  def add_origin(repo, root)
    origin = File.join(root, "origin.git")
    git(root, "clone", "--bare", repo, origin)
    git(repo, "remote", "add", "origin", origin)
  end
  def decision_receipt(manifest, route, head_revision: manifest.fetch("target_revision"))
    { "schema" => "hive-patrol-fix-receipt", "schema_version" => 1, "receipt_id" => "decision-1", "kind" => "decision", "stage" => "inbox",
      "task" => manifest.fetch("task"), "evidence_revision" => manifest.fetch("evidence_revision"), "recorded_at" => "2026-08-20T12:00:00Z",
      "payload" => { "route" => route, "rationale" => "current", "evidence" => [ "current" ], "blocker_owner" => "inbox_gate", "head_revision" => head_revision } }
  end
  def git(path, *args)
    out, err, status = Open3.capture3("git", "-C", path, *args); raise err unless status.success?; out
  end
end
