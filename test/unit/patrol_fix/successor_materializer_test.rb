require "test_helper"
require "hive/commands/init"
require "hive/patrol_fix/successor_materializer"
require "hive/task_capture"
require "hive/workflows/registry"

class PatrolFixSuccessorMaterializerTest < Minitest::Test
  include HiveTestHelper

  def test_escalation_creates_one_coding_successor_and_reciprocal_typed_link
    with_origin do |task, decision|
      materializer = Hive::PatrolFix::SuccessorMaterializer.new(task)

      first = materializer.call(decision)
      second = materializer.call(decision)

      assert_equal first.fetch(:slug), second.fetch(:slug)
      assert_equal 1, coding_tasks(task).length
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
      assert_equal({ "project" => task.project_name, "slug" => first.fetch(:slug) },
                   manifest.dig("relations", "successor"))
      reciprocal = JSON.parse(File.read(File.join(first.fetch(:task_folder), "patrol-fix-origin.json")))
      assert_equal task.slug, reciprocal.dig("origin", "slug")
      assert_equal decision.fetch("receipt_id"), reciprocal.dig("links", 0, "decision_receipt_id")
    end
  end

  def test_crash_after_capture_reuses_task_and_repairs_both_links
    with_origin do |task, decision|
      calls = 0
      crashing = Hive::PatrolFix::SuccessorMaterializer.new(
        task,
        after_capture: lambda do |_result|
          calls += 1
          raise "crash after capture" if calls == 1
        end
      )

      assert_raises(RuntimeError) { crashing.call(decision) }
      captured = coding_tasks(task).fetch(0)
      File.delete(File.join(File.dirname(captured), "patrol-fix-origin.json"))
      assert_equal 1, coding_tasks(task).length
      assert_nil Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read.dig("relations", "successor")

      result = crashing.call(decision)

      assert_equal 1, coding_tasks(task).length
      assert_equal result.fetch(:slug),
                   Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read.dig("relations", "successor", "slug")
      assert File.file?(File.join(result.fetch(:task_folder), "patrol-fix-origin.json"))
    end
  end

  def test_review_escalation_reuses_one_coding_successor_without_an_issue_record
    with_origin(stage: "review") do |task, decision|
      materializer = Hive::PatrolFix::SuccessorMaterializer.new(task)

      first = materializer.call(decision)
      replay = materializer.call(decision)

      assert_equal first.fetch(:slug), replay.fetch(:slug)
      assert_equal 1, coding_tasks(task).length
      manifest = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder).read
      assert_empty manifest.dig("relations", "issues")
      assert_equal first.fetch(:slug), manifest.dig("relations", "successor", "slug")
    end
  end

  def test_retry_commits_links_left_written_by_a_lost_commit_acknowledgement
    with_origin do |task, decision|
      git_ops = Hive::GitOps.new(task.project_root)
      commits = 0
      flaky_git = Object.new
      flaky_git.define_singleton_method(:hive_commit) do |**values|
        commits += 1
        raise "lost commit acknowledgement" if commits == 2

        git_ops.hive_commit(**values)
      end
      materializer = Hive::PatrolFix::SuccessorMaterializer.new(task, git_ops: flaky_git)
      git = Hive::GitOps.new(task.project_root)
      before = git.run_git!("-C", task.hive_state_path, "status", "--porcelain")

      assert_raises(RuntimeError) { materializer.call(decision) }
      assert_equal 1, coding_tasks(task).length
      assert_equal materializer.call(decision).fetch(:slug),
                   Hive::PatrolFix::TaskManifest.new(task_folder: task.folder)
                     .read.dig("relations", "successor", "slug")
      assert_equal before, git.run_git!("-C", task.hive_state_path, "status", "--porcelain")
    end
  end

  def test_retry_commits_a_new_reciprocal_generation_link_after_commit_failure
    with_origin do |task, decision|
      Hive::PatrolFix::SuccessorMaterializer.new(task).call(decision)
      manifest_store = Hive::PatrolFix::TaskManifest.new(task_folder: task.folder)
      next_manifest = Marshal.load(Marshal.dump(manifest_store.read))
      next_manifest.fetch("task")["generation"] = 2
      next_manifest.fetch("evidence_revision").merge!("generation" => 2, "digest" => "b" * 64)
      manifest_store.write!(next_manifest)
      next_decision = decision_receipt(next_manifest, stage: "inbox")
                      .merge("receipt_id" => "inbox-escalate-2")
      Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(next_decision)
      Hive::GitOps.new(task.project_root).hive_commit(
        stage_name: "1-inbox", slug: task.slug, action: "next escalation decided"
      )

      git_ops = Hive::GitOps.new(task.project_root)
      commits = 0
      flaky_git = Object.new
      flaky_git.define_singleton_method(:hive_commit) do |**values|
        commits += 1
        raise "lost reciprocal commit acknowledgement" if commits == 1

        git_ops.hive_commit(**values)
      end
      materializer = Hive::PatrolFix::SuccessorMaterializer.new(task, git_ops: flaky_git)
      before = git_ops.run_git!("-C", task.hive_state_path, "status", "--porcelain")

      assert_raises(RuntimeError) { materializer.call(next_decision) }
      materializer.call(next_decision)

      successor = coding_tasks(task).fetch(0)
      relation = JSON.parse(File.read(File.join(File.dirname(successor), "patrol-fix-origin.json")))
      assert_equal %w[inbox-escalate-1 inbox-escalate-2],
                   relation.fetch("links").map { |link| link.fetch("decision_receipt_id") }
      assert_equal before,
                   git_ops.run_git!("-C", task.hive_state_path, "status", "--porcelain")
    end
  end

  private

  def with_origin(stage: "inbox")
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        manifest = origin_manifest(Hive::GitOps.new(project_root).head_sha)
        result = Hive::TaskCapture.new(
          project_root: project_root, hive_state: hive_state,
          workflow_info: workflow_info(:"patrol-fix", pin: true), slug: "repair-one",
          state_bytes: Hive::PatrolFix.canonical_json(manifest),
          idempotency_key: "origin:repair-one", input_fingerprint: "c" * 64
        ).call
        task = Hive::Task.new(result.folder)
        decision = decision_receipt(manifest, stage: stage)
        Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder).append!(decision)
        Hive::GitOps.new(project_root).hive_commit(
          stage_name: "1-inbox", slug: task.slug, action: "escalation decided"
        )
        yield task, decision
      end
    end
  end

  def workflow_info(id, pin:)
    {
      descriptor: Hive::Workflows::Registry.fetch(id), pin: pin, managed: nil,
      managed_cfg: {}, authored_digest: nil
    }
  end

  def origin_manifest(head)
    {
      "schema" => "hive-patrol-fix-task-manifest", "schema_version" => 1,
      "task" => { "slug" => "repair-one", "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "target_revision" => head,
      "sources" => [ {
        "engine" => "ordinary_patrol", "identity" => "finding-1", "target_revision" => head,
        "evidence" => [ "Reachable defect." ], "affected_code" => [ "lib/demo.rb" ],
        "reproduction_guidance" => "Run the focused test.", "discovery_run" => "run-1",
        "semantic_lineage" => [ "root-1" ]
      } ],
      "aliases" => [], "relations" => { "successor" => nil, "issues" => [] }
    }
  end

  def decision_receipt(manifest, stage:)
    payload = {
      "route" => "escalate", "rationale" => "Requires product decisions.",
      "evidence" => [ "The change crosses bounded repair scope." ],
      "blocker_owner" => "coding_workflow", "head_revision" => manifest.fetch("target_revision")
    }
    if stage == "review"
      payload.merge!(
        "diff_digest" => "d" * 64, "fix_receipt_id" => "fix-1",
        "validation_receipt_id" => "validation-1"
      )
    end
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => "#{stage}-escalate-1", "kind" => "decision", "stage" => stage,
      "task" => manifest.fetch("task"), "evidence_revision" => manifest.fetch("evidence_revision"),
      "recorded_at" => "2026-08-20T12:00:00Z",
      "payload" => payload
    }
  end

  def coding_tasks(task)
    Dir.glob(File.join(task.hive_state_path, "stages", "*", "*", "meta.yml")).select do |path|
      Hive::TaskMeta.read(File.dirname(path))[:workflow].nil?
    end
  end
end
