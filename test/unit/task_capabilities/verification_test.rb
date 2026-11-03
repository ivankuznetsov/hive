require "test_helper"
require "hive/task_capabilities/verification"
require "hive/task_capabilities/resolver"
require "hive/attempts/dispatcher"
require_relative "../../support/task_capabilities_fixture"

class TaskCapabilitiesVerificationTest < Minitest::Test
  include HiveTestHelper

  include TaskCapabilitiesFixture

  def test_backend_behavior_runs_without_browser_and_accepts_bound_immutable_evidence
    with_verification do |verification, plan, store, code, _cfg, _task, context|
      result = verification.run!
      assert_equal "passed", result.fetch("state"), result.inspect
      check = result.fetch("checks").first
      assert_equal "passed", check.fetch("state")
      accepted = store.read_blob("result", check.fetch("result_digest"))
      assert_equal plan.digest, accepted.fetch("execution_plan_digest")
      assert_equal context.attempt_id, accepted.fetch("parent_attempt_id")
      assert_equal `git -C #{code} rev-parse HEAD`.strip, accepted.fetch("evaluated_sha")
      assert_equal 0, accepted.fetch("evidence").first.fetch("exit_status")
      assert_includes accepted.fetch("evidence").first.fetch("output"), "42"
      assert_equal "ci", accepted.fetch("check_id")
      assert_equal "behavior", accepted.fetch("kind")
      assert_equal result, verification.run!
    end
  end

  def test_unavailable_runner_is_blocked_and_a_real_failing_test_has_a_stable_actionable_finding
    with_verification(command: "missing-hive-verification-runner") do |verification|
      check = verification.run!.fetch("checks").first
      assert_equal "blocked", check.fetch("state")
      assert_includes check.dig("result", "reason"), "not runnable"
      assert_empty check.dig("result", "findings")
    end
    with_verification(command: "ruby -e 'warn :broken; exit 7'") do |verification|
      check = verification.run!.fetch("checks").first
      assert_equal "failed", check.fetch("state")
      assert_equal 7, check.dig("result", "evidence", 0, "exit_status")
      assert_equal "qa:ci:command-failed", check.dig("result", "findings", 0, "id")
      assert_includes check.dig("result", "findings", 0, "details"), "broken"
      assert_equal check.dig("result", "findings"), verification.run!.dig("checks", 0, "result", "findings")
    end
  end

  def test_review_only_and_empty_plans_cannot_pass_qa_and_whole_qa_waiver_is_visible
    [ [], [ { "id" => "review", "kind" => "source_review", "claim" => "Review source changes", "command" => "ruby -e 'exit 0'" } ] ].each do |checks|
      catalog = [ { "id" => "qa", "kind" => "verification", "stages" => [ "review" ], "checks" => checks } ]
      with_verification(command: nil, catalog: catalog) do |verification|
        assert_equal "blocked", verification.run!.fetch("state")
      end
    end
    with_verification(command: nil, selections: [ "qa=off" ], qa_waiver_reason: "Operator verifies rendered prose manually", qa_waiver_checks: [ "all" ]) do |verification|
      result = verification.run!
      assert_equal "waived", result.fetch("state")
      assert_equal true, result.dig("capabilities", 0, "waiver", "whole_gate")
      assert_empty result.dig("capabilities", 0, "waiver", "checks")
    end
  end

  def test_config_only_fourth_verifier_has_independent_identity_and_prose_checks_qualify
    fourth = { "id" => "link-checker", "kind" => "verification", "stages" => [ "review" ],
      "checks" => [ { "id" => "links", "kind" => "behavior", "claim" => "Prose contains a working local reference", "command" => "ruby -e 'abort unless File.read(%q{README.md}).include?(%q{example})'" } ] }
    with_verification(catalog: [ fourth ], selections: [ "link-checker=on" ]) do |verification|
      result = verification.run!
      assert_equal "passed", result.fetch("state")
      assert_equal [ "qa", "link-checker" ], result.fetch("capabilities").map { |entry| entry.fetch("id") }
      checks = result.fetch("checks")
      assert_equal %w[ci links], checks.map { |check| check.fetch("check_id") }
      refute_equal checks[0].fetch("result_digest"), checks[1].fetch("result_digest")
      assert_equal "link-checker", checks[1].dig("result", "capability_id")
    end
  end

  def test_dirty_or_changed_code_and_environment_never_reuse_a_success
    with_verification do |verification, plan, _store, code, _cfg, task, context|
      first = verification.run!.dig("checks", 0, "result_digest")
      File.write(File.join(code, "README.md"), "edited\n")
      result = verification.run!
      assert_equal "blocked", result.fetch("state")
      assert_includes result.dig("checks", 0, "result", "reason"), "clean"
      system("git", "-C", code, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-am", "changed", "-q", exception: true)
      projection = Hive::TaskCapabilities::ResultStore.new(task.folder).aggregate(plan: plan,
        sha: `git -C #{code} rev-parse HEAD`.strip, environment: Hive::TaskCapabilities::Verification.environment(plan: plan))
      assert_equal "stale", projection.fetch("state")
      refute_equal first, verification.run!.dig("checks", 0, "result_digest")
      prior = ENV["NODE_ENV"]
      ENV["NODE_ENV"] = "changed-test-environment"
      assert_equal "blocked", verification.run!.fetch("state")
      no_parent = Hive::TaskCapabilities::Verification.new(task: task, cfg: {}, worktree_path: code, context: nil)
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { no_parent.run! }
      assert_includes error.message, "--durable"
    ensure
      ENV["NODE_ENV"] = prior
    end
  end

  def test_a_command_that_changes_source_is_stale_even_when_it_exits_zero
    with_verification(command: "ruby -e 'File.write(%q{README.md}, %q{mutated})'") do |verification|
      result = verification.run!
      assert_equal "stale", result.fetch("state")
      assert_includes result.dig("checks", 0, "result", "reason"), "worktree bytes"
    end
  end

  def test_warned_browser_or_passed_json_alone_cannot_satisfy_a_planned_check
    with_verification do |verification|
      browser = Hive::Stages::Review::BrowserTest::Result.new(status: :warned, attempts: 1, summary: "not available", details: nil, error_message: nil)
      result = verification.run!(existing_results: { [ "qa", "ci" ] => browser })
      assert_equal "blocked", result.fetch("state")
    end
    with_verification do |verification|
      result = verification.run!(existing_results: { [ "qa", "ci" ] => { "status" => "passed" } })
      assert_equal "blocked", result.fetch("state")
    end
  end

  def test_actor_verifier_accepts_hash_checked_proof_and_keeps_real_parent_and_spawn_identity
    with_verification(catalog: [ actor_definition ], selections: [ "audit=on" ]) do |verification, _plan, store, _code, _cfg, task, context, attempts|
      response = lambda do |_task, _args, proposal|
        optional = Marshal.load(Marshal.dump(proposal.fetch("evidence").first))
        optional["kind"] = "screenshot"
        optional["representations"].each { |entry| entry.merge!("media_type" => "image/png", "path" => "missing-#{entry.fetch('role')}.png") }
        proposal.fetch("evidence") << optional
        JSON.generate(proposal)
      end
      result = with_actor_response(response) { verification.run! }
      assert_equal "passed", result.fetch("state"), result.inspect
      actor = result.fetch("checks").find { |check| check["capability_id"] == "audit" }.fetch("result")
      assert_equal context.attempt_id, actor.fetch("parent_attempt_id")
      assert_match(/\A[0-9a-f-]{36}\z/, actor.fetch("spawn_id"))
      assert_equal "approved", store.current.data.fetch("bindings").find { |binding| binding["id"] == "audit" }.dig("actor", "model")
      assert_includes actor.fetch("reason"), "optional screenshot/video capture unavailable"
      no_spawn = Hive::TaskCapabilities::Result.new(actor.merge("spawn_id" => nil))
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { Hive::TaskCapabilities::ResultStore.new(task.folder).accept(no_spawn) }
      refute File.exist?(File.join(task.folder, "capability-source"))
      retained = actor.dig("evidence", 0, "proof", "representations", 0)
      assert File.file?(File.join(task.folder, retained.fetch("path")))
      assert_equal 1, attempts.database.read { |db| db[:attempts].count }
      assert_equal result, verification.run!
      File.write(File.join(task.folder, retained.fetch("path")), "tampered")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) { verification.run! }
    end
  end

  def test_agent_missing_malformed_wrong_identity_or_tampered_proposals_block
    responses = [ ->(*) { nil }, ->(*) { "not JSON" }, ->(*) { "[]" }, ->(*) { "{}" },
      ->(_task, _args, proposal) { JSON.generate(proposal.merge("evaluated_sha" => "f" * 40)) },
      ->(_task, _args, proposal) { JSON.generate(proposal.merge("evidence" => nil)) },
      ->(_task, _args, proposal) { JSON.generate(proposal.merge("evidence" => [])) },
      ->(_task, _args, proposal) { proposal.dig("evidence", 0)["claims"] = [ "other-check" ]; JSON.generate(proposal) },
      ->(_task, _args, proposal) { proposal.dig("evidence", 0, "representations", 0)["sha256"] = "0" * 64; JSON.generate(proposal) } ]
    responses.each do |response|
      with_verification(catalog: [ actor_definition ], selections: [ "audit=on" ]) do |verification|
        result = with_actor_response(response) { verification.run! }
        assert_equal "blocked", result.fetch("state")
        check = result.fetch("checks").find { |item| item["capability_id"] == "audit" }
        assert_equal "blocked", check.fetch("state")
        refute_nil check.dig("result", "spawn_id")
        assert_equal "passed", result.fetch("checks").find { |item| item["capability_id"] == "qa" }.fetch("state")
      end
    end
  end

  def test_individual_not_applicable_has_evidence_but_all_na_never_passes_whole_qa
    check = { "id" => "ui", "kind" => "behavior", "claim" => "Exercise the rendered UI behavior", "provider" => "independent-actor" }
    response = ->(_task, _args, proposal) { JSON.generate(proposal.merge("state" => "not-applicable", "applicability" => { "reason" => "No UI changed; source snapshot documents the backend only scope" })) }
    with_verification(command: nil, catalog: [ actor_definition(id: "qa", checks: [ check ]) ]) do |verification|
      result = with_actor_response(response) { verification.run! }
      assert_equal "blocked", result.fetch("state")
      assert_equal "not-applicable", result.dig("checks", 0, "state"), result.inspect
      assert_includes result.dig("checks", 0, "result", "applicability", "reason"), "No UI changed"
      refute_empty result.dig("checks", 0, "result", "evidence")
    end
  end

  def test_existing_controller_ci_uses_the_same_contract_and_rejects_the_wrong_sha
    with_verification(command: "ruby -rsecurerandom -e 'puts SecureRandom.hex(8)'") do |verification, plan, _store, code, cfg, _task, context|
      environment = Hive::TaskCapabilities::Verification.environment(plan: plan)
      run = Hive::Stages::Review::CiFix.run_ci_once(cfg.dig("review", "ci", "command"), code, 262_144, 5)
      sha = `git -C #{code} rev-parse HEAD`.strip
      observations = Hive::TaskCapabilities::Verification.ci_observations(plan: plan, cfg: cfg, context: context, sha: sha, environment: environment, output: run.combined)
      assert_equal 1, observations.size
      result = verification.run!(existing_results: observations)
      assert_equal "passed", result.fetch("state")
      assert_equal run.combined, result.dig("checks", 0, "result", "evidence", 0, "output")
      cfg["timeout_sec"]["review_ci"] += 1
      assert_empty Hive::TaskCapabilities::Verification.ci_observations(plan: plan, cfg: cfg, context: context, sha: sha, environment: environment, output: "untrusted")
      assert_empty Hive::TaskCapabilities::Verification.ci_observations(plan: nil, cfg: cfg, context: context, sha: sha, environment: environment, output: "untrusted")
    end
    with_verification do |verification, plan, _store, _code, cfg, _task, context|
      observations = Hive::TaskCapabilities::Verification.ci_observations(plan: plan, cfg: cfg, context: context, sha: "f" * 40,
        environment: Hive::TaskCapabilities::Verification.environment(plan: plan), output: "green on the wrong commit")
      result = verification.run!(existing_results: observations)
      assert_equal "blocked", result.fetch("state")
      assert_includes result.dig("checks", 0, "result", "reason"), "another revision"
    end
  end

  def test_ui_browser_proof_qualifies_without_screenshot_and_preserves_independent_pinned_actor
    configure = lambda do |cfg, dir|
      cfg["review"]["browser_test"].merge!("enabled" => true, "model" => "browser-model", "effort" => "high")
      skill = File.join(dir, ".claude/skills/ce-test-browser/SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill))
      File.write(skill, "# Browser behavior verification\n")
    end
    with_verification(configure: configure) do |verification, plan, _store, code, _cfg, task, context|
      binding = plan.data.fetch("bindings").first
      check = binding.fetch("checks").find { |entry| entry["id"] == "browser" }
      actor = check.dig("runner", "actor_binding")
      assert_equal "browser-model", actor.dig("actor", "model")
      assert_equal "high", actor.dig("actor", "effort")
      result = with_actor_response { verification.run! }
      assert_equal "passed", result.fetch("state")
      accepted = result.fetch("checks").find { |entry| entry["check_id"] == "browser" }.fetch("result")
      assert_equal "document", accepted.dig("evidence", 0, "proof", "kind")
      refute_nil accepted.fetch("spawn_id")
      typed = Hive::TaskCapabilities::Result.new(accepted)
      browser = Hive::Stages::Review::BrowserTest::Result.new(status: :passed, attempts: 1, summary: "UI behavior exercised", details: "Document transcript retained; no screenshot available", error_message: nil, verification: typed)
      assert_same typed, Hive::Stages::Review::BrowserTest.verification_proposal(browser)
    end
  end

  def test_missing_browser_route_and_check_dependencies_block_only_their_checks
    checks = [ { "id" => "after", "kind" => "behavior", "claim" => "Dependent behavior", "command" => "ruby -e 'exit 0'", "depends_on" => [ "first" ] },
      { "id" => "first", "kind" => "behavior", "claim" => "Required behavior", "command" => "ruby -e 'exit 1'" } ]
    configure = ->(cfg, _dir) { cfg["review"]["browser_test"]["enabled"] = true }
    fourth = { "id" => "ordered", "kind" => "verification", "stages" => [ "review" ], "checks" => checks }
    with_verification(catalog: [ fourth ], selections: [ "ordered=on" ], configure: configure) do |verification|
      result = verification.run!
      assert_equal "blocked", result.fetch("state")
      by_id = result.fetch("checks").to_h { |entry| [ entry.fetch("check_id"), entry ] }
      assert_equal "passed", by_id.fetch("ci").fetch("state")
      assert_equal "blocked", by_id.fetch("browser").fetch("state")
      assert_equal "failed", by_id.fetch("first").fetch("state")
      assert_equal "blocked", by_id.fetch("after").fetch("state")
      assert_includes by_id.fetch("after").dig("result", "reason"), "prerequisites"
    end
  end

  def test_custom_legacy_browser_requirements_are_not_silently_replaced_by_default_skill
    configure = ->(cfg, _dir) { cfg["review"]["browser_test"].merge!("enabled" => true, "prompt_template" => "custom-browser.erb") }
    with_verification(configure: configure) do |verification|
      result = verification.run!
      browser = result.fetch("checks").find { |check| check["check_id"] == "browser" }
      assert_equal "blocked", browser.fetch("state")
      assert_includes browser.dig("result", "reason"), "explicit configured verification check"
    end
  end

  def test_unavailable_security_does_not_stop_unrelated_verification_and_never_falls_back
    security = actor_definition(id: "security")
    security["permissions"] = { "tools" => [ "Read" ], "commands" => [], "domains" => [] }
    security.fetch("actor").merge!("provider_account" => "absent", "launch_binding" => "approved")
    approval = security.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => "security")
    configure = ->(cfg, _dir) { cfg["task_capabilities"]["approvals"] = { "approved" => approval } }
    with_verification(catalog: [ security ], selections: [ "security=on" ], approval_references: [ "security=approved" ], configure: configure) do |verification|
      result = verification.run!
      assert_equal "blocked", result.fetch("state")
      assert_equal "passed", result.fetch("checks").find { |check| check["capability_id"] == "qa" }.fetch("state")
      security_result = result.fetch("checks").find { |check| check["capability_id"] == "security" }.fetch("result")
      assert_equal "blocked", security_result.fetch("state")
      assert_includes security_result.fetch("reason"), "restore the approved route"
      assert_nil security_result.fetch("spawn_id")
    end
  end

  def test_accepted_result_schema_and_protected_chain_fail_closed
    with_verification do |verification, plan, store, code, _cfg, task|
      result = verification.run!.dig("checks", 0, "result")
      [ { "task" => {} }, { "state" => "invented" }, { "evidence" => [] },
        { "evidence" => [ result.fetch("evidence").first.merge("kind" => "invented") ] },
        { "evidence" => [ result.fetch("evidence").first.merge("sha256" => "0" * 64) ] },
        { "state" => "not-applicable", "applicability" => {} }, { "state" => "failed", "findings" => [] },
        { "runner" => nil }, { "runner" => { "targets" => [ "../outside" ] } }, { "parent_attempt_id" => "" }, { "schema_version" => 2 } ].each do |mutation|
        assert_raises(Hive::TaskCapabilities::Result::Invalid) { Hive::TaskCapabilities::Result.new(result.merge(mutation)) }
      end
      results = Hive::TaskCapabilities::ResultStore.new(task.folder)
      inconsistent = Hive::TaskCapabilities::Result.new(result.merge("claim" => "A different check claim"))
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.accept(inconsistent) }
      missing_exit = Hive::TaskCapabilities::Result.new(result.merge("evidence" => [ { "kind" => "outcome", "evaluated_sha" => result.fetch("evaluated_sha"), "proof" => {} } ]))
      assert_raises(Hive::TaskCapabilities::Result::Invalid) { results.accept(missing_exit) }
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { store.blobs("unknown") }
      current = results.history.last.last
      bytes = Hive::WorkflowPackage::CanonicalJSON.generate(current.data.merge("parent_attempt_id" => "agent-invented"))
      digest = Digest::SHA256.hexdigest(bytes)
      File.write(File.join(task.folder, "capability-results", "#{digest}.json"), bytes)
      refute_includes results.history.map(&:first), digest
      assert_equal "passed", results.aggregate(plan: plan, sha: `git -C #{code} rev-parse HEAD`.strip,
        environment: Hive::TaskCapabilities::Verification.environment(plan: plan)).fetch("state")
      File.write(File.join(task.folder, "capability-results", "#{current.digest}.json"), "{}")
      assert_raises(Hive::TaskCapabilities::Store::InvalidState) { results.history }
    end
  end

  def test_actor_unavailable_and_unowned_snapshot_targets_block_without_hiding_other_checks
    with_verification(catalog: [ actor_definition ], selections: [ "audit=on" ]) do |verification, _plan, _store, _code, _cfg, task|
      response = ->(*) { { status: :error, error_reason: "fixture_unavailable" } }
      result = with_actor_response(response) { verification.run! }
      actor = result.fetch("checks").find { |check| check["capability_id"] == "audit" }.fetch("result")
      assert_equal "blocked", actor.fetch("state")
      refute_nil actor.fetch("spawn_id")
      assert_includes actor.fetch("reason"), "fixture_unavailable"
      FileUtils.mkdir_p(File.join(task.folder, "capability-source"))
      result = verification.run!
      assert_equal "passed", result.fetch("checks").find { |check| check["capability_id"] == "qa" }.fetch("state")
      assert_includes result.fetch("checks").find { |check| check["capability_id"] == "audit" }.dig("result", "reason"), "outside the repository worktree registry"
    end
  end

  def test_hard_required_qa_off_and_a_plan_without_checks_remain_blocked
    configure = ->(cfg, _dir) { cfg["task_capabilities"]["policy"] = { "required" => [ "qa" ] } }
    with_verification(configure: configure, selections: [ "qa=off" ], qa_waiver_reason: "Requested exception", qa_waiver_checks: [ "all" ]) do |verification, plan, store, code, _cfg, task|
      result = verification.run!
      assert_equal "blocked", result.fetch("state")
      assert_empty plan.data.fetch("waivers")
      empty = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("version" => 2, "bindings" => [], "waivers" => [], "blockers" => []))
      store.activate(empty, expected_version: 1)
      assert_equal "blocked", Hive::TaskCapabilities::ResultStore.new(task.folder).aggregate(plan: empty,
        sha: `git -C #{code} rev-parse HEAD`.strip, environment: Hive::TaskCapabilities::Verification.environment(plan: empty)).fetch("state")
    end
  end

  def test_deadline_or_cancelled_parent_and_signal_exit_are_blocked_not_failed_tests
    with_verification do |_verification, _plan, _store, code, cfg, task, context|
      verification = Hive::TaskCapabilities::Verification.new(task: task, cfg: cfg, worktree_path: code, context: context, timeout_sec: 0)
      assert_equal "blocked", verification.run!.fetch("state")
      context.close
      verification = Hive::TaskCapabilities::Verification.new(task: task, cfg: cfg, worktree_path: code, context: context)
      assert_raises(Hive::Attempts::RepositoryError) { verification.run! }
    end
    with_verification(command: "ruby -e 'Process.kill(%q{TERM}, Process.pid)'") do |verification|
      result = verification.run!
      assert_equal "blocked", result.fetch("state")
      assert_includes result.dig("checks", 0, "result", "reason"), "without an exit status"
    end
  end

  def test_independent_findings_and_command_output_are_redacted_before_acceptance
    with_verification(command: "ruby -e 'puts %q{ghp_} + %q{a} * 36; exit 2'") do |verification, _plan, store|
      check = verification.run!.dig("checks", 0)
      result = store.read_blob("result", check.fetch("result_digest"))
      assert_includes result.dig("evidence", 0, "output"), "[REDACTED:github_token]"
      refute_includes JSON.generate(result), "ghp_#{'a' * 36}"
    end
    response = lambda do |_task, _args, proposal|
      JSON.generate(proposal.merge("state" => "failed", "findings" => [ { "id" => "reference-mismatch", "severity" => "medium",
        "summary" => "Reference content differs from the expected prose", "details" => "Replace the mismatched reference in README.md; observed token ghp_#{'a' * 36}" } ]))
    end
    with_verification(catalog: [ actor_definition ], selections: [ "audit=on" ]) do |verification|
      result = with_actor_response(response) { verification.run! }
      assert_equal "failed", result.fetch("state")
      finding = result.fetch("checks").find { |check| check["capability_id"] == "audit" }.dig("result", "findings", 0)
      assert_equal "reference-mismatch", finding.fetch("id")
      assert_includes finding.fetch("details"), "[REDACTED:github_token]"
    end
  end

  def test_multiple_actor_checks_share_one_finite_parent_envelope
    checks = %w[first second].map { |id| { "id" => id, "kind" => "source_review", "claim" => "Check the #{id} source requirement", "provider" => "actor" } }
    with_verification(catalog: [ actor_definition(checks: checks) ], selections: [ "audit=on" ]) do |_verification, _plan, _store, code, cfg, task, context|
      verification = Hive::TaskCapabilities::Verification.new(task: task, cfg: cfg, worktree_path: code, context: context, budget_usd: 1, timeout_sec: 20)
      calls = 0
      response = ->(_task, _args, proposal) { calls += 1; JSON.generate(proposal) }
      result = with_actor_response(response) { verification.run! }
      assert_equal 1, calls
      assert_equal "passed", result.fetch("checks").find { |check| check["check_id"] == "first" }.fetch("state")
      second = result.fetch("checks").find { |check| check["check_id"] == "second" }
      assert_equal "blocked", second.fetch("state")
      assert_includes second.dig("result", "reason"), "resource envelope is exhausted"
    end
  end
end
