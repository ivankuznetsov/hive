require "test_helper"
require "json"
require "open3"
require "hive/task"
require "hive/stages/patrol_fix/fix"

class PatrolFixFixStageTest < Minitest::Test
  def test_creates_one_local_generation_and_records_only_a_clean_committed_fix
    with_fix_task do |task, worktree_root|
      runner = lambda do |**kwargs|
        worktree = kwargs.fetch(:owner).fetch("worktree")
        File.write(File.join(worktree, "app.rb"), "puts :fixed\n")
        git(worktree, "add", "app.rb")
        git(worktree, "commit", "-m", "Fix defect")
        File.write(kwargs.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-fix-report", "schema_version" => 1,
          "status" => "fixed", "summary" => "Fixed and committed the root cause.",
          "validation_commands" => [ { "identity" => "focused", "command" => "ruby -c app.rb" } ]
        ))
        { status: :ok, custody: :clean }
      end

      result = Hive::Stages::PatrolFix::Fix.run!(
        task, {}, agent_runner: runner, worktree_root: worktree_root
      )
      assert_equal :complete, result.fetch(:status)
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

  private

  def with_fix_task
    PatrolFixStageFixture.with_task(stage: "2-fix") do |task, root, manifest|
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
  def decision_receipt(manifest, route)
    { "schema" => "hive-patrol-fix-receipt", "schema_version" => 1, "receipt_id" => "decision-1", "kind" => "decision", "stage" => "inbox",
      "task" => manifest.fetch("task"), "evidence_revision" => manifest.fetch("evidence_revision"), "recorded_at" => "2026-08-20T12:00:00Z",
      "payload" => { "route" => route, "rationale" => "current", "evidence" => [ "current" ], "blocker_owner" => "inbox_gate", "head_revision" => manifest.fetch("target_revision") } }
  end
  def git(path, *args)
    out, err, status = Open3.capture3("git", "-C", path, *args); raise err unless status.success?; out
  end
end
