require "test_helper"
require_relative "../../support/task_capabilities_revision_fixture"
require_relative "../../support/task_capabilities_fixture"
require "hive/task_capabilities/gate"
require "hive/stages/review"

class TaskCapabilitiesRevisionTest < Minitest::Test
  include HiveTestHelper
  include TaskCapabilitiesFixture

  include TaskCapabilitiesRevisionFixture

  def test_qa_waiver_versions_the_active_plan_and_preserves_initial_identity
    with_revision do |service, task, store|
      initial = store.current
      token = expectation(service)
      result = service.waive(reason: "operator reason ghp_#{'a' * 36}", checks: [ "ci" ], **token)
      assert_equal "accepted", result.fetch("status")
      assert_equal 2, store.current.version
      assert_equal initial.adoption, Hive::TaskMeta.read(task.folder).fetch(:task_capabilities)
      assert_equal [ 1, 2 ], store.history.map(&:version)
      assert_includes store.current.data.fetch("waivers").first.fetch("reason"), "[REDACTED:github_token]"
      assert_equal "waived", store.current.data.dig("choices", "qa", "state")
      assert_equal result, service.waive(reason: "operator reason ghp_#{'a' * 36}", checks: [ "ci" ], **token)
    end
  end

  def test_proposals_are_inert_and_can_be_rejected_without_plan_changes
    with_revision do |service, _task, store|
      initial = store.current.digest
      proposal = service.propose(selections: [ "ui=off" ], **expectation(service))
      assert_equal initial, store.current.digest
      response = service.reject(proposal_digest: proposal.fetch("proposal_digest"), reason: "keep current", **expectation(service))
      assert_equal "rejected", response.fetch("status")
      assert_equal initial, store.current.digest
      assert_equal "rejected", service.show.fetch("proposals").first.fetch("status")
    end
  end

  def test_stale_version_sha_and_identity_fail_before_writes
    with_revision do |service, task, _store|
      token = expectation(service)
      snapshot = Dir.glob(File.join(task.folder, "**/*")).select { |path| File.file?(path) }.to_h { |path| [ path, File.binread(path) ] }
      [ { expected_version: 0 }, { expected_sha: "a" * 40 }, { expected_identity: token.fetch(:expected_identity).merge("id" => "other") } ].each do |change|
        error = assert_raises(Hive::TaskCapabilities::Admission::Error) { service.waive(reason: "reason", checks: [ "ci" ], **token.merge(change)) }
        assert_equal "task_capability_stale_revision", error.reason
      end
      assert_equal snapshot, snapshot.keys.to_h { |path| [ path, File.binread(path) ] }
    end
  end

  def test_empty_qa_can_receive_an_operator_check_within_the_original_authority
    with_revision(command: nil) do |service, _task, store, cfg|
      cfg["permissions"] = "read-only"
      proposal = service.propose(verification_plans: { "qa" => [ { "id" => "behavior", "kind" => "behavior", "claim" => "observe behavior", "command" => "ruby -e 'puts 7'" } ] }, **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      assert_equal "ruby -e 'puts 7'", store.current.data.fetch("bindings").first.fetch("checks").first.fetch("command")
      runner = store.current.data.fetch("bindings").first.fetch("checks").first.fetch("runner")
      assert_equal "controlled", runner.fetch("environment_mode")
      refute runner.key?("environment")
      assert_empty store.current.data.fetch("blockers")
    end
  end
end

class TaskCapabilitiesRevisionTest
  def ui_settings(policy: true, permissions: nil)
    { "policy" => { "auto_select" => policy ? [ { "capability" => "ui", "signals" => [ { "type" => "task_text", "value" => "screen" } ] } ] : [] },
      configure: lambda { |cfg, dir|
        skill = File.join(dir, ".claude/skills/ui-fixture/SKILL.md")
        FileUtils.mkdir_p(File.dirname(skill))
        File.write(skill, "Use clear labels.")
        cfg["agents"]["claude"]["bin"] = "ruby"
        cfg["task_capabilities"]["catalog"] = [ { "id" => "ui", "kind" => "guidance", "stages" => %w[plan execute],
          "skill" => "ui-fixture", "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" } } ]
        cfg["permissions"] = permissions if permissions
      } }
  end

  def security_settings
    { "catalog" => [ { "id" => "security", "kind" => "verification", "stages" => [ "review" ],
      "checks" => [ { "id" => "source", "kind" => "source_review", "claim" => "inspect source" } ] } ],
      "approvals" => { "local" => { "capability" => "security",
        "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" },
        "permissions" => { "tools" => [ "Read" ], "directories" => [ "." ], "domains" => [] },
        "targets" => [ "local-source" ], "budget_usd" => 1, "timeout_sec" => 10 } },
      configure: ->(cfg, _dir) { cfg["agents"]["claude"]["bin"] = "ruby" } }
  end

  def test_automatic_ui_addition_uses_matching_original_policy_at_admission
    with_revision(settings: ui_settings) do |service, task, store, cfg|
      File.write(File.join(task.folder, "plan.md"), "Add a screen")
      proposal = service.propose_from_signals!
      assert_equal "off", store.current.data.dig("choices", "ui", "effective")
      cfg["task_capabilities"]["policy"] = {}
      Hive::TaskCapabilities::Admission.enforce!(task)
      assert_equal 2, store.current.version
      assert_equal "on", store.current.data.dig("choices", "ui", "effective")
      assert_equal "accepted", service.show.fetch("proposals").find { |entry| entry["proposal_digest"] == proposal["proposal_digest"] }.fetch("status")
      assert_equal %w[plan execute], service.pending_guidance
      gate = Hive::TaskCapabilities::Gate.new(task: task, cfg: cfg)
      assert_match(/return the task to plan/, gate.evaluate.fetch("reason"))
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.record_guidance!(stage: "plan", plan_digest: store.current.digest) }
      with_attempt_context(attempt_id: "actual-owner", task_generation: 0) do
        assert_raises(Hive::TaskCapabilities::Admission::Error) { service.record_guidance!(stage: "plan", plan_digest: "a" * 64) }
        service.record_guidance!(stage: "plan", plan_digest: store.current.digest)
        service.record_guidance!(stage: "execute", plan_digest: store.current.digest)
      end
      assert_empty service.pending_guidance
      binding = store.current.data.fetch("bindings").find { |entry| entry["id"] == "qa" }
      check = binding.fetch("checks").first
      identity = Hive::TaskCapabilities::Verification.check_identity(plan: store.current, binding: binding, check: check,
        context: Struct.new(:attempt_id).new("actual-owner"), sha: expectation(service).fetch(:expected_sha), environment: Hive::TaskCapabilities::Verification.environment(plan: store.current))
      Hive::TaskCapabilities::ResultStore.new(task.folder).accept(Hive::TaskCapabilities::Result.command(identity.merge("task_delta" => Hive::TaskCapabilities::Result.task_delta(task.worktree_path, sha: expectation(service).fetch(:expected_sha))), exit_status: 0, output: "behavior observed"))
      assert gate.evaluate.fetch("allowed"), gate.evaluate.inspect
    end
  end

  def test_recommendation_only_and_newly_broadened_project_policy_cannot_autoactivate
    with_revision(settings: ui_settings(policy: false)) do |service, task, store, cfg|
      File.write(File.join(task.folder, "plan.md"), "Add a screen")
      service.propose(selections: [ "ui=automatic" ], **expectation(service))
      cfg["task_capabilities"]["policy"] = { "required" => [ "ui" ] }
      service.activate_pending!
      assert_equal 1, store.current.version
      assert_equal "off", store.current.data.dig("choices", "ui", "effective")
      with_attempt_context(attempt_id: "agent", task_generation: 0) { assert_nil service.activate_pending! }
    end
  end

  def test_security_addition_requires_explicit_acceptance_and_cannot_be_removed
    with_revision(settings: security_settings) do |service, task, store|
      token = expectation(service)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(selections: [ "security=on" ], **token) }
      proposal = service.propose(selections: [ "security=on" ], approval_references: [ "security=local" ], **token)
      service.activate_pending!
      assert_equal 1, store.current.version
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **token)
      assert_equal "on", store.current.data.dig("choices", "security", "effective")
      [ "security=off", "security=automatic" ].each do |selection|
        assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(selections: [ selection ], **expectation(service)) }
      end
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(verification_plans: { "security" => [] }, **expectation(service)) }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.risk_accept(result_digest: "a" * 64, finding_ids: [ "missing" ], reason: "unavailable", **expectation(service)) }
      assert_equal 2, store.current.version
      replacement = [ { "id" => "source", "kind" => "source_review", "claim" => "inspect current source" } ]
      proposal = service.propose(verification_plans: { "security" => replacement }, **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      bindings = store.current.data.fetch("bindings")
      security = bindings.find { |entry| entry["id"] == "security" }
      check = security.fetch("checks").first
      identity = Hive::TaskCapabilities::Verification.check_identity(plan: store.current, binding: security, check: check,
        context: Struct.new(:attempt_id).new("owner"), sha: expectation(service).fetch(:expected_sha), environment: Hive::TaskCapabilities::Verification.environment(plan: store.current))
      # A controller-observed failure is admissible even when the actor route
      # later disappears. It remains a failure in immutable result history.
      FileUtils.mkdir_p(File.join(task.folder, "local-source"))
      File.write(File.join(task.folder, "local-source/README.md"), "example")
      File.write(File.join(task.folder, "local-source/expected.txt"), "example")
      proof = proposed_outcome(task, identity, target: "local-source")
      failed = Hive::TaskCapabilities::Result.new(identity.merge("state" => "failed", "reason" => "observed", "applicability" => {}, "spawn_id" => "spawn",
        "evidence" => [ { "kind" => "outcome", "evaluated_sha" => identity.fetch("evaluated_sha"), "proof" => proof } ], "findings" => [ { "id" => "finding", "severity" => "medium", "summary" => "finding", "details" => "observed" } ]))
      digest = Hive::TaskCapabilities::ResultStore.new(task.folder).accept(failed)
      accepted = service.risk_accept(result_digest: digest, finding_ids: [ "finding" ], reason: "reason ghp_#{'a' * 36}", **expectation(service))
      assert_equal "risk-accepted", accepted.fetch("status")
      assert_includes Hive::TaskCapabilities::ResultStore.new(task.folder).disposition_history.last.last.fetch("reference"), "[REDACTED:github_token]"
      assert_equal "failed", Hive::TaskCapabilities::ResultStore.new(task.folder).history.last.last.state
      task.stage_name = "review"
      task.stage_index = 6
      assert_equal accepted, service.risk_accept(result_digest: digest, finding_ids: [ "finding" ], reason: "reason ghp_#{'a' * 36}", **expectation(service))
    end
  end

  def test_unavailable_security_template_is_not_a_capture_blocker_or_waiver
    settings = security_settings
    settings[:configure] = ->(cfg, _) { cfg["agents"]["claude"]["bin"] = "/missing-approved-route" }
    with_revision(settings: settings) do |service, _task, store|
      assert_empty store.current.data.fetch("blockers")
      proposal = service.propose(selections: [ "security=on" ], approval_references: [ "security=local" ], **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      assert store.current.data.fetch("blockers").any? { |entry| entry["reason"] == "task_capability_route_unavailable" }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.risk_accept(result_digest: "a" * 64, finding_ids: [], reason: "skip", **expectation(service)) }
    end
  end

  def test_check_revision_stales_dependents_and_reuses_unrelated_current_evidence
    with_revision do |service, task, store|
      checks = %w[a b c].map { |id| { "id" => id, "kind" => "behavior", "claim" => "observe #{id}", "command" => "ruby -e 'puts 1'", "depends_on" => id == "b" ? [ "a" ] : [] } }
      proposal = service.propose(verification_plans: { "qa" => checks }, **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      before = store.current
      binding = before.data.fetch("bindings").first
      results = Hive::TaskCapabilities::ResultStore.new(task.folder)
      environment = Hive::TaskCapabilities::Verification.environment(plan: before)
      sha = expectation(service).fetch(:expected_sha)
      binding.fetch("checks").each do |check|
        identity = Hive::TaskCapabilities::Verification.check_identity(plan: before, binding: binding, check: check, context: Struct.new(:attempt_id).new("owner"), sha: sha, environment: environment)
        results.accept(Hive::TaskCapabilities::Result.command(identity, exit_status: 0, output: "behavior observed"))
      end
      checks.first["command"] = "ruby -e 'puts 2'"
      proposal = service.propose(verification_plans: { "qa" => checks }, **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      current = store.current
      binding = current.data.fetch("bindings").first
      states = binding.fetch("checks").to_h { |check| [ check.fetch("id"), results.current(binding: binding, check: check, plan: current, sha: sha, environment: environment).fetch("state") ] }
      assert_equal({ "a" => "stale", "b" => "stale", "c" => "passed" }, states)
      assert_equal 3, results.history.length
      assert_equal [ 1, 2, 3 ], store.history.map(&:version)
    end
  end

  def test_operator_actions_deny_attempt_context_before_any_proposal_or_anchor_write
    with_revision do |service, task, store|
      token = expectation(service)
      proposal = service.propose(selections: [ "ui=off" ], **token)
      before = Dir.glob(File.join(task.folder, "**/*")).select { |path| File.file?(path) }.to_h { |path| [ path, File.binread(path) ] }
      with_attempt_context(attempt_id: "agent", task_generation: 0) do
        [ -> { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **token) },
          -> { service.reject(proposal_digest: proposal.fetch("proposal_digest"), reason: "no", **token) },
          -> { service.waive(reason: "no", checks: [ "ci" ], **token) },
          -> { service.risk_accept(result_digest: "a" * 64, finding_ids: [], reason: "no", **token) } ].each do |action|
          error = assert_raises(Hive::TaskCapabilities::Admission::Error, &action)
          assert_equal "task_capability_operator_required", error.reason
        end
        service.propose(selections: [ "ui=off" ], **token)
      end
      assert_equal before, before.keys.to_h { |path| [ path, File.binread(path) ] }
      assert_equal 1, store.current.version
    end
  end

  def test_running_launching_and_pending_publication_attempts_block_acceptance
    with_revision do |service, task, store|
      repository = Hive::Attempts::Repository.open_default
      launcher = Object.new
      launcher.define_singleton_method(:preflight!) { true }
      launcher.define_singleton_method(:launch) { |*, **| { "claimed" => true } }
      dispatcher = Hive::Attempts::Dispatcher.new(store: repository, launcher: launcher, capability_generator: -> { "c" * 64 })
      attempt = dispatcher.dispatch(task: task, project: "test-#{Digest::SHA256.hexdigest(task.project_root)[0, 16]}", intended_stage: "3-plan", argv: [ "hive", "run", task.slug ], request_id: "revision-owner", provider: "claude").attempt
      proposal = service.propose(selections: [ "ui=off" ], **expectation(service))
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service)) }
      assert_equal "task_capability_running_attempt", error.reason
      owner = { "pid" => Process.pid, "start_fingerprint" => Hive::Lock.process_start_time(Process.pid), "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
      attempt = repository.claim(attempt, owner: owner, claim_capability: "c" * 64, first_heartbeat_timeout_sec: 30, now: Time.now.utc)
      attempt = repository.first_heartbeat(attempt, stale_sec: 30, now: Time.now.utc)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service)) }
      repository.terminalize(attempt, outcome: "succeeded", exit_status: 0, final_checkpoint: { "marker" => "complete" }, output_references: [],
        log_reference: { "path" => "open/fixture.frames", "size" => 0, "sha256" => Digest::SHA256.hexdigest("") }, now: Time.now.utc)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service)) }
      assert_equal 1, store.current.version
    end
  end

  def test_interrupted_activation_and_journal_retries_create_one_version_and_one_event
    with_revision do |service, task, store|
      token = expectation(service)
      proposal = service.propose(selections: [ "ui=off" ], **token)
      original = Hive::AtomicFile.method(:write)
      with_replaced_singleton_method(Hive::AtomicFile, :write, lambda { |path, *args, **kwargs|
        raise "interrupted" if File.basename(path) == "execution-plan-current.json"
        original.call(path, *args, **kwargs)
      }) do
        assert_raises(RuntimeError) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **token) }
      end
      assert_equal 1, store.current.version
      assert_equal [ 1, 2 ], store.history.map(&:version)
      alternative = service.propose(selections: [ "ui=off" ], reason: "different proposal", **token)
      assert_raises(Hive::TaskCapabilities::Store::Conflict) { service.accept(proposal_digest: alternative.fetch("proposal_digest"), **token) }
      first = service.accept(proposal_digest: proposal.fetch("proposal_digest"), **token)
      assert_equal first, service.accept(proposal_digest: proposal.fetch("proposal_digest"), **token)
      assert_equal [ 1, 2 ], store.history.map(&:version)
      records = Hive::TaskProjection.read_journal(File.join(task.folder, "task-journal.jsonl"))
      assert_equal 1, records.count { |entry| entry.dig("payload", "activity_kind") == "capability_revision" }
    end
  end

  def test_qa_waiver_is_exact_and_hard_policy_cannot_be_waived
    with_revision(command: nil) do |service, _task, store|
      service.waive(reason: "manual confirmation", checks: [ "all" ], **expectation(service))
      assert store.current.data.fetch("waivers").first.fetch("whole_gate")
      assert_empty store.current.data.fetch("waivers").first.fetch("checks")
    end
    with_revision do |service, _task, store|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.waive(reason: "reason", checks: [ "future" ], **expectation(service)) }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.waive(reason: "", checks: [ "all" ], **expectation(service)) }
      assert_equal 1, store.current.version
    end
    with_revision(settings: { "policy" => { "required" => [ "qa" ] } }) do |service, _task, store|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.waive(reason: "reason", checks: [ "all" ], **expectation(service)) }
      assert_equal 1, store.current.version
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_rejected_proposal_retries_are_idempotent_and_cannot_be_accepted
    with_revision do |service, _task, store|
      token = expectation(service)
      proposal = service.propose(selections: [ "ui=off" ], **token)
      first = service.reject(proposal_digest: proposal.fetch("proposal_digest"), reason: "retain current", **token)
      assert_equal first, service.reject(proposal_digest: proposal.fetch("proposal_digest"), reason: "retain current", **token)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **token) }
      assert_equal 1, store.current.version
    end
  end

  def test_untrusted_proposals_cannot_import_a_candidate_generation_or_malformed_json
    with_revision do |service, task, store|
      token = expectation(service)
      proposal = service.propose(selections: [ "ui=off" ], **token)
      path = File.join(task.folder, "capability-proposals", "#{proposal.fetch('proposal_digest')}.json")
      value = JSON.parse(File.read(path))
      value["base_digest"] = "a" * 64
      bytes = Hive::WorkflowPackage::CanonicalJSON.generate(value)
      digest = Digest::SHA256.hexdigest(bytes)
      File.write(File.join(File.dirname(path), "#{digest}.json"), bytes)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: digest, **token) }
      File.write(path, "invalid JSON")
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **token) }
      assert_equal 1, store.current.version
    end
  end

  def test_verification_commands_cannot_borrow_broadened_live_permissions
    with_revision(settings: { configure: ->(cfg, _) { cfg["permissions"] = "read-only" } }) do |service, _task, store, cfg|
      cfg["permissions"] = "yolo"
      check = { "id" => "behavior", "kind" => "behavior", "claim" => "run behavior", "command" => "ruby -e 'puts 1'" }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(verification_plans: { "qa" => [ check ] }, **expectation(service)) }
      assert_equal 1, store.current.version
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_concurrent_acceptances_publish_only_one_new_version
    with_revision do |service, task, store|
      token = expectation(service)
      proposals = %w[first second].map { |reason| service.propose(selections: [ "ui=off" ], reason: reason, **token).fetch("proposal_digest") }
      start = Queue.new
      outcomes = proposals.map do |digest|
        Thread.new do
          start.pop
          begin
            Hive::TaskCapabilities::Revision.new(task: task).accept(proposal_digest: digest, **token).fetch("status")
          rescue Hive::Error => error
            error
          end
        end
      end
      2.times { start << true }
      results = outcomes.map(&:value)
      assert_equal 1, results.count("accepted")
      assert_equal 1, results.count { |value| value.is_a?(Hive::Error) }
      assert_equal [ 1, 2 ], store.history.map(&:version)
    end
  end

  def test_snapshots_reconstruct_deleted_instructions_and_old_plans_cannot_borrow_new_authority
    settings = { configure: lambda { |cfg, dir|
      path = File.join(dir, "guidance.md")
      File.write(path, "Keep keyboard navigation")
      cfg["agents"]["claude"]["bin"] = "ruby"
      cfg["task_capabilities"]["catalog"] = [ { "id" => "notes", "kind" => "guidance", "stages" => [ "plan" ],
        "instruction" => path, "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" } } ]
    } }
    with_revision(settings: settings) do |service, task, store|
      File.unlink(File.join(task.project_root, "guidance.md"))
      proposal = service.propose(selections: [ "notes=on" ], **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      assert_equal "Keep keyboard navigation", store.current.data.fetch("bindings").find { |entry| entry["id"] == "notes" }.fetch("instruction_content")
      snapshot = store.current.data.fetch("definitions").find { |entry| entry["id"] == "notes" }
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Definition.from_snapshot(snapshot.merge("instruction_digest" => "a" * 64), stages: task.workflow.stages) }
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Definition.new(snapshot, stages: task.workflow.stages, source: "ordinary") }
      legacy = Hive::TaskCapabilities::Plan.new(store.current.to_h.merge("version" => 3, "policy" => store.current.data.fetch("policy").except("catalog_bindings", "verification_authority")))
      store.activate(legacy, expected_version: 2)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(selections: [ "ui=on" ], **expectation(service)) }
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(verification_plans: { "qa" => [] }, **expectation(service)) }
      assert_equal 3, store.current.version
    end
  end

  def test_legacy_revision_reads_leave_the_task_untouched
    with_tmp_dir do |dir|
      File.write(File.join(dir, "task.md"), "legacy")
      task = Struct.new(:folder).new(dir)
      service = Hive::TaskCapabilities::Revision.new(task: task)
      assert_equal({ "plan" => nil, "history" => [], "proposals" => [] }, service.show)
      assert_nil service.propose_from_signals!
      assert_nil service.activate_pending!
      assert_empty service.pending_guidance
      assert_equal [ "task.md" ], Dir.children(dir)
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_archived_cancelled_and_missing_worktree_tasks_keep_readable_history_without_mutation_tokens
    with_revision do |service, task, store|
      token = expectation(service)
      assert_nil service.record_guidance!(stage: "plan", plan_digest: store.current.digest)
      FileUtils.rm_rf(task.worktree_path)
      value = service.show
      assert_equal store.current.to_h, value.fetch("plan")
      assert_nil value.fetch("expected")
      assert_match(/Git revision is unavailable/, value.fetch("mutation_unavailable"))
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(selections: [ "ui=off" ], **token) }
      Hive::TaskCapabilities::ResultStore.new(task.folder).record_terminal!(disposition: "cancelled", reference: "hive drop")
      task.stage_name = "done"
      task.stage_index = task.workflow.stages.last.index
      value = service.show
      assert_nil value.fetch("expected")
      assert_match(/read-only/, value.fetch("mutation_unavailable"))
      assert_equal 1, value.fetch("history").size
      assert_raises(Hive::TaskCapabilities::Admission::Error) { service.waive(reason: "later", checks: [ "all" ], **token) }
      task.stage_index = 3
      assert_match(/cancelled/, service.show.fetch("mutation_unavailable"))
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_missing_skill_install_is_explicitly_pinned_and_install_drift_rejects_acceptance
    settings = ui_settings
    configure = settings.fetch(:configure)
    settings[:configure] = lambda do |cfg, dir|
      configure.call(cfg, dir)
      File.unlink(File.join(dir, ".claude/skills/ui-fixture/SKILL.md"))
    end
    with_revision(settings: settings) do |service, task, store, cfg|
      skill = File.join(task.project_root, ".claude/skills/ui-fixture/SKILL.md")
      with_replaced_singleton_method(Hive::Config, :load, ->(*) { cfg }) do
        missing = service.propose(selections: [ "ui=on" ], **expectation(service))
        assert_empty service.show.fetch("proposals").find { |entry| entry["proposal_digest"] == missing.fetch("proposal_digest") }.dig("input", "skill_updates")
        cfg["agents"]["claude"]["bin"] = "/changed-runtime"
        assert_raises(Hive::TaskCapabilities::Admission::Error) { service.propose(selections: [ "ui=on" ], **expectation(service)) }
        cfg["agents"]["claude"]["bin"] = "ruby"
        File.write(skill, "Installed guidance")
        proposal = service.propose(selections: [ "ui=on" ], **expectation(service))
        shown = service.show.fetch("proposals").find { |entry| entry["proposal_digest"] == proposal.fetch("proposal_digest") }
        assert_equal Digest::SHA256.file(skill).hexdigest, shown.dig("input", "skill_updates", "ui:plan", "digest")
        File.write(skill, "Changed after proposal")
        assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service)) }
        assert_equal 1, store.current.version
        File.write(skill, "Installed guidance")
        service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
        assert_empty store.current.data.fetch("blockers")
        pinned = store.current.data.fetch("bindings").find { |entry| entry["id"] == "ui" }.fetch("skill_identity")
        File.write(skill, "Later drift")
        second = service.propose(selections: [ "ui=on" ], **expectation(service))
        service.accept(proposal_digest: second.fetch("proposal_digest"), **expectation(service))
        assert_equal pinned, store.current.data.fetch("bindings").find { |entry| entry["id"] == "ui" }.fetch("skill_identity")
      end
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_successful_primary_spawn_records_delivery_after_guidance_reaches_the_actor
    settings = ui_settings
    configure = settings.fetch(:configure)
    settings[:configure] = lambda do |cfg, dir|
      configure.call(cfg, dir)
      cfg["agents"]["claude"]["bin"] = File.expand_path("../../fixtures/fake-claude", __dir__)
      cfg["plan"]["model"] = "approved"
      cfg["plan"]["effort"] = "high"
      cfg["task_capabilities"]["catalog"].first.fetch("actor")["effort"] = "high"
    end
    with_revision(settings: settings) do |service, task, store, cfg|
      proposal = service.propose(selections: [ "ui=on" ], **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      task.define_singleton_method(:log_dir) { File.join(folder, "logs") }
      task.define_singleton_method(:agent_pid_path) { File.join(folder, ".agent.pid") }
      with_capability_parent(task) do
        profile = Hive::AgentProfiles.lookup("claude", cfg: cfg)
        guidance, launch = Hive::Stages::Base.task_capability_guidance(task, cfg, stage: "plan", profile: profile,
          launch_arguments: Hive::Stages::Base.model_launch_arguments(cfg, "plan", profile, current: Hive::Stages::Base.model_routing_current(cfg["plan"])))
        assert_includes guidance, store.current.digest
        assert_includes guidance, "/ui-fixture"
        result = nil
        with_env("HIVE_FAKE_CLAUDE_OUTPUT" => JSON.generate("type" => "result", "subtype" => "success", "result" => "guidance received", "modelUsage" => { "approved" => {} }),
          "HIVE_FAKE_CLAUDE_WRITE_FILE" => task.state_file, "HIVE_FAKE_CLAUDE_WRITE_CONTENT" => "<!-- COMPLETE -->") do
          result = Hive::Stages::Base.spawn_claude!(task, cfg, prompt: guidance, profile: profile,
            add_dirs: [ task.folder ], cwd: task.project_root, max_budget_usd: 1, timeout_sec: 10, **launch)
        end
        assert_equal :complete, result.fetch(:status), result.inspect
      end
      assert_equal [ "execute" ], service.pending_guidance
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_review_completion_uses_the_same_signal_proposal_boundary
    with_verification do |_verification, _plan, _store, code, cfg, task, context|
      stage = Struct.new(:worktree_path, :pass).new(code, 1)
      response = nil
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        response = Hive::Stages::Review.complete_capability_verification(task, cfg, stage, started_at: Time.now, max_wall_clock_sec: 60)
      end
      assert_equal :review_complete, response.fetch(:status)
    end
  end

  def test_capability_prerequisite_changes_stale_dependent_proof
    check = { "id" => "behavior", "kind" => "behavior", "claim" => "observe behavior", "command" => "ruby -e 'puts 1'" }
    definitions = [ { "id" => "audit", "kind" => "verification", "stages" => [ "review" ], "checks" => [ check ] },
      { "id" => "qa", "kind" => "verification", "stages" => [ "review" ], "depends_on" => [ "audit" ], "checks" => [ check ] } ]
    with_revision(settings: { "catalog" => definitions }) do |service, task, store|
      proposal = service.propose(selections: [ "qa=on", "audit=on" ], **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      assert_empty store.current.data.fetch("blockers")
      results = Hive::TaskCapabilities::ResultStore.new(task.folder)
      plan = store.current
      environment = Hive::TaskCapabilities::Verification.environment(plan: plan)
      head = expectation(service).fetch(:expected_sha)
      plan.data.fetch("bindings").each do |binding|
        identity = Hive::TaskCapabilities::Verification.check_identity(plan: plan, binding: binding, check: binding.fetch("checks").first,
          context: Struct.new(:attempt_id).new("owner"), sha: head, environment: environment)
        results.accept(Hive::TaskCapabilities::Result.command(identity, exit_status: 0, output: "observed"))
      end
      proposal = service.propose(verification_plans: { "audit" => [ check.merge("command" => "ruby -e 'puts 2'") ] }, **expectation(service))
      service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      plan = store.current
      binding = plan.data.fetch("bindings").find { |entry| entry["id"] == "qa" }
      assert_equal "stale", results.current(binding: binding, check: binding.fetch("checks").first, plan: plan, sha: head, environment: environment).fetch("state")
      assert_equal 2, results.history.length
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_task_operator_approval_corrects_captured_security_without_a_reusable_project_approval
    settings = security_settings
    envelope = settings.fetch("approvals").fetch("local")
    settings.fetch("catalog").first.merge!(envelope.except("capability"))
    settings["approvals"] = {}
    with_revision(settings: settings, selections: [ "security=on" ]) do |service, task, store, cfg|
      assert store.current.data.fetch("blockers").any? { |entry| entry["reason"] == "task_capability_approval_required" }
      with_replaced_singleton_method(Hive::Config, :load, ->(*) { cfg }) do
        proposal = service.propose(selections: [ "security=on" ], task_approvals: [ "security=task-owner" ], **expectation(service))
        preview = proposal.fetch("approval_previews").first
        assert_equal "task-owner", preview.fetch("reference")
        assert_equal envelope.fetch("targets"), preview.dig("envelope", "targets")
        assert_match(/\A[0-9a-f]{64}\z/, preview.fetch("digest"))
        assert_equal 1, store.current.version
        path = File.join(task.folder, "capability-proposals", "#{proposal.fetch('proposal_digest')}.json")
        forged = JSON.parse(File.read(path))
        forged.fetch("input").fetch("approval_previews").first["digest"] = "a" * 64
        forged_bytes = Hive::WorkflowPackage::CanonicalJSON.generate(forged)
        forged_digest = Digest::SHA256.hexdigest(forged_bytes)
        File.write(File.join(File.dirname(path), "#{forged_digest}.json"), forged_bytes)
        assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: forged_digest, **expectation(service)) }
        cfg["agents"]["claude"]["bin"] = "/changed-runtime"
        assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service)) }
        cfg["agents"]["claude"]["bin"] = "ruby"
        with_attempt_context(attempt_id: "agent", task_generation: 0) do
          assert_raises(Hive::TaskCapabilities::Admission::Error) { service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service)) }
        end
        service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
        security = store.current.data.fetch("bindings").find { |entry| entry["id"] == "security" }
        assert_equal "task-owner", security.fetch("approval_reference")
        assert_empty store.current.data.fetch("blockers")
        approved = store.read_blob("approval", preview.fetch("digest"))
        assert_equal security.fetch("actor"), approved.dig("envelope", "actor")
        assert_equal security.fetch("permissions"), approved.dig("envelope", "permissions")
        assert Hive::TaskCapabilities::ActorRunner.available!(task: task, cfg: cfg, binding: security)
      end
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_task_approval_can_authorize_the_captured_unavailable_descriptor_without_blocking_unrelated_dispatch
    settings = security_settings
    envelope = settings.fetch("approvals").fetch("local")
    envelope.fetch("actor").merge!("provider_account" => "approved-account", "launch_binding" => "default")
    settings.fetch("catalog").first.merge!(envelope.except("capability"))
    settings["approvals"] = {}
    with_revision(settings: settings, selections: [ "security=on" ]) do |service, task, store, cfg|
      original = store.current.data.fetch("bindings").find { |entry| entry["id"] == "security" }.fetch("actor_route")
      assert original.fetch("unavailable")
      with_replaced_singleton_method(Hive::Config, :load, ->(*) { cfg }) do
        proposal = service.propose(task_approvals: [ "security=task-owner" ], **expectation(service))
        service.accept(proposal_digest: proposal.fetch("proposal_digest"), **expectation(service))
      end
      assert_equal original, store.current.data.fetch("bindings").find { |entry| entry["id"] == "security" }.fetch("actor_route")
      assert Hive::TaskCapabilities::Admission.enforce!(task)
      refute Hive::TaskCapabilities::Gate.new(task: task, cfg: cfg).evaluate.fetch("allowed")
      assert store.current.data.fetch("blockers").all? { |blocker| blocker["phase"] == "finalization" }
    end
  end
end

class TaskCapabilitiesRevisionTest
  def test_task_approval_cannot_supply_an_uncaptured_executor_or_scope
    with_revision do |service, _task, store|
      assert_raises(Hive::TaskCapabilities::Admission::Error) do
        service.propose(selections: [ "security=on" ], task_approvals: [ "security=task-owner" ], **expectation(service))
      end
      assert_equal 1, store.current.version
    end
  end
end
