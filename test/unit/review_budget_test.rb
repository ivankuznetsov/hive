require "test_helper"
require "hive/review_budget"

class ReviewBudgetTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :id, :slug, :stage_name, :state_file, :worktree_path, :project_root, keyword_init: true)
  HEAD = "a" * 40
  NOW = Time.utc(2026, 10, 30, 12)

  def test_legacy_final_fix_has_fresh_evidence_without_scheduler_observation_or_writes
    with_fixture do |budget, task|
      before = tree_bytes(task.folder)
      snapshot = budget.observe
      assert_equal "eligible", snapshot.state
      assert_equal 4, snapshot.exhausted_pass
      assert_match(/\A[0-9a-f]{64}\z/, snapshot.evidence_token)
      assert_equal snapshot.evidence_token, budget.observe.evidence_token
      assert_equal before, tree_bytes(task.folder)
      refute File.exist?(File.join(task.folder, "review-budget"))
    end
  end

  def test_eligibility_counts_only_runner_accepted_reviewer_and_legacy_escalation_lines
    with_fixture do |budget, task|
      excluded = <<~MARKDOWN
        - [x] SUPPRESSED: already covered
        - [x] RESOLVED/NO-FIX: intentional
        - [x] RESOLVED: obsolete
        - [x] NO-FIX: accepted behavior
        - [x] suppressed: case insensitive exclusion
        * [x] Not a runner finding
        - [X] Not a runner finding either
      MARKDOWN
      File.open(File.join(task.folder, "reviews", "codex-04.md"), "a") { |file| file.write(excluded) }
      File.write(File.join(task.folder, "reviews", "escalations-04.md"),
        "- [x] AUTO-FIX: accepted legacy escalation\n" + excluded)
      Hive::Markers.set(task.state_file, :review_stale,
        reason: "final_fix_unverified", pass: 4, accepted: 2, escalations: 0)
      before = tree_bytes(task.folder)
      assert_equal "eligible", budget.observe.state
      receipt = record(budget)
      assert_equal 1, receipt.fetch("amount")
      before.each { |path, bytes| assert_equal bytes, tree_bytes(task.folder).fetch(path) }
    end
  end

  def test_missing_history_and_unbound_or_missing_head_proof_refuse_without_writes
    changes = [
      ->(task) { File.unlink(File.join(task.folder, "task-journal.jsonl")) },
      ->(task) { File.write(File.join(task.folder, "task-journal.jsonl"), "bad json\n") },
      ->(task) { File.unlink(File.join(task.folder, "reviews", "fix-success-03.md")) },
      ->(task) { File.write(File.join(task.folder, "reviews", "fix-success-03.md"), "<!-- kind=fixed -->\n") },
      ->(task) { File.unlink(File.join(task.folder, "reviews", "codex-04.md")) },
      ->(task) { File.unlink(File.join(task.folder, "reviews", "escalations-04.md")) },
      ->(task) { File.write(File.join(task.folder, "reviews", "errors-04.md"), "failed\n") },
      ->(task) { File.write(File.join(task.folder, "reviews", "fix-success-04.md"), "done\n") },
      ->(task) { File.write(File.join(task.folder, "reviews", "codex-05.md"), "later\n") }
    ]
    changes.each do |change|
      with_fixture do |budget, task|
        change.call(task)
        before = tree_bytes(task.folder)
        assert_equal "refused", budget.observe.state
        assert_equal before, tree_bytes(task.folder)
      end
    end
  end

  def test_other_stale_reasons_and_completed_reviews_do_not_offer_grants
    with_fixture do |budget, task|
      Hive::Markers.set(task.state_file, :review_stale, reason: "max_passes", pass: 4)
      assert_equal "unavailable", budget.observe.state
      Hive::Markers.set(task.state_file, :review_complete, pass: 4)
      assert_equal "unavailable", budget.observe.state
    end
  end

  def test_inputs_are_strict_bounded_canonical_and_secret_scanned
    with_replaced_singleton_method(Hive::SecretScanner, :match?, ->(*) { false }) do
      [ nil, 0, -1, 4, "", " 1", "1 ", "1.0", "1abc", 1.5 ].each do |value|
        error = assert_raises(Hive::ReviewBudget::Refused) { Hive::ReviewBudget.normalize_decision(passes: value, reason: "fix required") }
        assert_equal "invalid_passes", error.reason
      end
      [ nil, "", "  ", "x" * 1025, "bad\nreason", "bad\e", "\xFF".b, "bad\u200B" ].each do |value|
        error = assert_raises(Hive::ReviewBudget::Refused) { Hive::ReviewBudget.normalize_decision(passes: 1, reason: value) }
        assert_equal "invalid_reason", error.error_kind
      end
      assert_equal({ passes: 3, reason: "café" }, Hive::ReviewBudget.normalize_decision(passes: "3", reason: " cafe\u0301 ".b))
      assert_equal({ passes: 1, reason: "operator reason" }, Hive::ReviewBudget.normalize_decision(
        passes: 1, reason: "operator reason".dup.force_encoding(Encoding::US_ASCII)))
      assert_raises(Hive::ReviewBudget::Refused) do
        Hive::ReviewBudget.normalize_decision(passes: 1, reason: "\u0344" * 512)
      end
    end
    with_replaced_singleton_method(Hive::SecretScanner, :match?, ->(*) { true }) do
      assert_raises(Hive::ReviewBudget::Refused) { Hive::ReviewBudget.normalize_decision(passes: 1, reason: "secret") }
    end
    with_replaced_singleton_method(Hive::SecretScanner, :match?, ->(*) { raise Hive::SecretScanner::Unavailable }) do
      error = assert_raises(Hive::ReviewBudget::Refused) { Hive::ReviewBudget.normalize_decision(passes: 1, reason: "explanation") }
      assert_equal "secret_scan_unavailable", error.reason
    end
  end

  def test_grant_is_private_immutable_pending_then_applied_and_replays_original_bytes
    with_fixture do |budget, task|
      receipt = record(budget, passes: 3)
      assert_equal "pending", budget.observe.state
      assert_equal "pending", budget.application_state(receipt)
      assert_nil budget.next_slot
      assert_equal 3, budget.observe.remaining
      bytes = tree_bytes(task.folder)
      replay = budget.replay(evidence_token: receipt.fetch("observation_digest"), passes: "3", reason: "  needs further fixes  ")
      assert_equal receipt, replay
      assert_equal bytes, tree_bytes(task.folder)
      assert_equal 0o600, File.stat(grant_path(task, receipt)).mode & 0o777
      assert_equal 0o700, File.stat(File.join(task.folder, "reviews")).mode & 0o777
      assert_equal 0o600, File.stat(budget.audit_path).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(budget.audit_path)).mode & 0o777
      audit = JSON.parse(File.read(budget.audit_path))
      assert_equal "needs further fixes", audit.fetch("reason")
      assert_equal "operator", audit.fetch("source")
      clear(task)
      assert_equal "applied", budget.observe.state
      assert_equal "applied", budget.application_state(receipt)
      assert_equal 1, budget.next_slot.fetch("slot")
      assert_equal receipt, budget.replay(evidence_token: receipt.fetch("observation_digest"), passes: 3, reason: "needs further fixes")
      assert_equal 1, File.readlines(budget.audit_path).length
    end
  end

  def test_conflicting_replay_and_changed_snapshot_never_mutate_decision_or_marker
    with_fixture do |budget, task|
      snapshot = budget.observe
      File.write(File.join(task.folder, "reviews", "codex-04.md"), "- [x] Different finding\n")
      before = tree_bytes(task.folder)
      assert_raises(Hive::ReviewBudget::Refused) do
        budget.record_grant!(snapshot: snapshot, passes: 1, reason: "needs further fixes", caller: "local-operator", source: "operator")
      end
      assert_equal before, tree_bytes(task.folder)
      receipt = record(budget)
      before = tree_bytes(task.folder)
      [ [ 2, "needs further fixes" ], [ 1, "different reason" ] ].each do |passes, reason|
        error = assert_raises(Hive::ReviewBudget::Refused) { budget.replay(evidence_token: receipt.fetch("observation_digest"), passes: passes, reason: reason) }
        assert_equal "decision_conflict", error.reason
      end
      assert_equal before, tree_bytes(task.folder)
    end
  end

  def test_audit_repair_and_torn_final_entry_are_idempotent_without_another_grant
    with_fixture do |budget, task|
      receipt = record(budget)
      audit = File.binread(budget.audit_path)
      File.unlink(budget.audit_path)
      assert_equal "pending", budget.observe.state
      budget.reconcile_audit!(receipt)
      assert_equal audit, File.binread(budget.audit_path)
      File.binwrite(budget.audit_path, audit.byteslice(0, audit.bytesize / 2))
      budget.reconcile_audit!(receipt)
      assert_equal audit, File.binread(budget.audit_path)
      budget.reconcile_audit!(receipt)
      assert_equal 1, File.readlines(budget.audit_path).length
      assert_equal 1, budget.store.grants.length
      assert_equal :review_stale, Hive::Markers.current(task.state_file).name
      File.open(budget.audit_path, "ab") { |file| file.write("unrelated torn") }
      assert_raises(Hive::ReviewBudget::Refused) { budget.reconcile_audit!(receipt) }
    end
  end

  def test_only_fixed_completion_receipts_spend_slots_and_sealed_slot_never_reopens
    with_fixture do |budget, task|
      receipt = record(budget, passes: 2)
      clear(task)
      input = budget.observe
      assert_equal 1, budget.next_slot(snapshot: input).fetch("slot")
      assert_equal budget.next_slot(snapshot: input), budget.next_slot
      completion = budget.complete_fix!(snapshot: input, pass: 4, head: "b" * 40)
      assert_equal "fixed", completion.fetch("kind")
      assert_equal receipt.fetch("decision_id"), completion.fetch("decision_id")
      assert_equal 1, budget.observe.spent
      assert_equal 1, budget.observe.remaining
      assert_equal 2, budget.next_slot.fetch("slot")
      assert_equal completion, budget.complete_fix!(snapshot: input, pass: 4, head: "b" * 40)
      assert_raises(Hive::ReviewBudget::Refused) { budget.complete_fix!(snapshot: input, pass: 4, head: "c" * 40) }
      File.open(File.join(task.folder, "reviews", "escalations-04.md"), "a") { |file| file.write("Operator clarification\n") }
      assert_equal 1, budget.observe.spent
      assert_equal 2, budget.next_slot.fetch("slot")
      File.write(File.join(task.folder, "reviews", "fix-success-04.md"), "<!-- head=#{HEAD} kind=approved -->\n")
      assert_equal 1, budget.observe.spent
    end
  end

  def test_fixed_head_changes_and_restart_preserve_scope_while_generation_or_completion_expire_it
    with_fixture do |budget, task|
      receipt = record(budget)
      clear(task)
      input = budget.observe
      budget.complete_fix!(snapshot: input, pass: 4, head: "b" * 40)
      fresh = Hive::ReviewBudget.new(task: task, project: "demo", head: "b" * 40)
      assert_equal "verifying", fresh.observe.state
      assert_equal 1, fresh.observe.spent
      assert_equal "applied", fresh.application_state(receipt)
      Hive::Markers.set(task.state_file, :review_complete, pass: 5)
      assert_equal "completed", fresh.observe.state
      assert_equal 0, fresh.observe.remaining
      assert_equal "historical", fresh.application_state(receipt)
      clear(task)
      journal_event(task, event_type: "generation_advanced", task_generation: 1)
      assert_equal "expired", fresh.observe.state
      assert_equal 0, fresh.observe.remaining
      assert_equal "historical", fresh.application_state(receipt)
    end
  end

  def test_non_final_parks_suspend_without_losing_slots_or_authorizing_recovery
    with_fixture do |budget, task|
      receipt = record(budget, passes: 2)
      clear(task)
      [ :review_error, :review_ci_stale, :review_stale, :error, :review_waiting ].each do |marker|
        Hive::Markers.set(task.state_file, marker, phase: "fix", reason: "provider_hold", pass: 4)
        snapshot = budget.observe
        assert_equal "suspended", snapshot.state
        assert_equal 2, snapshot.remaining
        assert_equal marker.to_s, snapshot.blocking_marker.fetch("name")
        assert_equal "changed", budget.application_state(receipt)
        assert_nil budget.next_slot
      end
      clear(task)
      assert_equal 1, budget.next_slot.fetch("slot")
      Hive::Markers.set(task.state_file, :review_working, phase: "fix", pass: 4)
      assert_equal "fixing", budget.observe.state
    end
  end

  def test_preserved_findings_head_change_is_refused_before_any_slot_spending
    with_fixture do |budget, task|
      receipt = record(budget)
      clear(task)
      changed = Hive::ReviewBudget.new(task: task, project: "demo", head: "b" * 40)
      assert_equal "refused", changed.observe.state
      assert_equal "changed", changed.application_state(receipt)
      assert_equal 0, budget.observe.spent
    end
  end

  def test_repeat_grant_requires_spent_slots_and_a_later_head_bound_final_verification
    with_fixture do |budget, task|
      first = record(budget)
      clear(task)
      input = budget.observe
      budget.complete_fix!(snapshot: input, pass: 4, head: HEAD)
      File.write(File.join(task.folder, "reviews", "fix-success-04.md"), "<!-- head=#{HEAD} kind=fixed -->\n")
      File.write(File.join(task.folder, "reviews", "codex-05.md"), "- [x] A remaining defect\n")
      File.write(File.join(task.folder, "reviews", "escalations-05.md"), "# Escalations\n")
      Hive::Markers.set(task.state_file, :review_stale, reason: "final_fix_unverified", pass: 5, accepted: 1, escalations: 0)
      assert_equal "eligible", budget.observe.state
      second = record(budget, passes: 2)
      refute_equal first.fetch("decision_id"), second.fetch("decision_id")
      assert_equal 2, budget.observe.remaining
      assert_equal 1, budget.observe.spent
      assert_equal 2, second.fetch("sequence")
      assert_equal "historical", budget.application_state(first)
      clear(task)
      assert_equal second.fetch("decision_id"), budget.next_slot.fetch("decision_id")
      assert_equal 1, budget.next_slot.fetch("slot")
    end
  end

  def test_archive_retains_historical_replay_without_reactivating_or_recreating_a_receipt
    with_fixture do |budget, task|
      receipt = record(budget)
      budget.record_expiry!(reason: "review_reset")
      assert_equal "expiry", JSON.parse(File.readlines(budget.audit_path).last).fetch("event")
      archive = File.join(task.folder, "reviews", "archive", "rework-01")
      FileUtils.mkdir_p(archive)
      Dir[File.join(task.folder, "reviews", "*")].select { |path| File.file?(path) }.each { |path| FileUtils.mv(path, archive) }
      File.write(File.join(task.folder, "reviews", "codex-01.md"), "fresh review\n")
      clear(task)
      before = tree_bytes(task.folder)
      assert_equal receipt, budget.replay(evidence_token: receipt.fetch("observation_digest"), passes: 1, reason: "needs further fixes")
      assert_equal "historical", budget.application_state(receipt)
      assert_equal before, tree_bytes(task.folder)
      assert_equal 0, budget.observe.remaining
    end
  end

  def test_distinct_expiry_intents_append_without_conflict_and_each_replays_idempotently
    with_fixture do |budget, _task|
      record(budget)
      2.times { budget.record_expiry!(reason: "review_reset") }
      2.times { budget.record_expiry!(reason: "review_completed") }
      entries = File.readlines(budget.audit_path).map { |line| JSON.parse(line) }
      assert_equal %w[grant expiry expiry], entries.map { |entry| entry.fetch("event") }
      assert_equal %w[review_reset review_completed], entries.drop(1).map { |entry| entry.fetch("expiry_reason") }
    end
  end

  def test_receipt_removal_replacement_corruption_and_cross_task_identity_fail_closed
    with_fixture do |budget, task|
      receipt = record(budget)
      path = grant_path(task, receipt)
      original = File.binread(path)
      File.unlink(path)
      assert_equal "refused", budget.observe.state
      File.write(path, original, mode: "wb", perm: 0o600)
      [ "not json", original.sub('"schema_version":1', '"schema_version":2'), original.sub('"task_id":"42"', '"task_id":"43"') ].each do |bytes|
        File.binwrite(path, bytes)
        assert_equal "refused", budget.observe.state
      end
      File.binwrite(path, original)
      File.chmod(0o644, path)
      assert_equal "refused", budget.observe.state
      File.chmod(0o600, path)
      assert_equal "pending", budget.observe.state
      File.unlink(path)
      File.symlink(task.state_file, path)
      assert_equal "refused", budget.observe.state
    end
  end

  def test_symlink_parents_and_oversized_artifacts_are_refused
    with_fixture do |budget, task|
      reviews = File.join(task.folder, "reviews")
      FileUtils.mv(reviews, "#{reviews}-real")
      File.symlink("#{reviews}-real", reviews)
      assert_equal "refused", budget.observe.state
      File.unlink(reviews)
      FileUtils.mv("#{reviews}-real", reviews)
      File.binwrite(File.join(reviews, "codex-04.md"), "x" * (Hive::ReviewBudget::MAX_ARTIFACT_BYTES + 1))
      assert_equal "refused", budget.observe.state
    end
  end

  def test_custody_restores_agent_additions_edits_deletions_and_absent_audit
    [ :add, :edit, :delete, :audit ].each do |operation|
      with_fixture do |budget, task|
        receipt = record(budget)
        File.unlink(budget.audit_path) if operation == :audit
        before = tree_bytes(task.folder)
        capture = budget.capture_custody
        case operation
        when :add then File.write(File.join(task.folder, "reviews", "review-grant-agent-forgery.json"), "{}")
        when :edit then File.binwrite(grant_path(task, receipt), "{}")
        when :delete then File.unlink(grant_path(task, receipt))
        when :audit then File.write(budget.audit_path, "forged\n")
        end
        error = assert_raises(Hive::ReviewBudget::Refused) { budget.verify_custody!(capture) }
        assert_equal "agent_modified_budget", error.reason
        assert_equal before, tree_bytes(task.folder)
        assert budget.verify_custody!(budget.capture_custody)
      end
    end
  end

  def test_custody_fails_closed_when_an_agent_replaces_a_receipt_with_a_directory
    with_fixture do |budget, task|
      receipt = record(budget)
      capture = budget.capture_custody
      path = grant_path(task, receipt)
      File.unlink(path)
      Dir.mkdir(path)
      error = assert_raises(Hive::ReviewBudget::Refused) { budget.verify_custody!(capture) }
      assert_equal "unsafe_state", error.reason
      assert File.directory?(path)
    end
  end

  def test_custody_of_an_initial_empty_task_creates_no_files_and_accepts_ordinary_outputs
    with_fixture do |budget, task|
      FileUtils.rm_rf(File.join(task.folder, "reviews"))
      capture = budget.capture_custody
      assert budget.verify_custody!(capture)
      refute File.exist?(File.join(task.folder, "reviews"))
      FileUtils.mkdir_p(File.join(task.folder, "reviews"))
      File.write(File.join(task.folder, "reviews", "codex-01.md"), "- [ ] A finding\n")
      assert budget.verify_custody!(capture)
      refute budget.present?
    end
  end

  def test_partial_fix_head_proof_uses_exact_controller_marker_or_retained_recovery_history
    with_fixture do |budget, task|
      receipt = record(budget)
      clear(task)
      proof = { "phase" => "fix", "pass" => "4", "grant_decision" => receipt.fetch("decision_id"),
        "grant_slot" => "1", "input_head" => HEAD, "head" => "b" * 40,
        "input_artifacts_digest" => Hive::ReviewBudget.digest(budget.observe.evidence.fetch("artifacts")) }
      Hive::Markers.set(task.state_file, :review_error, **proof.transform_keys(&:to_sym), reason: "agent_failed")
      changed = Hive::ReviewBudget.new(task: task, project: "demo", head: "b" * 40)
      assert_equal "suspended", changed.observe.state
      assert changed.validate_resume!
      clear(task)
      assert_equal "refused", changed.observe.state
      assert_raises(Hive::ReviewBudget::Refused) { changed.validate_resume! }
      journal_event(task, event_type: "activity_recorded", provenance: { "source" => "recovery_service" },
        payload: { "activity_kind" => "recovery_recorded", "operation_id" => "retry-1", "review_grant_resume" => proof })
      assert_equal "applied", changed.observe.state
      assert changed.validate_resume!
      assert_equal 1, changed.next_slot.fetch("slot")
      explicit = Hive::ReviewBudget.new(task: task, project: "demo", head: -> { "b" * 40 }, resume_evidence: -> { proof })
      assert_equal "applied", explicit.observe.state
      invalid = Hive::ReviewBudget.new(task: task, project: "demo", head: "b" * 40, resume_evidence: proof.merge("grant_slot" => "2"))
      assert_equal "refused", invalid.observe.state
      changed_proof = Hive::ReviewBudget.new(task: task, project: "demo", head: "b" * 40,
        resume_evidence: proof.merge("input_artifacts_digest" => "c" * 64))
      assert_raises(Hive::ReviewBudget::Refused) { changed_proof.validate_resume! }
    end
  end

  def test_arbitrary_high_exhausted_pass_requires_admitted_history
    with_fixture do |budget, task|
      reviews = File.join(task.folder, "reviews")
      File.rename(File.join(reviews, "codex-04.md"), File.join(reviews, "codex-99.md"))
      File.rename(File.join(reviews, "escalations-04.md"), File.join(reviews, "escalations-99.md"))
      File.write(File.join(reviews, "fix-success-98.md"), "<!-- HIVE: head=#{HEAD} kind=fixed -->\n")
      Hive::Markers.set(task.state_file, :review_stale,
        reason: "final_fix_unverified", pass: 99, accepted: 1, escalations: 0)

      snapshot = budget.observe
      assert_equal "refused", snapshot.state
      assert_includes snapshot.remediation, "no admitted"
      refute budget.present?
    end
  end

  def test_later_slot_retry_keeps_its_own_input_head_and_ignores_prior_slot_proof
    with_fixture do |budget, task|
      receipt = record(budget, passes: 2)
      clear(task)
      budget.complete_fix!(snapshot: budget.observe, pass: 4, head: "b" * 40)
      reviews = File.join(task.folder, "reviews")
      File.write(File.join(reviews, "fix-success-04.md"), "<!-- head=#{'b' * 40} kind=fixed -->\n")
      File.write(File.join(reviews, "codex-05.md"), "- [x] Later accepted defect\n")
      File.write(File.join(reviews, "escalations-05.md"), "# Escalations\n")
      proof = { "phase" => "fix", "pass" => "4", "grant_decision" => receipt.fetch("decision_id"),
        "grant_slot" => "1", "input_head" => HEAD, "head" => "b" * 40 }
      later = Hive::ReviewBudget.new(task: task, project: "demo", head: "b" * 40, resume_evidence: proof)
      input = later.observe
      assert later.validate_resume!(snapshot: input)
      assert_equal "b" * 40, later.fix_input_head(snapshot: input)

      proof = proof.merge("pass" => "5", "grant_slot" => "2", "input_head" => "b" * 40,
        "head" => "c" * 40, "input_artifacts_digest" => Hive::ReviewBudget.digest(input.evidence.fetch("artifacts")))
      retry_budget = Hive::ReviewBudget.new(task: task, project: "demo", head: "c" * 40, resume_evidence: proof)
      retry_input = retry_budget.observe
      assert retry_budget.validate_resume!(snapshot: retry_input)
      assert_equal "b" * 40, retry_budget.fix_input_head(snapshot: retry_input)
      invalid = Hive::ReviewBudget.new(task: task, project: "demo", head: "c" * 40,
        resume_evidence: proof.merge("input_head" => nil))
      assert_raises(Hive::ReviewBudget::Refused) { invalid.fix_input_head(snapshot: invalid.observe) }
      completion = retry_budget.complete_fix!(snapshot: retry_input, pass: 5, head: "c" * 40)
      assert_equal "b" * 40, completion.fetch("input_head")
      assert_equal 2, completion.fetch("slot")
      assert_equal [ 2, 0 ], [ retry_budget.observe.spent, retry_budget.observe.remaining ]
    end
  end

  def test_resume_validation_preserves_suspension_and_refuses_later_unbound_findings
    with_fixture do |budget, task|
      record(budget, passes: 2)
      clear(task)
      input = budget.observe
      budget.complete_fix!(snapshot: input, pass: 4, head: HEAD)
      File.write(File.join(task.folder, "reviews", "fix-success-04.md"), "<!-- head=#{HEAD} kind=fixed -->\n")
      File.write(File.join(task.folder, "reviews", "codex-05.md"), "- [x] Later accepted defect\n")
      File.write(File.join(task.folder, "reviews", "escalations-05.md"), "# Escalations\n")
      Hive::Markers.set(task.state_file, :review_error, phase: :fix, reason: "agent_failed", pass: 5)
      assert budget.validate_resume!
      changed = Hive::ReviewBudget.new(task: task, project: "demo", head: "b" * 40)
      before = File.binread(task.state_file)
      assert_raises(Hive::ReviewBudget::Refused) { changed.validate_resume! }
      assert_equal before, File.binread(task.state_file)
      assert_equal 1, budget.observe.remaining
      Hive::Markers.set(task.state_file, :review_complete, pass: 5)
      assert budget.validate_resume!
    end
  end

  def test_missing_completion_cannot_resurrect_a_spent_fix_and_torn_completion_audit_repairs
    with_fixture do |budget, task|
      receipt = record(budget, passes: 2)
      clear(task)
      input = budget.observe
      completion = budget.complete_fix!(snapshot: input, pass: 4, head: HEAD)
      path = File.join(task.folder, "reviews", "review-completion-#{receipt.fetch('decision_id')}-01.json")
      bytes = File.binread(path)
      File.unlink(path)
      assert_equal "refused", budget.observe.state
      File.write(path, bytes, mode: "wb", perm: 0o600)
      lines = File.readlines(budget.audit_path)
      File.binwrite(budget.audit_path, lines.first + lines.last.byteslice(0, lines.last.bytesize / 2))
      assert_equal "applied", budget.observe.state
      budget.reconcile_audit!(receipt)
      assert_equal lines.join, File.binread(budget.audit_path)
      assert_equal completion, budget.complete_fix!(snapshot: input, pass: 4, head: HEAD)
      assert_equal 2, File.readlines(budget.audit_path).length
    end
  end

  def test_new_review_transition_and_changed_findings_refuse_active_reuse
    with_fixture do |budget, task|
      receipt = record(budget)
      clear(task)
      File.open(File.join(task.folder, "reviews", "codex-04.md"), "a") { |file| file.write("changed context\n") }
      assert_equal "refused", budget.observe.state
      assert_equal "changed", budget.application_state(receipt)
    end
    with_fixture do |budget, task|
      receipt = record(budget)
      clear(task)
      journal_event(task, event_type: "activity_recorded", provenance: { "source" => "command_service" },
        payload: { "activity_kind" => "approval_recorded", "operation_id" => "move-review", "to_stage" => "7-artifacts" })
      snapshot = budget.observe
      assert_equal "expired", snapshot.state
      assert_equal receipt.fetch("scope"), snapshot.original_scope
    end
  end

  def test_final_verification_counters_and_different_current_marker_are_coherent
    with_fixture do |budget, task|
      Hive::Markers.set(task.state_file, :review_stale, reason: "final_fix_unverified", pass: 4)
      assert_equal "refused", budget.observe.state
      Hive::Markers.set(task.state_file, :review_stale, reason: "final_fix_unverified", pass: 4, accepted: 2, escalations: 0)
      assert_equal "refused", budget.observe.state
      File.write(File.join(task.folder, "reviews", "escalations-04.md"), "### Q1. Decide\nQuestion\n### A1.\nAnswer\n")
      assert_equal "eligible", budget.observe.state
      File.write(File.join(task.folder, "reviews", "escalations-04.md"), "### Q1. Decide\nQuestion\n### A1.\n\n")
      Hive::Markers.set(task.state_file, :review_stale, reason: "final_fix_unverified", pass: 4, accepted: 1, escalations: 1)
      assert_equal "eligible", budget.observe.state
      receipt = record(budget)
      Hive::Markers.set(task.state_file, :review_stale, reason: "final_fix_unverified", pass: 4, accepted: 1, escalations: 1)
      assert_equal "refused", budget.observe.state
      assert_equal "changed", budget.application_state(receipt)
    end
    with_fixture do |budget, task|
      receipt = record(budget)
      clear(task)
      budget.complete_fix!(snapshot: budget.observe, pass: 4, head: HEAD)
      Hive::Markers.set(task.state_file, :review_stale, reason: "final_fix_unverified", pass: 4, accepted: 1, escalations: 0)
      assert_equal "suspended", budget.observe.state
      assert_equal "historical", budget.application_state(receipt)
    end
  end

  def test_completion_refuses_expired_scope_and_no_budget
    with_fixture do |budget, task|
      assert_raises(Hive::ReviewBudget::Refused) { budget.complete_fix!(snapshot: budget.observe, pass: 4, head: HEAD) }
      record(budget)
      clear(task)
      input = budget.observe
      task.stage_name = "artifacts"
      assert_raises(Hive::ReviewBudget::Refused) { budget.complete_fix!(snapshot: input, pass: 4, head: HEAD) }
    end
  end

  def test_receipt_writer_byte_compares_existing_records_and_audit_rejects_replacement
    with_fixture do |budget, task|
      receipt = record(budget)
      assert_equal receipt, budget.store.write_grant!(receipt)
      assert_raises(Hive::ReviewBudget::Refused) { budget.store.write_grant!(receipt.merge("recorded_at" => (NOW + 1).iso8601(6))) }
      audit = JSON.parse(File.read(budget.audit_path))
      File.write(budget.audit_path, JSON.generate(audit.merge("reason" => "forged reason")) + "\n")
      assert_raises(Hive::ReviewBudget::Refused) { budget.reconcile_audit!(receipt) }
      File.write(budget.audit_path, "{}\n")
      assert_equal "refused", budget.observe.state
      File.unlink(budget.audit_path)
      File.symlink(task.state_file, budget.audit_path)
      assert_equal "refused", budget.observe.state
    end
  end

  def test_private_parent_and_bounded_regular_reads_refuse_unsafe_paths
    with_fixture do |budget, task|
      record(budget)
      File.chmod(0o755, File.dirname(budget.audit_path))
      assert_equal "refused", budget.observe.state
      assert_raises(Hive::ReviewBudget::Refused) { budget.store.directory!(File.join(task.folder, "missing")) }
      assert_raises(Hive::ReviewBudget::Refused) { budget.store.read_regular(File.join(task.folder, "missing"), max_bytes: 10) }
      File.write(File.join(task.folder, "reviews", "review-grant-bad.json"), "{}\n")
      assert_raises(Hive::ReviewBudget::Refused) { budget.present? }
    end
  end

  def test_real_owned_worktree_head_and_pointer_are_bound_and_foreign_ownership_is_refused
    with_tmp_git_repo do |repository|
      with_fixture do |_budget, task|
        worktrees = File.join(repository, "worktrees")
        path = File.join(worktrees, task.slug)
        run!("git", "-C", repository, "worktree", "add", "-b", task.slug, path)
        task.project_root = repository
        task.worktree_path = path
        File.write(File.join(task.folder, "worktree.yml"), YAML.dump("path" => path, "branch" => task.slug))
        head = Hive::AgentGitGate.read(path, :head_oid).stdout.strip
        (1..3).each do |pass|
          File.write(File.join(task.folder, "reviews", "fix-success-#{format('%02d', pass)}.md"), "<!-- head=#{head} kind=fixed -->\n")
        end
        with_replaced_singleton_method(Hive::Worktree, :canonical_root, ->(*) { worktrees }) do
          budget = Hive::ReviewBudget.new(task: task, project: "demo")
          snapshot = budget.observe
          assert_equal "eligible", snapshot.state
          assert_equal path, snapshot.evidence.fetch("worktree").fetch("pointer").fetch("path")
          File.open(File.join(task.folder, "worktree.yml"), "a") { |file| file.write("note: changed\n") }
          refute_equal snapshot.evidence_token, budget.observe.evidence_token
          File.write(File.join(task.folder, "worktree.yml"), YAML.dump("path" => path, "branch" => "foreign"))
          assert_equal "worktree_unavailable", budget.observe.reason
        end
      end
    end
  end

  def test_git_failures_missing_identity_and_mixed_observations_refuse_read_only
    with_fixture do |_budget, task|
      failure = Hive::AgentGitGate::ReadResult.new(operation: :head_oid, stdout: "", stderr: "unavailable", exitstatus: 1, overflow: false)
      with_replaced_singleton_method(Hive::AgentGitGate, :read, ->(*) { failure }) do
        budget = Hive::ReviewBudget.new(task: task, project: "demo")
        assert_equal "worktree_unavailable", budget.observe.reason
      end
      with_replaced_singleton_method(Hive::AgentGitGate, :read, ->(*) { raise Hive::AgentGitGate::InvalidRequest }) do
        budget = Hive::ReviewBudget.new(task: task, project: "demo")
        assert_equal "worktree_unavailable", budget.observe.reason
      end
      reads = 0
      budget = Hive::ReviewBudget.new(task: task, project: "demo", head: -> { reads += 1; reads == 1 ? HEAD : "b" * 40 })
      assert_equal "evidence_changed", budget.observe.reason
      task.id = nil
      assert_equal "invalid_task_identity", budget.observe.reason
      task.id = 42
      File.chmod(0o000, task.state_file)
      assert_equal "invalid_evidence", Hive::ReviewBudget.new(task: task, project: "demo", head: HEAD).observe.reason
      File.chmod(0o600, task.state_file)
    end
  end

  def test_invalid_producer_epoch_and_attribution_are_rejected
    with_fixture do |budget, _task|
      fake_projection = Struct.new(:to_h).new({ "identity" => { "task_generation" => "1" } })
      fake_read = Struct.new(:projection, :journal_records, :diagnostics) do
        def current? = true
      end.new(fake_projection, [ {} ], [])
      reader = Object.new
      reader.define_singleton_method(:read_bounded) { |**| fake_read }
      with_replaced_singleton_method(Hive::TaskProjection::Reader, :new, ->(**) { reader }) do
        assert_equal "invalid_task_history", budget.observe.reason
      end
      with_replaced_singleton_method(Hive::SecretScanner, :match?, ->(*) { false }) do
        assert_raises(Hive::ReviewBudget::Refused) do
          budget.record_grant!(snapshot: budget.observe, passes: 1, reason: "repair", caller: "", source: "operator")
        end
      end
    end
  end

  def test_stale_logical_slot_cannot_be_completed_again_when_its_predecessor_disappears
    with_fixture do |budget, task|
      receipt = record(budget, passes: 2)
      clear(task)
      budget.complete_fix!(snapshot: budget.observe, pass: 4, head: HEAD)
      later = budget.observe
      File.unlink(File.join(task.folder, "reviews", "review-completion-#{receipt.fetch('decision_id')}-01.json"))
      File.write(budget.audit_path, File.readlines(budget.audit_path).first)
      error = assert_raises(Hive::ReviewBudget::Refused) { budget.complete_fix!(snapshot: later, pass: 5, head: HEAD) }
      assert_equal "completion_conflict", error.reason
    end
  end

  def test_strict_versioned_fields_reject_self_consistent_malformed_receipts
    mutations = [
      ->(entry) { entry["scope"] = {} },
      ->(entry) { entry["recorded_at"] = 42 },
      ->(entry) { entry["amount"] = 4 },
      ->(entry) { entry["reason"] = "bad\nreason" },
      ->(entry) { entry["evidence"]["marker"]["name"] = "review_error" },
      ->(entry) { entry["evidence"]["artifacts"] = { "../other-01.md" => "a" * 64 } },
      ->(entry) { entry["sequence"] = 2 }
    ]
    mutations.each do |mutation|
      with_fixture do |budget, task|
        receipt = record(budget)
        forged = JSON.parse(JSON.generate(receipt))
        mutation.call(forged)
        reidentify_grant!(forged)
        File.unlink(grant_path(task, receipt))
        File.write(grant_path(task, forged), JSON.generate(forged) + "\n", mode: "wb", perm: 0o600)
        assert_raises(Hive::ReviewBudget::Refused) { budget.store.records }
      end
    end
  end

  def test_completion_kind_identity_and_chain_are_strict
    [ "approved", "orphan", "slot_gap" ].each do |mutation|
      with_fixture do |budget, task|
        receipt = record(budget)
        clear(task)
        completion = budget.complete_fix!(snapshot: budget.observe, pass: 4, head: HEAD)
        path = File.join(task.folder, "reviews", "review-completion-#{receipt.fetch('decision_id')}-01.json")
        File.unlink(path)
        forged = JSON.parse(JSON.generate(completion))
        case mutation
        when "approved" then forged["kind"] = "approved"
        when "orphan" then forged["decision_id"] = "f" * 64
        when "slot_gap" then forged["slot"] = 2
        end
        forged_path = File.join(task.folder, "reviews", "review-completion-#{forged.fetch('decision_id')}-#{format('%02d', forged.fetch('slot'))}.json")
        File.write(forged_path, JSON.generate(forged) + "\n", mode: "wb", perm: 0o600)
        assert_raises(Hive::ReviewBudget::Refused) { budget.store.records }
      end
    end
  end

  def test_a_later_grant_cannot_bypass_an_unspent_predecessor_even_with_recomputed_digests
    with_fixture do |budget, task|
      first = record(budget)
      clear(task)
      completion = budget.complete_fix!(snapshot: budget.observe, pass: 4, head: HEAD)
      old_id = first.fetch("decision_id")
      forged = JSON.parse(JSON.generate(first)).merge("amount" => 2)
      reidentify_grant!(forged)
      completion = completion.merge("decision_id" => forged.fetch("decision_id"),
        "previous_receipt_digest" => Hive::ReviewBudget.digest([ Hive::ReviewBudget::EMPTY_CHAIN, forged ]))
      chain = budget.chain_digest([ forged ], [ completion ])
      second = JSON.parse(JSON.generate(first))
      second["sequence"] = 2
      second["previous_receipt_digest"] = chain
      second["evidence"]["receipt_chain_digest"] = chain
      second["evidence"]["pass"] = 5
      reidentify_grant!(second)
      File.unlink(grant_path(task, first))
      File.unlink(File.join(task.folder, "reviews", "review-completion-#{old_id}-01.json"))
      [ forged, second ].each { |grant| File.write(grant_path(task, grant), JSON.generate(grant) + "\n", mode: "wb", perm: 0o600) }
      File.write(File.join(task.folder, "reviews", "review-completion-#{forged.fetch('decision_id')}-01.json"), JSON.generate(completion) + "\n", mode: "wb", perm: 0o600)
      error = assert_raises(Hive::ReviewBudget::Refused) { budget.store.records }
      assert_match(/precedes exhausted/, error.message)
    end
  end

  def test_archived_decision_identity_is_ambiguous_if_retained_copies_differ
    with_fixture do |budget, task|
      receipt = record(budget)
      %w[rework-01 rework-02].each_with_index do |name, index|
        directory = File.join(task.folder, "reviews", "archive", name)
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, File.basename(grant_path(task, receipt))), JSON.generate(receipt.merge("recorded_at" => (NOW + index).iso8601(6))) + "\n", mode: "wb", perm: 0o600)
      end
      File.unlink(grant_path(task, receipt))
      assert_raises(Hive::ReviewBudget::Refused) { budget.replay(evidence_token: receipt.fetch("observation_digest"), passes: 1, reason: "needs further fixes") }
    end
  end

  def test_file_open_races_do_not_follow_a_replaced_inode_or_symlink
    [ :inode, :symlink ].each do |replacement|
      with_fixture do |budget, task|
        path = File.join(task.folder, "reviews", "codex-04.md")
        original_open = File.method(:open)
        raced = false
        wrapper = lambda do |candidate, *args, **kwargs, &block|
          if candidate == path && !raced
            raced = true
            File.rename(path, "#{path}.original")
            if replacement == :symlink
              File.symlink("#{path}.original", path)
            else
              File.write(path, "replacement\n")
            end
          end
          original_open.call(candidate, *args, **kwargs, &block)
        end
        with_replaced_singleton_method(File, :open, wrapper) do
          assert_equal "refused", budget.observe.state
        end
      end
    end
  end

  def test_audit_races_and_unrelated_torn_tail_fail_closed
    [ :read, :append ].each do |phase|
      with_fixture do |budget, _task|
        receipt = record(budget)
        original_open = File.method(:open)
        raced = false
        wrapper = lambda do |candidate, *args, **kwargs, &block|
          expected = phase == :read ? File::RDONLY | File::NOFOLLOW : File::WRONLY | File::CREAT | File::NOFOLLOW
          if candidate == budget.audit_path && args.first == expected && !raced
            raced = true
            bytes = File.binread(candidate)
            File.rename(candidate, "#{candidate}.old")
            File.write(candidate, phase == :append ? bytes + "changed" : bytes, mode: "wb", perm: 0o600)
          end
          original_open.call(candidate, *args, **kwargs, &block)
        end
        with_replaced_singleton_method(File, :open, wrapper) do
          if phase == :read
            assert_equal "refused", budget.observe.state
          else
            assert_raises(Hive::ReviewBudget::Refused) { budget.reconcile_audit!(receipt) }
          end
        end
      end
    end
    with_fixture do |budget, _task|
      record(budget)
      File.open(budget.audit_path, "a") { |file| file.write("unrelated torn") }
      assert_equal "refused", budget.observe.state
    end
  end

  def test_missing_completion_during_audit_and_failed_listing_restore_refuse
    with_fixture do |budget, task|
      receipt = record(budget)
      error = assert_raises(Hive::ReviewBudget::Refused) { budget.store.append_audit!(receipt, completion: { "decision_id" => receipt.fetch("decision_id") }) }
      assert_equal "unsafe_state", error.reason
      capture = budget.capture_custody
      File.write(File.join(task.folder, "reviews", "review-grant-#{'f' * 64}.json"), "{}")
      with_replaced_singleton_method(Hive::ProtectedFiles, :restore_paths, ->(*) { true }) do
        error = assert_raises(Hive::ReviewBudget::Refused) { budget.verify_custody!(capture) }
        assert_equal "unsafe_state", error.reason
      end
    end
  end

  def test_ci_repair_receipt_admits_the_next_exhausted_review_pass
    with_fixture do |budget, task|
      reviews = File.join(task.folder, "reviews")
      File.write(File.join(reviews, "fix-success-04.md"), "<!-- head=#{HEAD} kind=ci_repaired -->\n")
      File.write(File.join(reviews, "codex-05.md"), "- [x] A remaining finding\n")
      File.write(File.join(reviews, "escalations-05.md"), "# Escalations\n")
      Hive::Markers.set(task.state_file, :review_stale,
        reason: "final_fix_unverified", pass: 5, accepted: 1, escalations: 0)
      assert_equal "eligible", budget.observe.state
    end
  end

  def test_historical_admission_and_escalation_observation_guards_fail_closed
    with_fixture do |budget, _task|
      receipt = record(budget)
      evidence = budget.observe.evidence
      invalid = receipt.merge("evidence" => receipt.fetch("evidence").merge("pass" => 99))
      error = assert_raises(Hive::ReviewBudget::Refused) do
        budget.send(:validate_admitted_exhaustion!, evidence, [ invalid ], [])
      end
      assert_equal "contradictory_evidence", error.reason
      error = assert_raises(Hive::ReviewBudget::Refused) do
        budget.send(:escalation_proof, evidence.fetch("artifacts").merge("escalations-04.md" => "b" * 64), 4)
      end
      assert_equal "evidence_changed", error.reason
      invalid = JSON.parse(JSON.generate(receipt))
      invalid.fetch("evidence")["escalation_proof"] = { "unexpected" => "shape" }
      reidentify_grant!(invalid)
      assert_raises(Hive::ReviewBudget::Refused) do
        budget.store.write_grant!(invalid)
      end
    end
  end

  def test_new_fixed_completion_refuses_changed_captured_findings_without_spending
    with_fixture do |budget, task|
      record(budget)
      clear(task)
      input = budget.observe
      File.open(File.join(task.folder, "reviews", "codex-04.md"), "a") { |file| file.puts "Changed accepted work" }
      error = assert_raises(Hive::ReviewBudget::Refused) { budget.complete_fix!(snapshot: input, pass: 4, head: HEAD) }
      assert_equal "stale_evidence", error.reason
      assert_empty budget.store.records.last
    end
  end

  private

  def record(budget, passes: 1)
    with_replaced_singleton_method(Hive::SecretScanner, :match?, ->(*) { false }) do
      budget.record_grant!(snapshot: budget.observe, passes: passes,
        reason: "needs further fixes", caller: "local-operator", source: "operator")
    end
  end

  def reidentify_grant!(entry)
    token = Hive::ReviewBudget.digest(entry.fetch("evidence"))
    entry["observation_digest"] = token
    entry["decision_id"] = Hive::ReviewBudget.digest([ entry.fetch("project"), entry.fetch("task_id"), entry.fetch("task"), token,
      { passes: entry.fetch("amount"), reason: entry.fetch("reason") } ])
    entry
  end

  def clear(task)
    marker = Hive::Markers.current(task.state_file)
    Hive::Markers.clear_current(task.state_file, expected_name: marker.name, match_attrs: marker.attrs)
  end

  def grant_path(task, receipt)
    File.join(task.folder, "reviews", "review-grant-#{receipt.fetch('observation_digest')}.json")
  end

  def journal_event(task, **attributes)
    event = Hive::TaskJournal::Envelope.authoritative({ event_type: "reconciliation", task: { id: 42, slug: "example" },
      workflow: "coding", stage: "6-review", attempt_id: "attempt-#{attributes.fetch(:task_generation, 0)}",
      task_generation: 0, reason: "observed", occurred_at: NOW.iso8601 }.merge(attributes))
    File.open(File.join(task.folder, "task-journal.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
  end

  def with_fixture
    with_tmp_dir do |folder|
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      state_file = File.join(folder, "task.md")
      File.write(state_file, "---\nid: 42\n---\nTask\n")
      Hive::Markers.set(state_file, :review_stale,
                        reason: "final_fix_unverified", pass: 4, accepted: 1, escalations: 0)
      File.write(File.join(folder, "reviews", "codex-01.md"), "- [x] First fix\n")
      File.write(File.join(folder, "reviews", "escalations-01.md"), "# Escalations\n")
      File.write(File.join(folder, "reviews", "fix-success-01.md"), "<!-- HIVE: head=#{HEAD} kind=fixed -->\n")
      File.write(File.join(folder, "reviews", "codex-02.md"), "- [x] Second fix\n")
      File.write(File.join(folder, "reviews", "escalations-02.md"), "# Escalations\n")
      File.write(File.join(folder, "reviews", "fix-success-02.md"), "<!-- HIVE: head=#{HEAD} kind=fixed -->\n")
      File.write(File.join(folder, "reviews", "codex-03.md"), "- [x] Third fix\n")
      File.write(File.join(folder, "reviews", "escalations-03.md"), "# Escalations\n")
      File.write(File.join(folder, "reviews", "fix-success-03.md"), "<!-- HIVE: head=#{HEAD} kind=fixed -->\n")
      File.write(File.join(folder, "reviews", "codex-04.md"), "- [x] The accepted defect\n")
      File.write(File.join(folder, "reviews", "escalations-04.md"), "# Escalations\n")
      task = Task.new(folder: folder, id: 42, slug: "example", stage_name: "review",
                      state_file: state_file, worktree_path: folder)
      event = Hive::TaskJournal::Envelope.authoritative({ event_type: "legacy_baseline",
        task: { id: 42, slug: "example" }, workflow: "coding", stage: "6-review",
        attempt_id: "legacy", task_generation: 0, reason: "legacy_task_baseline",
        evidence: [], payload: { "source" => "task.md" }, occurred_at: NOW.iso8601 })
      File.write(File.join(folder, "task-journal.jsonl"), JSON.generate(event) + "\n")
      yield Hive::ReviewBudget.new(task: task, project: "demo", head: HEAD, clock: -> { NOW }), task
    end
  end

  def tree_bytes(folder)
    Dir[File.join(folder, "**", "*"), File.join(folder, ".*")].select { |path| File.file?(path) }
       .sort.to_h { |path| [ path.delete_prefix("#{folder}/"), File.binread(path) ] }
  end
end
