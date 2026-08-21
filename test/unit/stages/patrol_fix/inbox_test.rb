require "test_helper"
require "json"
require "open3"
require "hive/task"
require "hive/stages/patrol_fix/inbox"

class PatrolFixInboxStageTest < Minitest::Test
  include HiveTestHelper

  def test_reinvestigates_current_head_and_records_a_controller_bound_reject_without_worktree
    with_task do |task, manifest|
      head = git(task.project_root, "rev-parse", "HEAD").strip
      captured = nil
      runner = lambda do |**kwargs|
        captured = kwargs
        File.write(kwargs.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-inbox-report", "schema_version" => 1,
          "route" => "reject", "rationale" => "The current code no longer reproduces it.",
          "evidence" => [ "The cited branch is absent at current HEAD." ],
          "blocker_owner" => "inbox_gate"
        ))
        { status: :ok, custody: :clean }
      end

      result = with_replaced_singleton_method(
        Hive::Stages::ManagedAgentCustody, :launch_agent, runner
      ) do
        Hive::Stages::PatrolFix::Inbox.run!(task, {})
      end

      assert_equal :parked, result.fetch(:status)
      assert_includes captured.fetch(:prompt), "untrusted_patrol_finding"
      assert_equal "patrol_review", captured.fetch(:actor)
      assert_equal "stages.inbox", captured.fetch(:slot)
      assert_equal task.project_root, captured.fetch(:cwd)
      assert_equal [ task.project_root, task.folder ], captured.fetch(:add_dirs)
      assert_equal "inbox", captured.fetch(:stage)
      assert_equal "patrol-fix-inbox", captured.fetch(:log_label)
      receipt = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).read_all.fetch(0)
      assert_equal "reject", receipt.dig("payload", "route")
      assert_equal head, receipt.dig("payload", "head_revision")
      assert_equal manifest.fetch("evidence_revision"), receipt.fetch("evidence_revision")
      refute File.exist?(File.join(task.folder, "worktree.yml"))
    end
  end

  def test_agent_written_authority_is_rejected_even_in_trusted_execution_mode
    with_task do |task, _manifest|
      runner = lambda do |**kwargs|
        File.write(File.join(task.folder, Hive::PatrolFix::ReceiptStore::FILENAME), "agent bytes\n")
        File.write(kwargs.fetch(:output_path), "{}")
        { status: :ok, custody: :tampered, diagnostic: "patrol-fix-receipts.jsonl changed" }
      end

      error = assert_raises(Hive::StageError) do
        Hive::Stages::PatrolFix::Inbox.run!(task, {}, agent_runner: runner)
      end
      assert_includes error.message, "controller authority"
    end
  end

  def test_persisted_escalation_replay_finishes_exactly_once_successor_materialization
    with_task do |task, _manifest|
      calls = []
      successor = lambda do |receipt|
        calls << receipt.fetch("receipt_id")
        { slug: "repair-one-coding-abcd1234" }
      end
      runner = lambda do |**kwargs|
        File.write(kwargs.fetch(:output_path), JSON.generate(
          "schema" => "hive-patrol-fix-inbox-report", "schema_version" => 1,
          "route" => "escalate", "rationale" => "Needs a broader product decision.",
          "evidence" => [ "Repair crosses the bounded finding." ],
          "blocker_owner" => "coding_workflow"
        ))
        { status: :ok, custody: :clean }
      end

      first = Hive::Stages::PatrolFix::Inbox.run!(
        task, {}, agent_runner: runner, successor_materializer: successor
      )
      replay = Hive::Stages::PatrolFix::Inbox.run!(
        task, {}, agent_runner: ->(**) { flunk "persisted decision must not respawn" },
        successor_materializer: successor
      )

      assert_equal :parked, first.fetch(:status)
      assert_equal first.fetch(:receipt), replay.fetch(:receipt)
      assert_equal 2, calls.length
      assert_equal 1, calls.uniq.length
    end
  end

  private

  def with_task
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      git(repo, "init", "-b", "main")
      git(repo, "config", "user.email", "test@example.com")
      git(repo, "config", "user.name", "Test")
      File.write(File.join(repo, "app.rb"), "puts :ok\n")
      git(repo, "add", "app.rb")
      git(repo, "commit", "-m", "Initial")
      task_folder = File.join(repo, ".hive-state", "stages", "1-inbox", "repair-one")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "meta.yml"), { "slug" => "repair-one", "workflow" => "patrol-fix" }.to_yaml)
      head = git(repo, "rev-parse", "HEAD").strip
      manifest = {
        "schema" => "hive-patrol-fix-task-manifest", "schema_version" => 1,
        "task" => { "slug" => "repair-one", "generation" => 1 },
        "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
        "target_revision" => head,
        "sources" => [ {
          "engine" => "ordinary_patrol", "identity" => "finding-1", "target_revision" => head,
          "evidence" => [ "Observed a bug." ], "affected_code" => [ "app.rb" ],
          "reproduction_guidance" => "printf owned > /tmp/never-execute-this",
          "discovery_run" => "run-1", "semantic_lineage" => [ "root-1" ]
        } ],
        "aliases" => [], "relations" => { "successor" => nil, "issues" => [] }
      }
      Hive::PatrolFix::TaskManifest.new(task_folder: task_folder).write!(manifest)
      yield Hive::Task.new(task_folder), manifest
    end
  end

  def git(path, *args)
    out, err, status = Open3.capture3("git", "-C", path, *args)
    raise err unless status.success?

    out
  end
end
