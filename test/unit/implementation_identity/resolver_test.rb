require "test_helper"
require "hive/config"
require "hive/implementation_identity/resolver"

class ImplementationIdentityResolverTest < Minitest::Test
  include HiveTestHelper

  def test_execute_resolution_is_concrete_and_profile_native
    cfg = config(
      execute: { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    )

    selection = resolver(cfg).resolve_execute(generation: 3, attempt_id: "attempt-execute")

    assert_equal "execute", selection.stage
    assert_equal "codex", selection.provider
    assert_equal "gpt-5.6-sol", selection.model
    assert_equal "xhigh", selection.requested_effort
    assert_equal "xhigh", selection.effective_effort
    assert selection.effort_supported
    assert_equal 3, selection.generation
    assert_equal "attempt-execute", selection.originating_attempt
    assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=xhigh" ],
                 selection.native_arguments
  end

  def test_automatic_downstream_policies_use_utility_model_and_exact_execute_model
    execute = resolver(config).resolve_execute(generation: 4, attempt_id: "exec-1")
    subject = resolver(config)

    open_pr = subject.resolve_stage("open_pr", execute_identity: execute, attempt_id: "pr-1")
    fix = subject.resolve_stage("review.fix", execute_identity: execute, attempt_id: "fix-1")
    ci = subject.resolve_stage("review.ci", execute_identity: execute, attempt_id: "ci-1")

    assert_equal [ "codex", "gpt-5.6-terra", "medium", "persisted_execute" ],
                 [ open_pr.provider, open_pr.model, open_pr.requested_effort, open_pr.source ]
    [ fix, ci ].each do |selection|
      assert_equal "codex", selection.provider
      assert_equal "gpt-5.6-sol", selection.model
      assert_equal "high", selection.requested_effort
      assert_equal "persisted_execute", selection.source
    end
  end

  def test_field_level_overrides_apply_after_automatic_selection
    cfg = config(
      open_pr: { "effort" => "low" },
      review_fix: { "model" => "gpt-5.6-terra" }
    )
    execute = resolver(config).resolve_execute(generation: 1, attempt_id: "exec")
    subject = resolver(cfg)

    open_pr = subject.resolve_stage("open_pr", execute_identity: execute)
    fix = subject.resolve_stage("review.fix", execute_identity: execute)

    assert_equal [ "codex", "gpt-5.6-terra", "low", "explicit_override" ],
                 [ open_pr.provider, open_pr.model, open_pr.requested_effort, open_pr.source ]
    assert_equal [ "codex", "gpt-5.6-terra", "high", "explicit_override" ],
                 [ fix.provider, fix.model, fix.requested_effort, fix.source ]
  end

  def test_agent_only_cross_provider_review_override_uses_new_provider_default
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".claude"))
      File.write(File.join(root, ".claude", "settings.json"),
                 JSON.generate("model" => "claude-fable-5"))
      cfg = config(review_fix: { "agent" => "claude" }, project_root: root)
      execute = resolver(config).resolve_execute(generation: 2, attempt_id: "exec")

      fix = resolver(cfg).resolve_stage("review.fix", execute_identity: execute)

      assert_equal "claude", fix.provider
      assert_equal "claude-fable-5", fix.model
      assert_equal %w[--model claude-fable-5 --effort high], fix.native_arguments
      assert_equal "explicit_override", fix.source
    end
  end

  def test_pi_open_pr_uses_concrete_native_default_without_model_pin_or_fake_effort
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".pi"))
      File.write(File.join(root, ".pi", "settings.json"),
                 JSON.generate("provider" => "google", "model" => "gemini-2.5-pro"))
      cfg = config(
        execute: { "agent" => "pi", "model" => "google/gemini-2.5-pro" },
        project_root: root
      )
      subject = resolver(cfg)
      execute = subject.resolve_execute(generation: 1, attempt_id: "exec")

      open_pr = subject.resolve_stage("open_pr", execute_identity: execute)

      assert_equal "google/gemini-2.5-pro", open_pr.model
      refute open_pr.model_pinned
      refute open_pr.effort_supported
      assert_nil open_pr.effective_effort
      assert_equal [], open_pr.native_arguments
    end
  end

  def test_missing_execute_provider_and_unresolved_default_fail_visibly
    missing = config(execute: {})
    missing[Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY] = { "execute" => {} }.freeze
    assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      resolver(missing).resolve_execute(generation: 1, attempt_id: "exec")
    end

    with_tmp_dir do |root|
      unresolved = config(execute: { "agent" => "grok" }, project_root: root)
      with_replaced_singleton_method(Dir, :home, -> { root }) do
        assert_raises(Hive::ImplementationIdentity::ResolutionError) do
          resolver(unresolved).resolve_execute(generation: 1, attempt_id: "exec")
        end
      end
    end
  end

  def test_downstream_resolution_rejects_unknown_stage_and_blank_provider_override
    execute = resolver(config).resolve_execute(generation: 1, attempt_id: "exec")

    assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      resolver(config).resolve_stage("artifacts", execute_identity: execute)
    end

    cfg = config(review_fix: { "agent" => "" })
    assert_raises(Hive::ImplementationIdentity::ResolutionError) do
      resolver(cfg).resolve_stage("review.fix", execute_identity: execute)
    end
  end

  def test_downstream_inherits_legacy_source
    execute = resolver(config).resolve_legacy(
      provider: "codex", model: "gpt-5.6-sol", effort: nil,
      generation: 1, attempt_id: "legacy-exec"
    )

    selection = resolver(config).resolve_stage("review.ci", execute_identity: execute)

    assert_equal "legacy_backfill", selection.source
  end

  def test_claude_execute_uses_explicit_global_model_and_effort
    cfg = config(execute: { "agent" => "claude" })
    cfg["claude"] = { "model" => "claude-fable-5", "effort" => "medium" }

    selection = resolver(cfg).resolve_execute(generation: 1, attempt_id: "exec")

    assert_equal "claude-fable-5", selection.model
    assert_equal "medium", selection.effective_effort
    assert_equal %w[--model claude-fable-5 --effort medium], selection.native_arguments
  end

  def test_execute_composes_exact_model_and_coarse_effort_into_frozen_routing
    cfg = config(
      execute: {
        "agent" => "codex", "model" => "gpt-5.6-terra", "effort" => "low"
      },
      models: {
        "execute" => { "effort" => "xhigh" },
        "execute_implementation" => { "model" => "gpt-5.6-sol" }
      }
    )

    selection = resolver(cfg).resolve_execute(generation: 2, attempt_id: "exec-routed")
    arguments = selection.routing_arguments(Hive::AgentProfiles.lookup(:codex))

    assert_equal "codex", selection.provider
    assert_equal "gpt-5.6-sol", selection.model
    assert_equal "xhigh", selection.requested_effort
    assert_empty selection.native_arguments
    assert_equal [ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=xhigh" ],
                 arguments.global_arguments
    assert_empty arguments.subcommand_arguments
    assert_equal "execute_implementation", selection.routing.fetch("stage")
    assert_equal(
      { "kind" => "exact", "key" => "execute_implementation" },
      selection.routing.dig("provenance", "model")
    )
    assert_equal(
      { "kind" => "coarse", "key" => "execute" },
      selection.routing.dig("provenance", "effort")
    )
  end

  def test_downstream_composes_public_routes_over_existing_policy_fallbacks
    cfg = config(
      models: {
        "open_pr" => { "effort" => "xhigh" },
        "review" => { "effort" => "low" },
        "review_fix" => { "model" => "gpt-5.6-fix" },
        "review_ci" => { "model" => "gpt-5.6-ci" }
      }
    )
    execute = resolver(config).resolve_execute(generation: 3, attempt_id: "exec")
    subject = resolver(cfg)

    open_pr = subject.resolve_stage("open_pr", execute_identity: execute)
    fix = subject.resolve_stage("review.fix", execute_identity: execute)
    ci = subject.resolve_stage("review.ci", execute_identity: execute)

    assert_equal [ "codex", "gpt-5.6-terra", "xhigh" ],
                 [ open_pr.provider, open_pr.model, open_pr.requested_effort ]
    assert_equal [ "codex", "gpt-5.6-fix", "low" ],
                 [ fix.provider, fix.model, fix.requested_effort ]
    assert_equal [ "codex", "gpt-5.6-ci", "low" ],
                 [ ci.provider, ci.model, ci.requested_effort ]
    assert_equal "open_pr", open_pr.routing.fetch("stage")
    assert_equal "review_fix", fix.routing.fetch("stage")
    assert_equal "review_ci", ci.routing.fetch("stage")
    assert_equal "current", open_pr.routing.dig("provenance", "model", "kind")
    assert_equal "coarse", fix.routing.dig("provenance", "effort", "kind")
  end

  def test_routed_model_sentinel_is_concretized_before_durable_capture
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".codex"))
      File.write(
        File.join(root, ".codex", "config.toml"),
        "model = \"gpt-5.6-native\"\n"
      )
      cfg = config(
        execute: { "agent" => "codex", "model" => "gpt-5.6-sol" },
        project_root: root,
        models: {
          "execute_implementation" => { "model" => "inherit" }
        }
      )

      selection = resolver(cfg).resolve_execute(generation: 4, attempt_id: "exec")
      arguments = selection.routing_arguments(Hive::AgentProfiles.lookup(:codex))

      assert_equal "gpt-5.6-native", selection.model
      assert_equal "gpt-5.6-native", selection.routing.fetch("model")
      assert_equal [ "--model", "gpt-5.6-native" ], arguments.global_arguments
      assert_equal "exact", selection.routing.dig("provenance", "model", "kind")
    end
  end

  def test_routed_effort_is_validated_by_selected_provider
    %w[pi grok].each do |provider|
      cfg = config(
        execute: { "agent" => provider, "model" => "provider/model-v1" },
        models: {
          "execute_implementation" => { "effort" => "high" }
        }
      )

      error = assert_raises(Hive::ConfigError) do
        resolver(cfg).resolve_execute(generation: 1, attempt_id: "#{provider}-exec")
      end

      assert_match(/models\.execute_implementation\.effort/, error.message)
      assert_match(/profile :#{provider}/, error.message)
    end
  end

  def test_exact_downstream_model_does_not_resolve_a_shadowed_provider_default
    cfg = config(
      execute: { "agent" => "pi", "model" => "provider/execute-model" },
      models: {
        "open_pr" => { "model" => "provider/routed-model" }
      }
    )
    execute = resolver(cfg).resolve_execute(generation: 1, attempt_id: "pi-exec")

    selection = resolver(cfg).resolve_stage("open_pr", execute_identity: execute)
    arguments = selection.routing_arguments(Hive::AgentProfiles.lookup(:pi))

    assert_equal "provider/routed-model", selection.model
    assert selection.model_pinned
    assert_equal [ "--model", "provider/routed-model" ], arguments.subcommand_arguments
  end

  def test_exact_execute_model_does_not_resolve_a_shadowed_provider_default
    cfg = config(
      execute: { "agent" => "pi" },
      models: {
        "execute_implementation" => { "model" => "provider/routed-model" }
      }
    )

    selection = resolver(cfg).resolve_execute(generation: 1, attempt_id: "pi-exec")
    arguments = selection.routing_arguments(Hive::AgentProfiles.lookup(:pi))

    assert_equal "provider/routed-model", selection.model
    assert selection.model_pinned
    assert_equal [ "--model", "provider/routed-model" ], arguments.subcommand_arguments
  end

  def test_downstream_route_preserves_explicit_provider_selection
    cfg = config(
      review_fix: { "agent" => "claude" },
      models: {
        "review_fix" => { "model" => "claude-opus-4-6", "effort" => "high" }
      }
    )
    execute = resolver(config).resolve_execute(generation: 1, attempt_id: "exec")

    selection = resolver(cfg).resolve_stage("review.fix", execute_identity: execute)
    arguments = selection.routing_arguments(Hive::AgentProfiles.lookup(:claude))

    assert_equal "claude", selection.provider
    assert_equal "claude-opus-4-6", selection.model
    assert_equal %w[--model claude-opus-4-6 --effort high],
                 arguments.subcommand_arguments
    assert_empty arguments.global_arguments
  end

  private

  def resolver(cfg)
    Hive::ImplementationIdentity::Resolver.new(cfg: cfg)
  end

  def config(execute: { "agent" => "codex", "model" => "gpt-5.6-sol" },
             open_pr: {}, review_fix: {}, review_ci: {}, project_root: nil,
             models: nil)
    fields = {
      "execute" => execute.dup.freeze,
      "open_pr" => open_pr.dup.freeze,
      "review.fix" => review_fix.dup.freeze,
      "review.ci" => review_ci.dup.freeze
    }.freeze
    value = {
      "project_root" => project_root,
      "execute" => execute.dup,
      "open_pr" => open_pr.dup,
      "review" => { "fix" => review_fix.dup, "ci" => review_ci.dup },
      Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY => fields
    }
    value["models"] = models if models
    value
  end
end
