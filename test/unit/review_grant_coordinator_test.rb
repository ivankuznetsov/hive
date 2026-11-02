require "test_helper"
require "hive/daemon/recovery_coordinator"
require "hive/attempts/context"
require_relative "../support/review_grant_fixture"

class ReviewGrantCoordinatorTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  def test_stable_task_identity_is_rechecked_under_the_lock
    with_review_grant_task do |task, _cfg|
      changed = task.dup
      changed.define_singleton_method(:id) { "other-task" }
      coordinator = Hive::Daemon::RecoveryCoordinator.new(task_resolver: ->(**) { changed })
      before = task_bytes(task)
      error = assert_raises(Hive::ReviewBudget::Refused) { grant(task, coordinator: coordinator) }
      assert_equal "stale_evidence", error.reason
      assert_equal before, task_bytes(task)
    end
  end

  def test_live_task_lock_refuses_without_writing_a_decision
    with_review_grant_task do |task, _cfg|
      before = task_bytes(task)
      ready, release = Queue.new, Queue.new
      owner = Thread.new do
        Hive::Lock.with_task_lock(task.folder, create: false) do
          ready << true
          release.pop
        end
      end
      ready.pop
      assert_raises(Hive::ConcurrentRunError) { grant(task) }
      assert_equal before, task_bytes(task)
    ensure
      release << true
      owner.join
    end
  end

  def test_simultaneous_identical_operator_requests_allocate_one_receipt
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      start, outcomes = Queue.new, Queue.new
      workers = 2.times.map do
        Thread.new do
          start.pop
          begin
            outcomes << grant(task, token: token)
          rescue Hive::ConcurrentRunError => error
            outcomes << error
          end
        end
      end
      2.times { start << true }
      workers.each(&:join)
      results = 2.times.map { outcomes.pop }
      applied = results.grep(Hash)
      assert_equal 1, applied.count { |row| row.fetch("state") == "applied" }
      assert applied.all? { |row| %w[applied replayed].include?(row.fetch("state")) }
      assert_equal 1, budget.store.grants.length
      assert_equal 1, budget.observe.remaining
      assert_equal 1, File.readlines(budget.audit_path).length
      assert_equal :none, Hive::Markers.current(task.state_file).name
    end
  end

  def test_worktree_safety_is_required_even_with_a_fresh_valid_token
    with_review_grant_task do |task, _cfg|
      coordinator = Hive::Daemon::RecoveryCoordinator.new(safety: ->(row) {
        assert_equal "review_stale", row.marker
        assert_equal "final_fix_unverified", row.marker_attrs.fetch("reason")
        [ false, "Worktree belongs to a different task" ]
      })
      before = task_bytes(task)
      error = assert_raises(Hive::ReviewBudget::Refused) { grant(task, coordinator: coordinator) }
      assert_equal "unsafe_state", error.reason
      assert_includes error.message, "different task"
      assert_equal before, task_bytes(task)
    end
  end

  def test_operator_source_is_checked_again_after_resolving_the_locked_task
    with_review_grant_task do |task, _cfg|
      checks = 0
      authority = lambda do
        checks += 1
        raise Hive::AgentSupport::OperatorAuthority::Denied if checks == 2
        { "caller" => "uid:#{Process.uid}", "source" => "operator_cli" }
      end
      before = task_bytes(task)
      with_replaced_singleton_method(Hive::AgentSupport::OperatorAuthority, :assert_operator!, authority) do
        assert_raises(Hive::AgentSupport::OperatorAuthority::Denied) { grant(task) }
      end
      assert_equal 2, checks
      assert_equal before, task_bytes(task)
    end
  end

  def test_receipt_write_failure_leaves_marker_and_budget_unchanged
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      budget.store.define_singleton_method(:write_grant!) { |_receipt| raise IOError, "receipt fsync failed" }
      before = task_bytes(task)
      with_replaced_singleton_method(Hive::ReviewBudget, :new, ->(**) { budget }) do
        assert_raises(IOError) { grant(task, token: token) }
      end
      assert_equal before, task_bytes(task)
    end
  end

  def test_failure_after_audit_before_marker_clear_replays_one_decision
    with_review_grant_task do |task, _cfg|
      token = Hive::ReviewBudget.new(task: task, project: task.project_name).observe.evidence_token
      coordinator = Hive::Daemon::RecoveryCoordinator.new
      coordinator.define_singleton_method(:clear_recoverable_marker) { |*_, **| raise IOError, "lost after audit fsync" }
      assert_raises(IOError) { grant(task, token: token, coordinator: coordinator) }
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      assert_equal "pending", budget.observe.state
      assert_equal 1, File.readlines(budget.audit_path).length
      decision_bytes = File.binread(Dir[File.join(task.folder, "reviews", "review-grant-*.json")].fetch(0))
      replayed = grant(task, token: token)
      assert_equal "replayed", replayed.fetch("state")
      assert_equal 1, budget.observe.remaining
      assert_equal 1, File.readlines(budget.audit_path).length
      assert_equal decision_bytes, File.binread(Dir[File.join(task.folder, "reviews", "review-grant-*.json")].fetch(0))
    end
  end

  def test_failure_after_marker_clear_replays_without_another_allocation
    with_review_grant_task do |task, _cfg|
      token = Hive::ReviewBudget.new(task: task, project: task.project_name).observe.evidence_token
      coordinator = Hive::Daemon::RecoveryCoordinator.new
      coordinator.define_singleton_method(:review_grant_result) { |*_, **| raise IOError, "lost response" }
      assert_raises(IOError) { grant(task, token: token, coordinator: coordinator) }
      assert_equal :none, Hive::Markers.current(task.state_file).name
      before = task_bytes(task)
      result = grant(task, token: token)
      assert_equal "replayed", result.fetch("state")
      assert_equal before, task_bytes(task)
    end
  end

  def test_exact_marker_guard_refuses_a_race_after_pending_evidence_was_validated
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      receipt = budget.record_grant!(snapshot: budget.observe, passes: 1,
        reason: "Finish accepted fixes", caller: "operator", source: "operator_cli")
      original = budget.method(:application_state)
      budget.define_singleton_method(:application_state) do |current|
        state = original.call(current)
        Hive::Markers.set(task.state_file, :review_stale,
          reason: "wall_clock", pass: 4, accepted: 1, escalations: 0)
        state
      end
      error = nil
      Hive::Lock.with_task_lock(task.folder, create: false) do
        error = assert_raises(Hive::ReviewBudget::Refused) do
          Hive::Daemon::RecoveryCoordinator.new.send(:apply_review_grant!, task, budget, receipt)
        end
      end
      assert_equal "stale_evidence", error.reason
      assert_equal "wall_clock", Hive::Markers.current(task.state_file).attrs.fetch("reason")
      assert_equal 1, budget.store.grants.length
    end
  end

  def test_failed_exact_marker_clear_cannot_be_reported_as_applied
    with_review_grant_task do |task, _cfg|
      coordinator = Hive::Daemon::RecoveryCoordinator.new
      coordinator.define_singleton_method(:clear_recoverable_marker) { |*_, **| false }
      error = assert_raises(Hive::ReviewBudget::Refused) { grant(task, coordinator: coordinator) }
      assert_equal "stale_evidence", error.reason
      assert_equal :review_stale, Hive::Markers.current(task.state_file).name
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      assert_equal "pending", budget.observe.state
      assert_equal 1, budget.store.grants.length
    end
  end

  def test_obsolete_replay_returns_its_historical_decision_without_clearing_completion
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      applied = grant(task, token: token)
      Hive::Markers.set(task.state_file, :review_complete, pass: 5, browser: "skipped")
      before = task_bytes(task)
      replay = grant(task, token: token)
      assert_equal "replayed", replay.fetch("state")
      assert_equal applied.fetch("decision_id"), replay.fetch("decision_id")
      assert_equal before, task_bytes(task)
      assert_equal 0, budget.observe.remaining
      assert_equal "completed", budget.observe.state
    end
  end

  def test_spent_decision_replay_preserves_fresh_exhaustion_and_its_new_token
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      old_token = budget.observe.evidence_token
      applied = grant(task, token: old_token)
      fixing = budget.observe
      head = fixing.evidence.fetch("head")
      Hive::Lock.with_task_lock(task.folder, create: false) do
        budget.complete_fix!(snapshot: fixing, pass: 4, head: head)
      end
      File.write(File.join(task.folder, "reviews", "fix-success-04.md"), "<!-- HIVE: head=#{head} kind=fixed -->\n")
      File.write(File.join(task.folder, "reviews", "codex-05.md"), "- [x] Fresh verification finding\n")
      File.write(File.join(task.folder, "reviews", "escalations-05.md"), "# Escalations\n")
      Hive::Markers.set(task.state_file, :review_stale,
        reason: "final_fix_unverified", pass: 5, accepted: 1, escalations: 0)
      fresh = budget.observe
      assert_equal "eligible", fresh.state, fresh.remediation
      refute_equal old_token, fresh.evidence_token
      before = task_bytes(task)
      replay = grant(task, token: old_token)
      assert_equal "replayed", replay.fetch("state")
      assert_equal applied.fetch("decision_id"), replay.fetch("decision_id")
      assert_equal before, task_bytes(task)
      assert_equal fresh.evidence_token, budget.observe.evidence_token
      assert_equal 1, budget.store.grants.length
      assert_equal 1, budget.observe.spent
      assert_equal 0, budget.observe.remaining
    end
  end

  def test_changed_reason_conflicts_without_touching_the_existing_decision
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      grant(task, token: token)
      before = task_bytes(task)
      error = assert_raises(Hive::ReviewBudget::Refused) { grant(task, token: token, reason: "A different decision") }
      assert_equal "decision_conflict", error.reason
      assert_equal before, task_bytes(task)
    end
  end

  def test_archived_replay_preserves_an_eligible_or_active_new_review
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      applied = grant(task, token: token)
      budget.record_expiry!(reason: "review_reset")
      archive = File.join(task.reviews_dir, "archive", "rework-01")
      FileUtils.mkdir_p(archive)
      Dir[File.join(task.reviews_dir, "*")].select { |path| File.file?(path) }.each { |path| FileUtils.mv(path, archive) }
      # A reset review has new controller completion bytes and hence a new scope.
      Dir[File.join(archive, "*.md")].each { |path| FileUtils.cp(path, task.reviews_dir) }
      File.open(File.join(task.reviews_dir, "fix-success-01.md"), "a") { |file| file.puts "new review scope" }
      Hive::Markers.set(task.state_file, :review_stale,
        reason: "final_fix_unverified", pass: 4, accepted: 1, escalations: 0)

      [ "eligible", "applied" ].each do |state|
        fresh = budget.observe
        assert_equal state, fresh.state, fresh.remediation
        before = task_bytes(task)
        replay = grant(task, token: token)
        assert_equal "replayed", replay.fetch("state")
        assert_equal applied.fetch("decision_id"), replay.fetch("decision_id")
        assert_equal "historical", budget.application_state(budget.replay(evidence_token: token, passes: 1, reason: "Finish accepted fixes"))
        assert_equal before, task_bytes(task)
        assert_equal fresh, budget.observe
        grant(task, token: fresh.evidence_token) if state == "eligible"
      end
      assert_equal 1, budget.store.grants.length
      assert_equal 1, budget.observe.remaining
    end
  end

  def test_nonfinal_park_remains_suspended_when_daemon_reconciles_budget
    with_review_grant_task do |task, _cfg|
      grant(task, passes: 3)
      Hive::Markers.set(task.state_file, :review_ci_stale, pass: 4, attempts: 3)
      before = task_bytes(task)
      Hive::Lock.with_task_lock(task.folder, create: false) do
        snapshot = Hive::Daemon::RecoveryCoordinator.new.reconcile_review_grant!(task: task, project: task.project_name)
        assert_equal "suspended", snapshot.state
        assert_equal 3, snapshot.remaining
        assert_equal "review_ci_stale", snapshot.blocking_marker.fetch("name")
      end
      assert_equal before, task_bytes(task)
    end
  end

  def test_authenticated_recovery_request_preserves_partial_fix_proof_once_before_observing
    with_partial_fix do |task, budget, receipt, proof|
      context, attempt, request = recovery_binding(task, proof)
      coordinator = bound_coordinator(task, context, attempt, request)
      assert_equal "refused", budget.observe.state, "A changed HEAD needs the canonical recovery proof"
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        Hive::Lock.with_task_lock(task.folder, create: false) do
          first = coordinator.reconcile_review_grant!(task: task, project: task.project_name)
          assert_equal "applied", first.state, first.remediation
          assert_equal receipt.fetch("decision_id"), first.decision_id
          assert_equal 1, first.remaining
          before = task_bytes(task)
          second = coordinator.reconcile_review_grant!(task: task, project: task.project_name)
          assert_equal "applied", second.state
          assert_equal before, task_bytes(task)
        end
      end
      records = Hive::TaskProjection::Reader.new(task_folder: task.folder, task: task).read_bounded.journal_records
      resumes = records.select { |entry| entry.dig("payload", "activity_kind") == "recovery_recorded" }
      assert_equal 1, resumes.length
      assert_equal proof, resumes.first.dig("payload", "review_grant_resume")
      assert_equal "recovery_service", resumes.first.dig("provenance", "source")
      assert_equal 1, budget.observe.remaining
      assert budget.validate_resume!
    end
  end

  def test_unrelated_context_or_request_never_rebinds_the_partial_fix_head
    with_partial_fix do |task, budget, _receipt, proof|
      context, attempt, request = recovery_binding(task, proof)
      candidates = [
        [ nil, attempt, request ],
        [ context.dup.tap { |value| value.instance_variable_set(:@project, "other-project") }, attempt, request ],
        [ context.dup.tap { |value| value.instance_variable_set(:@task_slug, "other-task") }, attempt, request ],
        [ context, nil, request ],
        [ context, attempt, nil ],
        [ context, attempt, request.with(task_id: "other-task") ],
        [ context, attempt, request.with(expected_stage: "4-execute") ],
        [ context, attempt, request.with(recovery: {}) ],
        [ context, attempt, request.with(recovery: { "expected_marker_attrs" => "invalid" }) ],
        [ context, attempt, request.with(recovery: { "expected_marker_attrs" => proof.merge("grant_decision" => "0" * 64) }) ]
      ]
      before = task_bytes(task)
      candidates.each do |current, admitted, canonical|
        coordinator = bound_coordinator(task, context, admitted, canonical)
        with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { current }) do
          Hive::Lock.with_task_lock(task.folder, create: false) do
            snapshot = coordinator.reconcile_review_grant!(task: task, project: task.project_name)
            assert_equal "refused", snapshot.state
          end
        end
        assert_equal before, task_bytes(task)
      end
      assert_equal 0, budget.observe.remaining
    end
  end

  def test_recovery_proof_with_wrong_slot_head_input_or_phase_cannot_authorize_resume
    with_partial_fix do |task, _budget, _receipt, proof|
      invalid = [
        proof.merge("grant_slot" => "2"), proof.merge("head" => "0" * 40),
        proof.merge("input_head" => "0" * 40), proof.merge("pass" => "5"),
        proof.merge("phase" => "triage"), proof.merge("input_artifacts_digest" => "0" * 64)
      ]
      before = task_bytes(task)
      invalid.each do |changed|
        context, attempt, request = recovery_binding(task, changed)
        coordinator = bound_coordinator(task, context, attempt, request)
        with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
          Hive::Lock.with_task_lock(task.folder, create: false) do
            begin
              snapshot = coordinator.reconcile_review_grant!(task: task, project: task.project_name)
              assert_equal "refused", snapshot.state
            rescue Hive::ReviewBudget::Refused => error
              assert_equal "evidence_changed", error.reason
            end
          end
        end
        assert_equal before, task_bytes(task)
      end
    end
  end

  def test_stale_attempt_generation_cannot_write_recovery_proof
    with_partial_fix do |task, _budget, _receipt, proof|
      context, attempt, request = recovery_binding(task, proof)
      context.instance_variable_set(:@task_generation, 1)
      coordinator = bound_coordinator(task, context, attempt, request)
      before = task_bytes(task)
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        Hive::Lock.with_task_lock(task.folder, create: false) do
          error = assert_raises(Hive::TaskActivity::AppendFailed) do
            coordinator.reconcile_review_grant!(task: task, project: task.project_name)
          end
          assert_includes error.message, "task_generation"
        end
      end
      assert_equal before, task_bytes(task)
    end
  end

  def test_partial_fix_without_authoritative_activity_binding_refuses
    with_partial_fix do |task, _budget, _receipt, proof|
      context, attempt, request = recovery_binding(task, proof)
      coordinator = bound_coordinator(task, context, attempt, request)
      before = task_bytes(task)
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::TaskActivity, :for_context, ->(*, **) { nil }) do
          Hive::Lock.with_task_lock(task.folder, create: false) do
            error = assert_raises(Hive::ReviewBudget::Refused) do
              coordinator.reconcile_review_grant!(task: task, project: task.project_name)
            end
            assert_equal "invalid_task_history", error.reason
          end
        end
      end
      assert_equal before, task_bytes(task)
    end
  end

  def test_ordinary_recovery_retains_exact_controller_proof_before_marker_clear
    with_partial_fix do |task, budget, _receipt, proof|
      context, attempt, request = recovery_binding(task, proof)
      store = Object.new
      store.define_singleton_method(:fetch) { |id| id == context.attempt_id ? attempt : nil }
      activity = Hive::TaskActivity.for_context(task, context: context, attempt_store: store)
      Hive::Markers.set(task.state_file, :review_error, proof.merge("reason" => "fix_agent_failed"))
      marker = Hive::Markers.current(task.state_file)
      before = task_bytes(task)
      Hive::Lock.with_task_lock(task.folder, create: false) do
        Hive::Daemon::RecoveryCoordinator.new.send(:preserve_review_grant_resume!, task, marker, request)
      end
      assert_equal before, task_bytes(task), "Legacy recovery waits for the authenticated worker to retain proof"
      with_replaced_singleton_method(Hive::TaskActivity, :for_task, ->(*) { activity }) do
        Hive::Lock.with_task_lock(task.folder, create: false) do
          Hive::Daemon::RecoveryCoordinator.new.send(:preserve_review_grant_resume!, task, marker, request)
          assert Hive::Markers.clear_current(task.state_file, expected_name: :review_error, match_attrs: marker.attrs)
        end
      end
      snapshot = budget.observe
      assert_equal "applied", snapshot.state, snapshot.remediation
      assert_equal proof, snapshot.evidence.fetch("resume_evidence")
      assert_equal 1, snapshot.remaining
    end
  end

  def test_ordinary_recovery_validates_grant_even_without_a_durable_previous_attempt
    with_review_grant_task do |task, _cfg|
      grant(task)
      Hive::Markers.set(task.state_file, :review_error, pass: 4, phase: "review", reason: "reviewer_failed")
      request = recovery_request(task, {})
      marker = Hive::Markers.current(task.state_file)
      before = task_bytes(task)
      Hive::Lock.with_task_lock(task.folder, create: false) do
        Hive::Daemon::RecoveryCoordinator.new.send(:preserve_review_grant_resume!, task, marker, request)
      end
      assert_equal before, task_bytes(task)
      File.open(File.join(task.folder, "reviews", "codex-04.md"), "a") { |file| file.puts "Changed accepted finding" }
      before = task_bytes(task)
      Hive::Lock.with_task_lock(task.folder, create: false) do
        assert_raises(Hive::ReviewBudget::Refused) do
          Hive::Daemon::RecoveryCoordinator.new.send(:preserve_review_grant_resume!, task, marker, request)
        end
      end
      assert_equal before, task_bytes(task)
    end
  end

  def test_ordinary_recovery_does_not_clear_a_park_after_granted_findings_change
    with_review_grant_task do |task, _cfg|
      grant(task)
      Hive::Markers.set(task.state_file, :review_error, pass: 4, phase: "fix", reason: "fix_agent_failed")
      marker = Hive::Markers.current(task.state_file)
      row = { project: task.project_name, slug: task.slug, folder: task.folder,
        state_file: task.state_file, stage: "6-review", workflow: "coding",
        marker: marker.name.to_s, marker_attrs: marker.attrs,
        state_file_mtime: Time.now.utc - 3600, live_task_lock: false }
      generation = Struct.new(:task_generation, :progress_token).new("a" * 64, "b" * 64)
      coordinator = Hive::Daemon::RecoveryCoordinator.new(task_resolver: ->(**) { task },
        safety: ->(_) { [ true, "safe" ] }, generation_resolver: ->(*, **) { generation })
      admitted = coordinator.request(row: row, requestor: "cli")
      assert_equal "queued", admitted.status, admitted.to_h.inspect
      queue = coordinator.instance_variable_get(:@request_queue)
      request = queue.fetch(admitted.request_id)
      File.open(File.join(task.folder, "reviews", "codex-04.md"), "a") { |file| file.puts "Changed accepted finding" }
      before = task_bytes(task)
      result = coordinator.resume(request: request, row: row)
      assert_equal "blocked", result.status, result.to_h.inspect
      assert_equal "review_grant_evidence_changed", result.reason
      assert_equal "operator", result.owner
      assert_includes result.remediation, "codex-04.md"
      assert_equal before, task_bytes(task)
      assert_equal marker.raw, Hive::Markers.current(task.state_file).raw
    end
  end

  private

  def with_partial_fix
    with_review_grant_task do |task, _cfg|
      result = grant(task)
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      before = budget.observe
      run!("git", "-C", task.worktree_path, "commit", "--quiet", "--allow-empty", "-m", "Incomplete accepted fix")
      proof = {
        "grant_decision" => result.fetch("decision_id"), "grant_slot" => "1",
        "input_head" => before.evidence.fetch("head"), "head" => Hive::Stages::Review.git_head(task.worktree_path),
        "input_artifacts_digest" => Hive::ReviewBudget.digest(before.evidence.fetch("artifacts")),
        "pass" => "4", "phase" => "fix"
      }
      yield task, budget, before.receipts.last, proof
    end
  end

  def recovery_binding(task, proof)
    context = Hive::Attempts::Context.send(:new, attempt_id: "recovery-attempt", task_generation: 0,
      ownership_generation: "recovery-owner", project: task.project_name,
      task_slug: task.slug, intended_stage: "6-review")
    attempt = { "request_id" => "recovery-request", "task_id" => task.id.to_s,
      "task_slug" => task.slug, "intended_stage" => "6-review", "task_input_epoch" => 0,
      "ownership_generation" => "recovery-owner" }
    [ context, attempt, recovery_request(task, proof) ]
  end

  def recovery_request(task, proof)
    Hive::RuntimeControlPlane::DispatchRepository::Request.new(
      request_id: "recovery-request", created_at: Time.now.utc.iso8601(6),
      project: task.project_name, slug: task.slug, argv: [ "hive", "run", task.slug ], requestor: "cli",
      task_id: task.id.to_s, expected_stage: "6-review", expected_marker_name: "review_error",
      recovery: { "expected_marker_attrs" => proof })
  end

  def bound_coordinator(task, context, attempt, request)
    store = Object.new
    store.define_singleton_method(:fetch) { |id| id == context.attempt_id ? attempt : nil }
    queue = Object.new
    queue.define_singleton_method(:fetch) { |id| id == "recovery-request" ? request : nil }
    Hive::Daemon::RecoveryCoordinator.new(attempt_store: store, dispatch_repository: queue)
  end

  def grant(task, token: nil, passes: 1, reason: "Finish accepted fixes", coordinator: Hive::Daemon::RecoveryCoordinator.new)
    token ||= Hive::ReviewBudget.new(task: task, project: task.project_name).observe.evidence_token
    coordinator.grant_review!(task: task, project: task.project_name,
      passes: passes, reason: reason, evidence_token: token)
  end

  def task_bytes(task)
    paths = [ task.state_file, File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME), *Dir[File.join(task.folder, "reviews", "*")],
      *Dir[File.join(task.folder, "review-budget", "*")] ]
    paths.select { |path| File.file?(path) }.sort.to_h { |path| [ path, File.binread(path) ] }
  end
end
