require "test_helper"
require "hive/task_capabilities/resolver"

class TaskCapabilitiesResolverTest < Minitest::Test
  include HiveTestHelper

  def config
    Marshal.load(Marshal.dump(Hive::Config::DEFAULTS)).tap { |cfg| cfg["task_capabilities"]["enabled"] = true }
  end

  def resolver(cfg = config, **options)
    Hive::TaskCapabilities::Resolver.new(workflow: Hive::Workflows::Coding::DESCRIPTOR, cfg: cfg, **options)
  end

  def test_automatic_qa_is_selected_and_disabled_verification_is_a_durable_blocker
    preview = resolver.preview
    assert_equal "on", preview.dig("choices", "qa", "effective")
    assert_equal "off", preview.dig("choices", "security", "effective")
    assert preview.fetch("recommendations").any? { |entry| entry["id"] == "ui" }
    assert_includes preview.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_verification_unavailable"
  end

  def test_task_creator_can_waive_all_qa_without_a_standing_exception
    preview = resolver.preview(selections: [ "qa=off" ], qa_waiver_reason: "docs only", qa_waiver_checks: [ "all" ])
    assert_empty preview.fetch("blockers")
    assert_equal "waived", preview.dig("choices", "qa", "state")
    assert_equal "on", resolver.preview.dig("choices", "qa", "effective")
    assert_raises(Hive::TaskCapabilities::Admission::Error) { resolver.preview(selections: [ "qa=off" ]) }
  end

  def test_hard_policy_conflict_blocks_and_explicit_ui_off_beats_signal
    cfg = config
    cfg["task_capabilities"]["policy"] = { "required" => [ "qa" ], "auto_select" => [
      { "capability" => "ui", "signals" => [ { "type" => "task_text", "value" => "screen" } ] }
    ] }
    preview = resolver(cfg).preview(selections: [ "qa=off", "ui=off" ], qa_waiver_reason: "reason", qa_waiver_checks: [ "all" ], task_text: "new screen")
    assert_equal "off", preview.dig("choices", "ui", "effective")
    assert_includes preview.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_policy_conflict"
  end

  def test_invalid_client_choices_are_errors
    [ [ "unknown=on" ], [ "qa=maybe" ], [ "qa=on", "qa=off" ], [ "qa" ] ].each do |choices|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { resolver.preview(selections: choices) }
    end
  end

  def test_usable_ci_behavior_check_and_fresh_preview_build_the_same_pinned_plan
    cfg = config
    cfg["review"]["ci"]["command"] = "bin/test"
    r = resolver(cfg)
    preview = r.preview
    assert_empty preview.fetch("blockers")
    result = r.resolve(task_identity: { "id" => "1", "slug" => "some-task", "workflow" => "coding" }, expected_preview: preview.fetch("preview_digest"))
    assert_equal preview.fetch("choices"), result.plan.data.fetch("choices")
    cfg["review"]["ci"]["command"] = "bin/other-test"
    assert_raises(Hive::TaskCapabilities::Admission::Error) do
      resolver(cfg).resolve(task_identity: { "id" => "1", "slug" => "some-task", "workflow" => "coding" }, expected_preview: preview.fetch("preview_digest"))
    end
  end
end

class TaskCapabilitiesResolverTest
  def qa_check
    { "id" => "behavior", "kind" => "behavior", "claim" => "fixture behavior", "command" => "ruby check.rb" }
  end

  def security_definition
    { "id" => "security", "kind" => "verification", "stages" => [ "review" ], "checks" => [ qa_check ] }
  end

  def security_envelope
    { "capability" => "security", "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" },
      "permissions" => { "tools" => [ "Read", "Bash" ], "commands" => [ "ruby check.rb" ], "domains" => [] },
      "targets" => [ "fixtures/local" ], "budget_usd" => 3, "timeout_sec" => 60 }
  end

  def test_tri_state_matrix_preserves_explicit_choices_and_never_auto_enables_security
    %w[automatic on off].repeated_permutation(3).each do |qa, ui, security|
      options = { selections: [ "qa=#{qa}", "ui=#{ui}", "security=#{security}" ] }
      options.merge!(qa_waiver_reason: "operator reason", qa_waiver_checks: [ "all" ]) if qa == "off"
      preview = resolver.preview(**options)
      assert_equal qa == "automatic" ? "on" : qa, preview.dig("choices", "qa", "effective")
      assert_equal ui == "automatic" ? "off" : ui, preview.dig("choices", "ui", "effective")
      assert_equal security == "automatic" ? "off" : security, preview.dig("choices", "security", "effective")
    end
  end

  def test_selected_installed_ui_skill_pins_identity_and_policy_signals
    with_tmp_dir do |root|
      path = File.join(root, ".claude/skills/ui-fixture/SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# UI fixture\n")
      cfg = config
      cfg["review"]["ci"]["command"] = "ruby check.rb"
      binary = File.join(root, "fixture-executor")
      File.write(binary, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, binary)
      cfg["agents"]["claude"]["bin"] = binary
      cfg["task_capabilities"]["catalog"] = [ { "id" => "ui", "kind" => "guidance", "stages" => %w[plan execute], "skill" => "ui-fixture", "actor" => security_envelope.fetch("actor") } ]
      cfg["task_capabilities"]["policy"] = { "auto_select" => [ { "capability" => "ui", "signals" => [ { "type" => "task_text", "value" => "screen" } ] } ] }
      preview = resolver(cfg, project_root: root).preview(task_text: "add screen")
      assert_empty preview.fetch("blockers")
      assert_equal "policy-signal", preview.dig("choices", "ui", "source")
      assert_equal "screen", preview.dig("choices", "ui", "signals", 0, "matched")
      bindings = preview.fetch("bindings").select { |entry| entry["id"] == "ui" }
      assert_equal %w[plan execute], bindings.map { |entry| entry.fetch("stage") }
      assert_equal Digest::SHA256.file(path).hexdigest, bindings.first.dig("skill_identity", "digest")
      File.unlink(path)
      missing = resolver(cfg, project_root: root).preview(selections: [ "ui=on" ])
      assert_includes missing.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_missing_skill"
    end
  end

  def test_security_missing_approval_blocks_but_an_unavailable_approved_route_only_blocks_finalization
    cfg = config
    cfg["review"]["ci"]["command"] = "ruby check.rb"
    cfg["task_capabilities"]["catalog"] = [ security_definition ]
    cfg["task_capabilities"]["approvals"] = { "local" => security_envelope }
    cfg["agents"]["claude"]["bin"] = "/missing-approved-security-route"
    r = resolver(cfg)
    missing = r.preview(selections: [ "security=on" ])
    assert_includes missing.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_approval_required"
    approved = r.resolve(task_identity: { "id" => "1", "slug" => "task", "workflow" => "coding" }, selections: [ "security=on" ], approval_references: [ "security=local" ])
    blocker = approved.preview.fetch("blockers").find { |entry| entry["reason"] == "task_capability_route_unavailable" }
    assert_equal "finalization", blocker.fetch("phase")
    assert_includes blocker.fetch("message"), "restore the approved route"
    assert_equal security_envelope.fetch("actor").merge("launch_binding" => "default"), approved.plan.data.fetch("bindings").find { |entry| entry["id"] == "security" }.fetch("actor")
    assert_equal 1, approved.approvals.length
    assert_equal Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(approved.approvals.first)), approved.plan.data.fetch("approvals").first.fetch("digest")
    cfg["agents"]["claude"]["bin"] = "ruby"
    restored = resolver(cfg).preview(selections: [ "security=on" ], approval_references: [ "security=local" ])
    assert_empty restored.fetch("blockers")
    cfg["task_capabilities"]["catalog"].first["actor"] = security_envelope.fetch("actor").merge("model" => "unapproved")
    scope = resolver(cfg).preview(selections: [ "security=on" ], approval_references: [ "security=local" ])
    assert_includes scope.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_approval_scope"
    assert_raises(Hive::TaskCapabilities::Admission::Error) { r.preview(approval_references: [ "security=unknown" ]) }
  end

  def test_fourth_configuration_only_verifier_uses_generic_binding_and_dependencies
    cfg = config
    cfg["review"]["ci"]["command"] = "ruby check.rb"
    cfg["task_capabilities"]["catalog"] = [ { "id" => "accessibility", "kind" => "verification", "stages" => [ "review" ], "checks" => [ qa_check ], "depends_on" => [ "qa" ] } ]
    valid = resolver(cfg).preview(selections: [ "accessibility=on" ])
    assert_empty valid.fetch("blockers")
    assert_equal %w[qa accessibility], valid.fetch("bindings").map { |entry| entry.fetch("id") }
    conflict = resolver(cfg).preview(selections: [ "qa=off", "accessibility=on" ], qa_waiver_reason: "reason", qa_waiver_checks: [ "all" ])
    assert_includes conflict.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_blocked"
  end

  def test_waiver_must_cover_all_planned_checks_and_redacts_operator_text
    cfg = config
    cfg["task_capabilities"]["catalog"] = [ { "id" => "qa", "kind" => "verification", "stages" => [ "review" ], "checks" => [ qa_check, qa_check.merge("id" => "other") ] } ]
    r = resolver(cfg)
    assert_raises(Hive::TaskCapabilities::Admission::Error) { r.preview(selections: [ "qa=off" ], qa_waiver_reason: "reason", qa_waiver_checks: [ "behavior" ]) }
    preview = r.preview(selections: [ "qa=off" ], qa_waiver_reason: "ghp_abcdefghijklmnopqrstuvwxyz0123456789", qa_waiver_checks: %w[behavior other])
    refute_includes JSON.generate(preview), "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    [ { qa_waiver_reason: "unexpected" }, { qa_waiver_checks: "all" }, { qa_waiver_checks: [ "all", "behavior" ] }, { selections: nil }, { selections: [ nil ] }, { approval_references: [ "security=" ] }, { selections: [ "qa=" ] } ].each do |options|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { r.preview(**options) }
    end
  end

  def test_review_only_empty_unusable_and_browser_checks_remain_distinct
    cfg = config
    cfg["task_capabilities"]["catalog"] = [ { "id" => "qa", "kind" => "verification", "stages" => [ "review" ], "checks" => [ qa_check.merge("kind" => "source_review") ] } ]
    assert_includes resolver(cfg).preview.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_verification_unavailable"
    cfg["task_capabilities"]["catalog"].first["checks"] = [ qa_check.reject { |key, _| key == "command" } ]
    assert_includes resolver(cfg).preview.fetch("blockers").map { |entry| entry["reason"] }, "task_capability_verification_unavailable"
    cfg["task_capabilities"]["catalog"] = []
    cfg["review"]["browser_test"]["enabled"] = true
    preview = resolver(cfg).preview
    assert_empty preview.fetch("blockers")
    assert_equal "browser", preview.fetch("bindings").first.fetch("checks").first.fetch("id")
  end
end

class TaskCapabilitiesResolverTest
  def test_preview_freshness_includes_all_input_signals_even_without_a_policy_match
    r = resolver
    preview = r.preview(task_text: "first task")
    assert_raises(Hive::TaskCapabilities::Admission::Error) do
      r.resolve(task_identity: { "id" => "1", "slug" => "task", "workflow" => "coding" }, task_text: "second task", expected_preview: preview.fetch("preview_digest"))
    end
    assert_match(/\A[0-9a-f]{64}\z/, preview.fetch("input_digest"))
  end

  def test_custom_guidance_pins_instruction_and_inherited_envelope_without_a_fake_skill
    with_tmp_dir do |root|
      instruction = File.join(root, "guidance.md")
      File.write(instruction, "# Repository guidance\n")
      cfg = config
      cfg["agents"]["claude"]["bin"] = "ruby"
      cfg["task_capabilities"]["catalog"] = [ { "id" => "writing", "kind" => "guidance", "stages" => [ "plan" ], "instruction" => instruction, "actor" => security_envelope.fetch("actor") } ]
      preview = resolver(cfg).preview(selections: [ "qa=off", "writing=on" ], qa_waiver_reason: "operator reason", qa_waiver_checks: [ "all" ])
      assert_empty preview.fetch("blockers")
      binding = preview.fetch("bindings").first
      assert_equal "# Repository guidance\n", binding.fetch("instruction_content")
      assert_equal cfg.fetch("permissions"), binding.fetch("permissions")
      assert_equal 100, binding.fetch("budget_usd")
      assert_equal 3600, binding.fetch("timeout_sec")
      assert_match(/\A[0-9a-f]{64}\z/, binding.fetch("actor_fingerprint"))
      cfg["agents"]["claude"]["bin"] = "/missing/executor"
      unavailable = resolver(cfg).preview(selections: [ "writing=on" ])
      assert unavailable.fetch("blockers").any? { |entry| entry["capability"] == "writing" && entry["reason"] == "task_capability_blocked" }
      cfg["task_capabilities"]["catalog"].first.delete("actor")
      assert resolver(cfg).preview(selections: [ "writing=on" ]).fetch("blockers").any? { |entry| entry["capability"] == "writing" }
    end
  end

  def test_approval_payloads_must_name_the_selected_capability_and_active_attempts_cannot_approve
    cfg = config
    cfg["task_capabilities"]["approvals"] = { "local" => security_envelope }
    r = resolver(cfg)
    assert_raises(Hive::TaskCapabilities::Admission::Error) { r.preview(approval_references: [ "security=local" ]) }
    assert_raises(Hive::TaskCapabilities::Admission::Error) { r.preview(selections: [ "ui=on" ], approval_references: [ "ui=local" ]) }
    with_attempt_context(attempt_id: "actor", task_generation: 0) do
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) do
        r.resolve(task_identity: { "id" => "1", "slug" => "task", "workflow" => "coding" }, selections: [ "security=on" ])
      end
      assert_equal "task_capability_operator_required", error.reason
    end
  end
end

class TaskCapabilitiesResolverTest
  def test_hard_required_ui_selects_automatically_but_cannot_expand_existing_stage_bounds
    cfg = config
    cfg["task_capabilities"]["policy"] = { "required" => %w[qa ui] }
    cfg["task_capabilities"]["catalog"] = [ { "id" => "ui", "kind" => "guidance", "stages" => %w[plan execute], "budget_usd" => 1000 } ]
    preview = resolver(cfg).preview
    assert_equal "hard-policy", preview.dig("choices", "qa", "source")
    assert_equal "on", preview.dig("choices", "ui", "effective")
    assert preview.fetch("blockers").any? { |entry| entry["capability"] == "ui" && entry["reason"] == "task_capability_policy_conflict" }
    [ { task_text: nil }, { repository_paths: nil }, { task_labels: [ 1 ] }, { changed_paths: "web/a.rb" } ].each do |inputs|
      assert_raises(Hive::TaskCapabilities::Admission::Error) { resolver.preview(**inputs) }
    end
  end
end

class TaskCapabilitiesResolverTest
  def test_forbidden_qa_off_is_blocked_and_retains_only_a_rejected_exception_request
    cfg = config
    cfg["task_capabilities"]["policy"] = { "required" => [ "qa" ] }
    preview = resolver(cfg).preview(selections: [ "qa=off" ], qa_waiver_reason: "operator request", qa_waiver_checks: [ "all" ])
    assert_equal "off", preview.dig("inputs", "qa")
    assert_equal "blocked", preview.dig("choices", "qa", "state")
    assert_equal "operator request", preview.dig("choices", "qa", "requested_waiver", "reason")
    assert_empty preview.fetch("waivers")
  end

  def test_automatic_ui_normalizes_presets_and_accepts_only_provable_scope_narrowing
    with_tmp_dir do |root|
      path = File.join(root, ".claude/skills/ui-fixture/SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# UI fixture\n")
      read = %w[Read LS Grep Glob]
      cases = [
        [ { "tools" => "invalid-shape" }, "read-only", false ],
        [ { "preset" => "yolo" }, "read-only", true ],
        [ "yolo", { "preset" => "yolo" }, true ],
        [ "read-only", { "preset" => "read-only" }, true ],
        [ { "preset" => "scoped", "tools" => read + [ "Edit" ], "dirs" => [ "reports", "../shared" ] }, { "preset" => "scoped", "tools" => [ "Read" ], "dirs" => [ "reports/sub", "../shared/child" ] }, true ],
        [ { "tools" => read + [ "Bash" ], "commands" => [ "ruby *" ], "directories" => [ "reports" ] }, "read-only", true ],
        [ { "tools" => read + [ "Bash" ], "commands" => [ "ruby *" ] }, { "tools" => [ "Read", "Bash" ], "commands" => [ "ruby check.rb" ] }, true ],
        [ "read-only", "yolo", false ],
        [ "read-only", { "preset" => "scoped", "tools" => [ "Edit" ] }, false ],
        [ { "preset" => "scoped", "tools" => read, "dirs" => [ "reports" ] }, { "preset" => "scoped", "tools" => [ "Read" ], "dirs" => [ "../elsewhere" ] }, false ],
        [ { "tools" => read + [ "Bash" ], "commands" => [ "ruby *" ] }, { "preset" => "scoped", "bash" => true }, false ],
        [ { "preset" => "scoped", "tools" => read, "dirs" => [ File.join(root, "reports") ] }, { "preset" => "scoped", "tools" => [ "Read" ], "dirs" => [ File.join(root, "reports/sub") ] }, true ]
      ]
      cases.each do |inherited, requested, admitted|
        cfg = config
        cfg["agents"]["claude"]["bin"] = "ruby"
        cfg["plan"]["permissions"] = inherited
        cfg["execute"]["permissions"] = inherited
        cfg["task_capabilities"]["policy"] = { "required" => [ "ui" ] }
        cfg["task_capabilities"]["catalog"] = [ { "id" => "ui", "kind" => "guidance", "stages" => %w[plan execute], "skill" => "ui-fixture", "actor" => security_envelope.fetch("actor"), "permissions" => requested } ]
        preview = resolver(cfg, project_root: root).preview
        conflicts = preview.fetch("blockers").select { |entry| entry["capability"] == "ui" && entry["reason"] == "task_capability_policy_conflict" }
        assert_equal admitted, conflicts.empty?, "requested #{requested.inspect} beneath #{inherited.inspect}"
      end
    end
  end
end

class TaskCapabilitiesResolverTest
  def test_configured_default_accounts_cannot_reuse_an_approval_that_omits_the_account
    cfg = config
    cfg["review"]["ci"]["command"] = "ruby check.rb"
    cfg["agents"]["claude"]["bin"] = "ruby"
    cfg["task_capabilities"]["catalog"] = [ security_definition ]
    cfg["task_capabilities"]["approvals"] = { "local" => security_envelope }
    %w[account-a account-b].each do |id|
      account = Hive::ProviderRouting::Account.new(id: id, adapter: "claude", launch_binding: "default", models: [ "approved" ], max_concurrent: 2, cooldown_sec: {})
      cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = { id => account }
      preview = resolver(cfg).preview(selections: [ "security=on" ], approval_references: [ "security=local" ])
      assert preview.fetch("blockers").any? { |blocker| blocker["reason"] == "task_capability_approval_scope" && blocker["message"].include?("provider_account") }
    end
    cfg["task_capabilities"]["approvals"]["local"]["actor"].merge!("provider_account" => "account-b", "launch_binding" => "default")
    assert_empty resolver(cfg).preview(selections: [ "security=on" ], approval_references: [ "security=local" ]).fetch("blockers")
    cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = {}
    unavailable = resolver(cfg).preview(selections: [ "security=on" ], approval_references: [ "security=local" ])
    assert unavailable.fetch("blockers").any? { |blocker| blocker["reason"] == "task_capability_route_unavailable" && blocker["phase"] == "finalization" }
  end

  def test_unselected_guidance_keeps_immutable_catalog_authority_without_blocking_capture
    with_tmp_dir do |root|
      cfg = config
      cfg["review"]["ci"]["command"] = "ruby check.rb"
      cfg["task_capabilities"]["catalog"] = [ { "id" => "ui", "kind" => "guidance", "stages" => %w[plan execute], "skill" => "uninstalled",
        "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" }, "permissions" => "read-only", "budget_usd" => 1, "timeout_sec" => 5 } ]
      result = resolver(cfg, project_root: root).resolve(task_identity: { "id" => "1", "slug" => "task", "workflow" => "coding" })
      assert_empty result.plan.data.fetch("blockers")
      snapshot = result.plan.data.fetch("policy").fetch("catalog_bindings").first
      refute snapshot.fetch("available")
      assert_equal 1, snapshot.fetch("budget_usd")
      assert_equal "default", snapshot.dig("actor_route", "launch_binding_id")
      cfg["budget_usd"]["plan"] = 100
      assert_equal snapshot, result.plan.data.fetch("policy").fetch("catalog_bindings").first
    end
  end
end
