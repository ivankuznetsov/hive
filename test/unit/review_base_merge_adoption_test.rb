require "test_helper"
require "hive/daemon/recovery_coordinator"
require "hive/review_base_merge_adoption"
require_relative "../support/review_grant_fixture"

class ReviewBaseMergeAdoptionTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  Adoption = Hive::ReviewBaseMergeAdoption

  # The uk-new-companies wedge: a review grant admitted one extra fix pass,
  # the hosted gate then parked the approved head as REVIEW_CI_STALE
  # reason=base_conflict, and the operator merged the base exactly as
  # reviews/ci-blocked.md instructs. The routine workflow.retry refused the
  # grant as stale and nothing re-ran CI or review.
  def test_routine_retry_after_the_documented_base_merge_starts_one_fresh_review
    with_base_merge_grant_task do |task, approved|
      merged = merge_task_base(task)
      mark_task_base_conflict(task, blocked: approved)

      result, coordinator = resume_recovery(task)

      assert_equal "queued", result.status, result.to_h.inspect
      assert_equal "cleared", result.phase
      assert_equal :none, Hive::Markers.current(task.state_file).name, "CI and review can run again"
      assert_equal merged, git_head(task), "adoption never rewrites the operator's merge"
      assert_empty git(task, "status", "--porcelain")

      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      refute budget.present?, "the grant bound to the pre-merge head is not carried to the merged head"
      audit = File.readlines(budget.audit_path).map { |line| JSON.parse(line) }
      assert_equal [ "grant", "expiry" ], audit.map { |entry| entry.fetch("event") }, "no allowance is minted or refunded"
      assert_equal "base_merge_adopted", audit.last.fetch("expiry_reason")
      assert_empty live_review_state(task), "no finding, fix receipt or grant from the old head stays live"
      assert_equal 0, Hive::Stages::Review.max_review_pass(task.folder)

      archive = Dir[File.join(task.reviews_dir, "archive", "*-base-merge-*")].fetch(0)
      receipt = JSON.parse(File.read(File.join(archive, "retirement.json")))
      assert_equal({ "schema" => "hive.review-generation-retirement", "schema_version" => 1,
                     "expiry_reason" => "base_merge_adopted", "before_oid" => approved,
                     "after_oid" => merged, "base_branch" => "master",
                     "base_oid" => base_tip(task) }, receipt)
      assert File.file?(File.join(archive, "codex-04.md"))
      assert File.file?(File.join(archive, "fix-success-03.md"))
      refute_empty Dir[File.join(archive, "review-grant-*.json")]
    end
  end

  # Every later retry of the same recovery, an interrupted adoption, and the
  # next base conflict on the merged head all reuse the one fresh review:
  # none of them archives its passes again or hands out another pass budget.
  def test_repeated_retries_yield_exactly_one_fresh_review
    with_base_merge_grant_task do |task, approved|
      merged = merge_task_base(task)
      mark_task_base_conflict(task, blocked: approved)
      stale = Hive::Markers.current(task.state_file)

      result, coordinator = resume_recovery(task)
      assert_equal "cleared", result.phase, result.to_h.inspect
      again = coordinator.resume(request: result_request(coordinator, result), row: recovery_row(task))
      assert_equal "cleared", again.phase, "a replayed transition never adopts twice"

      # A crash after retirement but before the marker cleared replays the
      # same stale marker: the existing retirement is completed, not repeated.
      Hive::Markers.set(task.state_file, :review_ci_stale, stale.attrs)
      records = []
      activity = Object.new
      activity.define_singleton_method(:record) do |**kwargs|
        raise Hive::TaskActivity::Conflict, "already journaled" if records.any?

        records << kwargs
      end
      receipt = adopter(task, activity: activity).adopt!(marker: Hive::Markers.current(task.state_file))
      replay = adopter(task, activity: activity).adopt!(marker: Hive::Markers.current(task.state_file))
      assert_equal receipt, replay
      assert_equal approved, receipt.fetch("before_oid")
      assert_equal merged, receipt.fetch("after_oid")
      assert_equal [ "review-base-merge:#{approved}:#{merged}" ], records.map { |entry| entry.fetch(:operation_id) }
      assert_equal receipt, records.first.fetch(:payload).fetch("adopted_base_merge")

      archives = Dir[File.join(task.reviews_dir, "archive", "*")]
      assert_equal 1, archives.size, "one retired generation, one fresh review"
      assert_equal archives.first.delete_prefix("#{task.folder}/"), receipt.fetch("archive")
      audit = File.readlines(File.join(task.folder, "review-budget", "audit.jsonl")).map { |line| JSON.parse(line) }
      assert_equal 1, audit.count { |entry| entry["event"] == "expiry" }

      # The fresh review runs pass 1 on the merged head, and the base moves
      # again: its next base conflict blocks the merged head itself.
      File.write(File.join(task.reviews_dir, "codex-01.md"), "- [x] Fresh finding on the merged head\n")
      File.write(File.join(task.reviews_dir, "escalations-01.md"), "# Escalations\n")
      fresh = review_files(task)
      mark_task_base_conflict(task, blocked: merged)
      assert_nil adopter(task).adopt!(marker: Hive::Markers.current(task.state_file))
      assert_equal fresh, review_files(task)

      # Merging the base again carries no grant, so it never retires the
      # fresh review: ordinary tasks keep their pass count.
      File.write(File.join(task.project_root, "BASE.md"), "base moved again\n")
      run!("git", "-C", task.project_root, "commit", "--quiet", "-am", "base moved again")
      run!("git", "-C", task.project_root, "push", "--quiet", "origin", "master")
      git(task, "fetch", "--quiet", "origin")
      merge_task_base(task)
      assert_nil adopter(task).adopt!(marker: Hive::Markers.current(task.state_file))
      assert_equal fresh, review_files(task)
      assert_equal 1, Hive::Stages::Review.max_review_pass(task.folder)
      assert_equal 1, Dir[File.join(task.reviews_dir, "archive", "*")].size
    end
  end

  def test_unrelated_head_changes_fail_closed_and_keep_the_grant_refusal
    with_base_merge_grant_task do |task, approved|
      git(task, "commit", "--allow-empty", "-qm", "unreviewed change")
      mark_task_base_conflict(task, blocked: approved)
      before = review_files(task)
      marker = Hive::Markers.current(task.state_file)

      result, = resume_recovery(task)

      assert_equal "blocked", result.status
      assert_equal "review_grant_evidence_changed", result.reason, "a non-merge head change keeps today's refusal"
      assert_equal "operator", result.owner
      assert_equal marker.raw, Hive::Markers.current(task.state_file).raw
      assert_equal before, review_files(task)

      unrelated = {
        "a merge followed by another commit" => lambda do
          merge_task_base(task)
          git(task, "commit", "--allow-empty", "-qm", "after the merge")
        end,
        "a commit before the merge" => lambda do
          git(task, "commit", "--allow-empty", "-qm", "before the merge")
          merge_task_base(task)
        end,
        "a merge of a branch that is not the base" => lambda do
          git(task, "checkout", "--quiet", "-b", "side", "origin/master")
          git(task, "commit", "--allow-empty", "-qm", "side work")
          git(task, "checkout", "--quiet", task.slug)
          merge_task_base(task, ref: "side")
        end,
        "an octopus merge" => lambda do
          other = git(task, "commit-tree", "-p", approved, "-m", "branch-only", "#{approved}^{tree}")
          git(task, "merge", "--no-ff", "--quiet", "-m", "octopus", "origin/master", other)
        end
      }
      unrelated.each do |label, change|
        git(task, "reset", "--hard", "--quiet", approved)
        change.call
        mark_task_base_conflict(task, blocked: approved)
        assert_nil adopter(task).adopt!(marker: Hive::Markers.current(task.state_file)), label
        assert_equal before, review_files(task), label
      end

      # A real base merge still fails closed when the grant evidence changed
      # beside the head: nothing retires before the grant validates.
      git(task, "reset", "--hard", "--quiet", approved)
      merge_task_base(task)
      mark_task_base_conflict(task, blocked: approved)
      File.open(File.join(task.reviews_dir, "codex-04.md"), "a") { |file| file.puts "- [x] Rewritten finding" }
      edited = review_files(task)
      refused = assert_raises(Hive::ReviewBudget::Refused) { adopter(task).adopt!(marker: Hive::Markers.current(task.state_file)) }
      assert_includes refused.message, "codex-04.md"
      assert_equal edited, review_files(task)
      assert_empty Dir[File.join(task.reviews_dir, "archive", "*")]
      assert Hive::ReviewBudget.new(task: task, project: task.project_name).present?
    end
  end

  def test_dirty_worktree_blocks_with_the_exact_operator_action_then_adopts
    with_base_merge_grant_task do |task, approved|
      merged = merge_task_base(task)
      mark_task_base_conflict(task, blocked: approved)
      File.write(File.join(task.worktree_path, "scratch.txt"), "operator scratch\n")
      before = review_files(task)

      dirty, = resume_recovery(task)

      assert_equal "blocked", dirty.status
      assert_equal "review_base_merge_refused", dirty.reason
      assert_equal "operator", dirty.owner
      assert_includes dirty.remediation, "dirty_worktree"
      assert_includes dirty.remediation, "status"
      assert_equal before, review_files(task)
      assert_equal merged, git_head(task)

      File.delete(File.join(task.worktree_path, "scratch.txt"))
      receipt = adopter(task).adopt!(marker: Hive::Markers.current(task.state_file))
      assert_equal merged, receipt.fetch("after_oid")
      assert_empty live_review_state(task)
    end
  end

  def test_only_a_granted_base_conflict_with_a_merged_blocked_head_is_adopted
    with_base_merge_grant_task(grant: false) do |task, approved|
      merge_task_base(task)
      mark_task_base_conflict(task, blocked: approved)
      before = review_files(task)
      assert_nil adopter(task).adopt!(marker: Hive::Markers.current(task.state_file)),
                 "without a grant the ordinary retry already re-runs CI and review"
      assert_equal before, review_files(task)
    end

    with_base_merge_grant_task do |task, approved|
      before = review_files(task)
      marker = -> { Hive::Markers.current(task.state_file) }
      mark_task_base_conflict(task, blocked: approved)
      assert_nil adopter(task).adopt!(marker: marker.call), "nothing merged yet: the grant is still current"

      merge_task_base(task)
      Hive::Markers.set(task.state_file, :review_ci_stale, gate: "github", attempts: 2, pass: 1)
      assert_nil adopter(task).adopt!(marker: marker.call), "red CI is not a base conflict"
      Hive::Markers.set(task.state_file, :review_ci_stale, gate: "github", reason: "mergeability_unknown", pass: 1)
      assert_nil adopter(task).adopt!(marker: marker.call)
      Hive::Markers.set(task.state_file, :review_error, phase: "ci", reason: "base_conflict", pass: 1)
      assert_nil adopter(task).adopt!(marker: marker.call)
      Hive::Markers.set(task.state_file, :review_ci_stale, gate: "github", reason: "base_conflict", pass: 1)
      assert_nil adopter(task).adopt!(marker: marker.call), "no recorded blocked head"
      mark_task_base_conflict(task, blocked: "not-an-oid")
      assert_nil adopter(task).adopt!(marker: marker.call)

      mark_task_base_conflict(task, blocked: approved)
      with_replaced_singleton_method(Hive::Worktree, :read_owned_pointer, ->(*, **) { raise Hive::WorktreeError, "torn" }) do
        assert_nil adopter(task).adopt!(marker: marker.call), "an unowned worktree is never adopted"
      end
      failing = lambda do |failed|
        gate = Hive::AgentGitGate.dup
        gate.define_singleton_method(:read) do |path, operation, **params|
          next Hive::AgentGitGate::ReadResult.new(operation: operation, stdout: "", stderr: "", exitstatus: 128, overflow: false) if operation == failed

          Hive::AgentGitGate.read(path, operation, **params)
        end
        gate
      end
      %i[head_oid object_content branch_oid].each do |operation|
        assert_nil adopter(task, gate: failing.call(operation)).adopt!(marker: marker.call), operation.to_s
      end
      raising = Hive::AgentGitGate.dup
      raising.define_singleton_method(:read) { |*, **| raise Hive::AgentGitGate::InvalidRequest, "unsafe config" }
      unsafe = assert_raises(Adoption::Refused) { adopter(task, gate: raising).adopt!(marker: marker.call) }
      assert_equal "git_unavailable", unsafe.reason
      assert_equal before, review_files(task)
      assert_empty Dir[File.join(task.reviews_dir, "archive", "*")]
    end
  end

  # A grant whose slot was already spent still validates on the merged head,
  # so the existing verification path (guardrail over the merge, then a
  # verify-only review) keeps it: adoption never resets a spent grant.
  def test_a_spent_grant_keeps_the_ordinary_verification_path
    with_base_merge_grant_task do |task|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      input = budget.observe
      git(task, "commit", "--allow-empty", "-qm", "granted fix")
      fixed = git_head(task)
      budget.complete_fix!(snapshot: input, pass: 4, head: fixed)
      merge_task_base(task)
      mark_task_base_conflict(task, blocked: fixed)
      before = review_files(task)

      assert_nil adopter(task).adopt!(marker: Hive::Markers.current(task.state_file))
      result, = resume_recovery(task)

      assert_equal "cleared", result.phase, result.to_h.inspect
      assert_equal before, review_files(task)
      assert_equal 0, budget.observe.remaining
      assert_empty Dir[File.join(task.reviews_dir, "archive", "*")]
    end
  end

  # Pointers written before `base_branch` existed fall back only to the base
  # origin names, and adopt nothing when origin names none.
  def test_legacy_pointer_uses_only_the_origin_default_branch
    with_base_merge_grant_task(base_branch: nil) do |task, approved|
      merged = merge_task_base(task)
      mark_task_base_conflict(task, blocked: approved)
      tip = base_tip(task)
      run!("git", "-C", task.project_root, "update-ref", "-d", "refs/remotes/origin/master")
      assert_nil adopter(task).adopt!(marker: Hive::Markers.current(task.state_file))

      run!("git", "-C", task.project_root, "update-ref", "refs/remotes/origin/master", tip)
      receipt = adopter(task, activity: nil).adopt!(marker: Hive::Markers.current(task.state_file))
      assert_equal "master", receipt.fetch("base_branch")
      assert_equal merged, receipt.fetch("after_oid")
    end
  end

  private

  def adopter(task, gate: Hive::AgentGitGate, activity: :journal)
    return Adoption.new(task: task, gate: gate) if activity == :journal

    Adoption.new(task: task, gate: gate, activity: -> { activity })
  end

  def recovery_row(task)
    marker = Hive::Markers.current(task.state_file)
    { project: task.project_name, slug: task.slug, folder: task.folder,
      state_file: task.state_file, stage: "6-review", workflow: "coding",
      marker: marker.name.to_s, marker_attrs: marker.attrs,
      state_file_mtime: Time.now.utc - 3600, live_task_lock: false }
  end

  def coordinator_for(task)
    generation = Struct.new(:task_generation, :progress_token).new("a" * 64, "b" * 64)
    Hive::Daemon::RecoveryCoordinator.new(task_resolver: ->(**) { task },
      safety: ->(_) { [ true, "safe" ] }, generation_resolver: ->(*, **) { generation })
  end

  def resume_recovery(task, coordinator: coordinator_for(task))
    row = recovery_row(task)
    admitted = coordinator.request(row: row, requestor: "cli")
    assert_includes %w[queued blocked], admitted.status, admitted.to_h.inspect
    [ coordinator.resume(request: result_request(coordinator, admitted), row: row), coordinator ]
  end

  def result_request(coordinator, receipt)
    coordinator.instance_variable_get(:@request_queue).fetch(receipt.request_id)
  end

  def live_review_state(task)
    Dir.children(task.reviews_dir).select do |name|
      Hive::ReviewPass.number(name) || Hive::ReviewPass.budget_receipt?(name)
    end.sort
  end

  def review_files(task)
    Dir[File.join(task.folder, "reviews", "**", "*")].select { |path| File.file?(path) }.sort
      .to_h { |path| [ path, File.binread(path) ] }
  end

  def base_tip(task)
    git(task, "rev-parse", "refs/remotes/origin/master")
  end

  def git(task, *args)
    run!("git", "-C", task.worktree_path, *args).strip
  end

  def git_head(task)
    git(task, "rev-parse", "HEAD")
  end
end
