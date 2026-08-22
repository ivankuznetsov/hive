require "test_helper"
require "hive/patrol_fix/worktree_snapshot"

class PatrolFixWorktreeSnapshotTest < Minitest::Test
  include HiveTestHelper

  Result = Data.define(:stdout, :stderr, :overflow, :ok) do
    def success? = ok
  end

  Task = Data.define(:folder, :project_root, :slug)

  class Custody
    attr_reader :validated

    def initialize(owner, error: nil)
      @owner = owner
      @error = error
    end

    def read = @owner

    def validate!(owner)
      @validated = owner
      raise @error if @error
    end
  end

  def test_captures_one_clean_exact_reviewed_snapshot
    snapshot = capture

    assert_equal OWNER, snapshot.fetch("owner")
    assert_equal HEAD, snapshot.fetch("head_revision")
    assert_equal DIFF, snapshot.fetch("diff")
  end

  def test_rejects_every_stale_custody_binding
    stale_owner = OWNER.merge("generation" => 2)
    assert_stage_error(/custody is stale/) { capture(owner: stale_owner) }

    stale_fix = deep_copy(FIX)
    stale_fix.fetch("payload")["worktree_generation"] = 2
    assert_stage_error(/does not bind/) { capture(fix: stale_fix) }

    assert_stage_error(/HEAD changed after validation/) do
      capture(gate: default_gate.merge(head_oid: ok("c" * 40)))
    end
    assert_stage_error(/HEAD changed before publication/) do
      capture(phase: :publish, gate: default_gate.merge(head_oid: ok("c" * 40)))
    end

    validation = deep_copy(VALIDATION)
    validation.fetch("payload")["worktree_head"] = "c" * 40
    assert_stage_error(/validation receipt/) { capture(validation: validation) }
  end

  def test_rejects_dirty_unavailable_and_changed_diffs_for_both_phases
    assert_stage_error(/bytes changed/) do
      capture(gate: default_gate.merge(status: ok(" M app.rb\n")))
    end
    assert_stage_error(/dirty before publication/) do
      capture(phase: :publish, gate: default_gate.merge(status: ok(" M app.rb\n")))
    end
    unavailable = Result.new(stdout: "", stderr: "failed", overflow: false, ok: false)
    assert_stage_error(/review diff is unavailable/) do
      capture(gate: default_gate.merge(diff: unavailable))
    end
    assert_stage_error(/reviewed diff is unavailable/) do
      capture(phase: :publish, gate: default_gate.merge(diff: unavailable))
    end
    assert_stage_error(/fix diff changed/) do
      capture(gate: default_gate.merge(diff: ok("changed")))
    end
    assert_stage_error(/reviewed diff changed/) do
      capture(phase: :publish, gate: default_gate.merge(diff: ok("changed")))
    end
  end

  def test_translates_custody_and_hardened_git_failures
    invalid = Hive::PatrolFix::WorktreeReceipt::InvalidWorktree.new("foreign worktree")
    assert_stage_error(/foreign worktree/) { capture(custody_error: invalid) }

    failed = Result.new(stdout: "", stderr: "git exploded", overflow: false, ok: false)
    assert_stage_error(/hardened Git head_oid failed: git exploded/) do
      capture(gate: default_gate.merge(head_oid: failed))
    end
  end

  private

  HEAD = "b" * 40
  DIFF = "diff --git a/app.rb b/app.rb\n"
  DIGEST = Digest::SHA256.hexdigest(DIFF)
  OWNER = {
    "generation" => 1, "evidence_digest" => "a" * 64,
    "worktree" => "/tmp/worktree", "branch" => "fix/one",
    "base_revision" => "a" * 40
  }.freeze
  FIX = {
    "task" => { "generation" => 1 },
    "payload" => {
      "worktree_generation" => 1, "worktree" => OWNER.fetch("worktree"),
      "branch" => OWNER.fetch("branch"), "base_revision" => OWNER.fetch("base_revision"),
      "head_revision" => HEAD, "diff_digest" => DIGEST
    }
  }.freeze
  MANIFEST = {
    "task" => { "generation" => 1 }, "evidence_revision" => { "digest" => "a" * 64 }
  }.freeze
  VALIDATION = { "payload" => { "worktree_head" => HEAD } }.freeze

  def capture(owner: OWNER, fix: FIX, validation: VALIDATION, phase: :review,
              gate: default_gate, custody_error: nil)
    custody = Custody.new(owner, error: custody_error)
    receipt_new = ->(**_args) { custody }
    gate_read = lambda do |_path, operation, **_args|
      gate.fetch(operation)
    end
    task = Task.new(folder: "/tmp/task", project_root: "/tmp/project", slug: "task")

    with_replaced_singleton_method(Hive::PatrolFix::WorktreeReceipt, :new, receipt_new) do
      with_replaced_singleton_method(Hive::AgentGitGate, :read, gate_read) do
        Hive::PatrolFix::WorktreeSnapshot.capture(
          task: task, manifest: deep_copy(MANIFEST), fix: deep_copy(fix),
          validation: deep_copy(validation), worktree_root: "/tmp", phase: phase
        )
      end
    end
  end

  def default_gate
    { head_oid: ok(HEAD), status: ok(""), diff: ok(DIFF) }
  end

  def ok(stdout)
    Result.new(stdout: stdout, stderr: "", overflow: false, ok: true)
  end

  def assert_stage_error(pattern, &block)
    error = assert_raises(Hive::StageError, &block)
    assert_match pattern, error.message
  end

  def deep_copy(value) = Marshal.load(Marshal.dump(value))
end
