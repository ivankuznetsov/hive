require "test_helper"
require "hive/daemon/recovery_coordinator"
require "hive/review_fast_forward_adoption"
require_relative "../support/review_grant_fixture"

class ReviewFastForwardAdoptionTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  PR_URL = "https://github.com/acme/app/pull/42".freeze
  Adoption = Hive::ReviewFastForwardAdoption

  # End to end through the recovery coordinator with real repositories: the
  # operator fast-forwarded the published PR branch while a review grant was
  # suspended behind a publication failure (the hivedev F4 wedge).
  def test_routine_retry_adopts_a_remote_fast_forward_and_starts_a_new_review_generation
    with_adoption_fixture do |task, bare, reviewed, ahead|
      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead)
      result, coordinator = resume_recovery(task, bare)

      assert_equal "queued", result.status, result.to_h.inspect
      assert_equal "cleared", result.phase
      assert_equal ahead, git_head(task), "the clean owned worktree fast-forwards to the exact PR head"
      assert_empty git(task, "status", "--porcelain")
      assert_equal :none, Hive::Markers.current(task.state_file).name

      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      refute budget.present?, "the grant bound to the old head ends instead of wedging the retry"
      audit = File.readlines(budget.audit_path).map { |line| JSON.parse(line) }
      assert_equal [ "remote_fast_forward_adopted" ], audit.select { |entry| entry["event"] == "expiry" }.map { |entry| entry["expiry_reason"] }
      assert_empty Dir.children(task.reviews_dir).select { |name| Hive::ReviewPass.number(name) || Hive::ReviewPass.budget_receipt?(name) },
                   "the next review starts at pass 1 instead of reusing findings bound to the old head"
      assert_equal 0, Hive::Stages::Review.max_review_pass(task.folder)

      archive = Dir[File.join(task.reviews_dir, "archive", "*-remote-fast-forward-*")].fetch(0)
      receipt = JSON.parse(File.read(File.join(archive, "retirement.json")))
      assert_equal({ "schema" => "hive.review-generation-retirement", "schema_version" => 1,
                     "expiry_reason" => "remote_fast_forward_adopted", "before_oid" => reviewed,
                     "after_oid" => ahead, "branch" => task.slug, "pr_url" => PR_URL }, receipt)
      assert File.file?(File.join(archive, "codex-04.md"))
      refute_empty Dir[File.join(archive, "review-grant-*.json")]

      again = coordinator.resume(request: result_request(coordinator, result), row: recovery_row(task))
      assert_equal "cleared", again.phase, "a replayed transition never adopts twice"
      assert_equal ahead, git_head(task)
    end
  end

  def test_true_divergence_keeps_the_previous_refusal_and_never_moves_the_worktree
    with_adoption_fixture do |task, bare, reviewed, ahead|
      git(task, "commit", "--allow-empty", "-qm", "local-only fix")
      local = git_head(task)
      mark_publication_failure(task, reviewed: local, remote_head: ahead)
      before = review_files(task)

      result, = resume_recovery(task, bare)

      assert_equal "blocked", result.status
      assert_equal "review_grant_evidence_changed", result.reason, "divergence keeps today's outcome"
      assert_equal local, git_head(task)
      assert_equal before, review_files(task)
      refute_equal reviewed, local
    end
  end

  def test_dirty_worktree_and_unreachable_pr_head_block_with_the_exact_operator_action
    with_adoption_fixture do |task, bare, reviewed, ahead|
      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead, failure: "remote_fast_forward_adoptable")
      File.write(File.join(task.worktree_path, "scratch.txt"), "operator scratch\n")
      before = review_files(task)

      dirty, = resume_recovery(task, bare)

      assert_equal "blocked", dirty.status
      assert_equal "remote_fast_forward_refused", dirty.reason
      assert_equal "operator", dirty.owner
      assert_includes dirty.remediation, "dirty_worktree"
      assert_includes dirty.remediation, "status"
      assert_equal reviewed, git_head(task)
      assert_equal before, review_files(task)
      File.delete(File.join(task.worktree_path, "scratch.txt"))

      Dir.mktmpdir("adoption-clone") do |clone_root|
        clone = File.join(clone_root, "clone")
        run!("git", "clone", "--quiet", "--branch", task.slug, bare, clone)
        run!("git", "-C", clone, "-c", "user.email=o@example.com", "-c", "user.name=Operator",
          "commit", "--allow-empty", "-qm", "pushed from another machine")
        run!("git", "-C", clone, "push", "--quiet", "origin", "HEAD:refs/heads/#{task.slug}")
      end
      unreachable, = resume_recovery(task, bare)

      assert_equal "blocked", unreachable.status
      assert_includes unreachable.remediation, "remote_object_unavailable"
      assert_includes unreachable.remediation, "fetch origin #{task.slug}"
      assert_equal reviewed, git_head(task)
      assert_equal before, review_files(task)
    end
  end

  def test_only_review_publication_failures_with_fast_forward_reasons_are_candidates
    with_adoption_fixture(grant: false) do |task, bare, reviewed, ahead|
      adopter = adopter(task, bare)
      Hive::Markers.set(task.state_file, :review_error, reason: "fix_agent_failed", pass: 4)
      assert_nil adopter.adopt!(marker: Hive::Markers.current(task.state_file))
      Hive::Markers.set(task.state_file, :review_error, reason: "review_publication_failed",
        publication_reason: "publication_failed", pass: 4)
      assert_nil adopter.adopt!(marker: Hive::Markers.current(task.state_file))

      mark_publication_failure(task, reviewed: "not-an-oid", remote_head: ahead)
      assert_nil adopter.adopt!(marker: Hive::Markers.current(task.state_file))
      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead, pr_url: "https://github.com/acme/app/issues/42")
      assert_nil adopter.adopt!(marker: Hive::Markers.current(task.state_file))
      assert_equal reviewed, git_head(task)
    end
  end

  def test_nothing_to_adopt_returns_to_the_ordinary_retry_path
    with_adoption_fixture(grant: false) do |task, bare, reviewed, ahead|
      # The worktree moved somewhere that does not extend the reviewed head.
      other = git(task, "commit-tree", "-m", "unrelated", "#{reviewed}^{tree}")
      mark_publication_failure(task, reviewed: other, remote_head: ahead)
      assert_nil adopter(task, bare).adopt!(marker: Hive::Markers.current(task.state_file))

      # The PR names the reviewed head again.
      run!("git", "-C", task.worktree_path, "push", "--quiet", "--force", bare, "#{reviewed}:refs/heads/#{task.slug}")
      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead)
      assert_nil adopter(task, bare).adopt!(marker: Hive::Markers.current(task.state_file))

      # The PR branch was deleted.
      run!("git", "-C", task.worktree_path, "push", "--quiet", bare, ":refs/heads/#{task.slug}")
      assert_nil adopter(task, bare).adopt!(marker: Hive::Markers.current(task.state_file))
      assert_equal reviewed, git_head(task)
      assert_empty Dir[File.join(task.reviews_dir, "archive", "*")]
    end
  end

  def test_interrupted_adoption_is_completed_without_another_merge_and_records_activity
    with_adoption_fixture do |task, bare, reviewed, ahead|
      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead)
      git(task, "merge", "--ff-only", "--quiet", ahead)
      records = []
      activity = Object.new
      activity.define_singleton_method(:record) { |**kwargs| records << kwargs }
      gate = Hive::AgentGitGate.dup
      gate.define_singleton_method(:fast_forward) { |**| raise "an adopted head is never merged again" }
      adopter = Adoption.new(task: task, gate: gate, remote_target: ->(*) { bare },
        allow_local_transport: true, activity: -> { activity })

      receipt = adopter.adopt!(marker: Hive::Markers.current(task.state_file))
      replay = adopter.adopt!(marker: Hive::Markers.current(task.state_file))

      assert_equal reviewed, receipt.fetch("before_oid")
      assert_equal ahead, receipt.fetch("after_oid")
      assert_equal receipt, replay, "a replay reuses the same archive and receipt"
      assert_equal 1, Dir[File.join(task.reviews_dir, "archive", "*-remote-fast-forward-*")].size
      assert_equal [ "recovery_recorded" ], records.map { |entry| entry.fetch(:kind) }.uniq
      assert_equal "review-remote-fast-forward:#{reviewed}:#{ahead}", records.first.fetch(:operation_id)
      assert_equal receipt, records.first.fetch(:payload).fetch("adopted_remote_fast_forward")

      File.write(File.join(task.worktree_path, "scratch.txt"), "x\n")
      dirty = assert_raises(Adoption::Refused) { adopter.adopt!(marker: Hive::Markers.current(task.state_file)) }
      assert_equal "dirty_worktree", dirty.reason
    end
  end

  def test_identity_and_observation_failures_refuse_with_an_owner
    with_adoption_fixture(grant: false) do |task, bare, reviewed, ahead|
      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead, branch: "other-branch")
      marker = -> { Hive::Markers.current(task.state_file) }
      moved = assert_raises(Adoption::Refused) { adopter(task, bare).adopt!(marker: marker.call) }
      assert_equal "publication_identity_changed", moved.reason

      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead)
      with_replaced_singleton_method(Hive::Worktree, :read_owned_pointer, ->(*, **) { raise Hive::WorktreeError, "torn" }) do
        missing = assert_raises(Adoption::Refused) { adopter(task, bare).adopt!(marker: marker.call) }
        assert_equal "worktree_unavailable", missing.reason
      end

      unreadable = Hive::AgentGitGate.dup
      unreadable.define_singleton_method(:read) do |path, operation, **params|
        next Hive::AgentGitGate::ReadResult.new(operation: operation, stdout: "", stderr: "", exitstatus: 128, overflow: false) if operation == :head_oid

        Hive::AgentGitGate.read(path, operation, **params)
      end
      head = assert_raises(Adoption::Refused) { adopter(task, bare, gate: unreadable).adopt!(marker: marker.call) }
      assert_equal "worktree_unavailable", head.reason

      unobservable = assert_raises(Adoption::Refused) do
        adopter(task, File.join(bare, "missing.git")).adopt!(marker: marker.call)
      end
      assert_equal "remote_observation_unavailable", unobservable.reason
      assert_equal "hive", unobservable.owner

      foreign = ->(*, **) { "https://github.com/someone/else.git" }
      with_replaced_singleton_method(Hive::Gh, :origin_push_url, foreign) do
        identity = assert_raises(Adoption::Refused) { Adoption.new(task: task).adopt!(marker: marker.call) }
        assert_equal "publication_identity_changed", identity.reason
      end
      with_replaced_singleton_method(Hive::Gh, :origin_push_url, ->(*, **) { raise Hive::GhError, "no origin" }) do
        unresolved = assert_raises(Adoption::Refused) { Adoption.new(task: task).adopt!(marker: marker.call) }
        assert_equal "remote_unavailable", unresolved.reason
        assert_equal "hive", unresolved.owner
      end
      own = ->(*, **) { "https://github.com/acme/app.git" }
      observed = []
      gate = Hive::AgentGitGate.dup
      gate.define_singleton_method(:observe_remote_branch) do |**kwargs|
        observed << kwargs.fetch(:remote)
        raise Hive::AgentGitGate::CommandFailed, "offline"
      end
      with_replaced_singleton_method(Hive::Gh, :origin_push_url, own) do
        assert_raises(Adoption::Refused) { Adoption.new(task: task, gate: gate).adopt!(marker: marker.call) }
      end
      assert_equal [ "https://github.com/acme/app.git" ], observed
      assert_equal reviewed, git_head(task)
    end
  end

  def test_races_inside_the_gate_and_invalid_budget_evidence_refuse_before_retirement
    with_adoption_fixture do |task, bare, reviewed, ahead|
      mark_publication_failure(task, reviewed: reviewed, remote_head: ahead)
      marker = Hive::Markers.current(task.state_file)
      {
        Hive::AgentGitGate::RemoteConflict.new("remote branch moved after observation") => [ "remote_moved", "hive" ],
        Hive::AgentGitGate::FastForwardRefused.new(:dirty_worktree, "raced") => [ "dirty_worktree", "operator" ],
        Hive::AgentGitGate::FastForwardRefused.new(:local_head_moved, "raced") => [ "local_head_moved", "operator" ],
        Hive::AgentGitGate::CommandFailed.new("exact fast-forward failed") => [ "git_unavailable", "operator" ]
      }.each do |error, (reason, owner)|
        gate = Hive::AgentGitGate.dup
        gate.define_singleton_method(:fast_forward) { |**| raise error }
        refused = assert_raises(Adoption::Refused) { adopter(task, bare, gate: gate).adopt!(marker: marker) }
        assert_equal reason, refused.reason
        assert_equal owner, refused.owner
      end

      grant_path = Dir[File.join(task.reviews_dir, "review-grant-*.json")].fetch(0)
      File.chmod(0o644, grant_path)
      assert_raises(Hive::ReviewBudget::Refused) { adopter(task, bare).adopt!(marker: marker) }
      assert_equal reviewed, git_head(task)
      assert_empty Dir[File.join(task.reviews_dir, "archive", "*")]
    end
  end

  def test_retirement_without_review_state_or_a_receipt_is_a_no_op
    with_tmp_dir do |folder|
      task = Struct.new(:folder, :project_name).new(folder, "demo")
      assert_nil Hive::Stages::Review::PassArchive.retire!(task, label: "x", expiry_reason: "review_reset")
      FileUtils.mkdir_p(File.join(folder, "reviews", "archive", "broken"))
      File.write(File.join(folder, "reviews", "archive", "broken", "retirement.json"), "{torn")
      FileUtils.mkdir_p(File.join(folder, "reviews", "archive", "earlier"))
      assert_nil Hive::Stages::Review::PassArchive.retire!(task, label: "x", expiry_reason: "review_reset")
      created = Hive::Stages::Review::PassArchive.retire!(task, label: "x", expiry_reason: "review_reset",
        receipt: { "after_oid" => "a" * 40 })
      assert_equal "reviews/archive/x", created
      assert_equal created, Hive::Stages::Review::PassArchive.retire!(task, label: "y",
        expiry_reason: "review_reset", receipt: { "after_oid" => "a" * 40 })
    end
  end

  private

  def with_adoption_fixture(grant: true)
    with_review_grant_task do |task, _cfg|
      grant_fix_pass(task) if grant
      Dir.mktmpdir("adoption-remote") do |remote_root|
        bare = File.join(remote_root, "app.git")
        run!("git", "init", "--bare", "--quiet", bare)
        run!("git", "-C", task.project_root, "remote", "add", "origin", bare)
        reviewed = git_head(task)
        git(task, "push", "--quiet", "origin", "HEAD:refs/heads/#{task.slug}")
        git(task, "commit", "--allow-empty", "-qm", "operator change pushed outside Hive")
        ahead = git_head(task)
        git(task, "push", "--quiet", "origin", "HEAD:refs/heads/#{task.slug}")
        git(task, "reset", "--hard", "--quiet", reviewed)
        yield task, bare, reviewed, ahead
      end
    end
  end

  def grant_fix_pass(task)
    token = Hive::ReviewBudget.new(task: task, project: task.project_name).observe.evidence_token
    Hive::Daemon::RecoveryCoordinator.new.grant_review!(task: task, project: task.project_name,
      passes: 1, reason: "Review the operator's follow-up", evidence_token: token)
  end

  def mark_publication_failure(task, reviewed:, remote_head:, failure: "remote_conflict",
                               branch: task.slug, pr_url: PR_URL)
    evidence = { "worktree" => task.worktree_path, "branch" => branch, "pr_url" => pr_url,
      "publication" => "unknown", "verification" => "pending", "local_head" => reviewed,
      "remote_head" => remote_head, "classification" => failure == "remote_conflict" ? "divergent" : "behind",
      "unpushed_shas" => [], "failure_reason" => failure }
    Hive::Markers.set(task.state_file, :review_error, phase: "ci", reason: "review_publication_failed",
      publication_reason: failure, pass: 4, **Hive::ReviewPublicationRecovery.encode(evidence))
  end

  def adopter(task, bare, gate: Hive::AgentGitGate)
    Adoption.new(task: task, gate: gate, remote_target: ->(*) { bare }, allow_local_transport: true)
  end

  def recovery_row(task)
    marker = Hive::Markers.current(task.state_file)
    { project: task.project_name, slug: task.slug, folder: task.folder,
      state_file: task.state_file, stage: "6-review", workflow: "coding",
      marker: marker.name.to_s, marker_attrs: marker.attrs,
      state_file_mtime: Time.now.utc - 3600, live_task_lock: false }
  end

  def resume_recovery(task, bare)
    row = recovery_row(task)
    generation = Struct.new(:task_generation, :progress_token).new("a" * 64, "b" * 64)
    coordinator = Hive::Daemon::RecoveryCoordinator.new(task_resolver: ->(**) { task },
      safety: ->(_) { [ true, "safe" ] }, generation_resolver: ->(*, **) { generation },
      review_fast_forward_adoption: ->(locked) { adopter(locked, bare) })
    admitted = coordinator.request(row: row, requestor: "cli")
    assert_includes %w[queued blocked], admitted.status, admitted.to_h.inspect
    [ coordinator.resume(request: result_request(coordinator, admitted), row: row), coordinator ]
  end

  def result_request(coordinator, receipt)
    coordinator.instance_variable_get(:@request_queue).fetch(receipt.request_id)
  end

  def review_files(task)
    Dir[File.join(task.folder, "reviews", "**", "*")].select { |path| File.file?(path) }.sort
  end

  def git(task, *args)
    run!("git", "-C", task.worktree_path, *args).strip
  end

  def git_head(task)
    git(task, "rev-parse", "HEAD")
  end
end
