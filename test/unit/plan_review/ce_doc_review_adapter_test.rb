require "test_helper"
require "hive/plan_review/adapters/ce_doc_review"
require "hive/stages/base"

class PlanReviewCeDocReviewAdapterTest < Minitest::Test
  include HiveTestHelper

  # Hive journals the review attempt while the reviewer runs, so anchoring its
  # own bookkeeping made every review fail with "reviewer modified protected
  # artifacts" for writes the reviewer never made.
  def test_custody_manifest_does_not_anchor_hive_written_journals
    anchored = Hive::ArtifactFirewall::ORCHESTRATOR_OWNED -
      Hive::PlanReview::Adapters::CeDocReview::HiveRunner::ORCHESTRATOR_JOURNALS

    refute_includes anchored, "task-journal.jsonl"
    refute_includes anchored, "task-projection.json"
    refute_includes anchored, "task-projection.checkpoint.json"
    # The reviewer's actual input must still be protected.
    assert_includes anchored, "plan.md"
  end

  def test_hive_runner_capability_probe_uses_the_project_configured_opencode_plugin
    plugin = "compound-engineering@git+https://github.com/EveryInc/" \
      "compound-engineering-plugin.git#compound-engineering-v3.21.4"
    runner = Hive::PlanReview::Adapters::CeDocReview::HiveRunner.new(
      task: nil,
      cfg: { "agents" => { "opencode" => { "plugins" => [ plugin ] } } }
    )

    result = runner.capability_probe(
      agent: "opencode", invocation: "/ce-doc-review", project_root: Dir.pwd
    )
    adapter = Hive::PlanReview::Adapters::CeDocReview.new(runner:)

    assert_equal "present", result.fetch("status")
    assert_includes result.fetch("diagnostic"), "configured native plugin"
    assert_equal runner, adapter.instance_variable_get(:@capability_probe).receiver
  end

  def test_hive_runner_capability_probe_degrades_profile_faults_to_unsupported
    runner = Hive::PlanReview::Adapters::CeDocReview::HiveRunner.new(
      task: nil, cfg: Hive::Config::DEFAULTS
    )

    result = with_replaced_singleton_method(
      Hive::AgentProfiles, :lookup,
      ->(*, **) { raise "prepared profile registry is unreachable" }
    ) do
      runner.capability_probe(
        agent: "opencode", invocation: "/ce-doc-review", project_root: Dir.pwd
      )
    end

    assert_equal "unsupported", result.fetch("status")
    assert_includes result.fetch("diagnostic"), "prepared profile registry is unreachable"
  end

  def test_default_capability_probe_reports_a_present_skill
    profile = Object.new
    profile.define_singleton_method(:verify_skill) do |invocation, project_root:|
      [ :present, "#{invocation} is available in #{project_root}" ]
    end
    adapter = Hive::PlanReview::Adapters::CeDocReview.new(runner: ->(**) { })

    result = with_replaced_singleton_method(
      Hive::AgentProfiles, :lookup, ->(*, **) { profile }
    ) do
      adapter.send(
        :default_capability_probe,
        agent: "codex", invocation: "/ce-doc-review", project_root: Dir.pwd
      )
    end

    assert_equal "present", result.fetch("status")
    assert_includes result.fetch("diagnostic"), "/ce-doc-review is available"
  end

  def test_public_capability_probe_does_not_invoke_the_reviewer
    runner_calls = 0
    adapter = Hive::PlanReview::Adapters::CeDocReview.new(
      runner: ->(**) { runner_calls += 1 },
      capability_probe: ->(**) do
        { "status" => "unsupported", "diagnostic" => "missing skill" }
      end
    )

    result = adapter.probe_capability(
      kind: "primary", reviewer: { "provider" => "codex" },
      project_root: Dir.pwd
    )

    assert_equal "unsupported", result.fetch("status")
    assert_equal "missing skill", result.fetch("diagnostic")
    assert_equal 0, runner_calls
  end

  def test_success_uses_disposable_plan_and_validates_machine_output
    with_request do |request, plan_path|
      original = File.binread(plan_path)
      runner = lambda do |prompt:, cwd:, output_path:, request:, **|
        refute_equal File.dirname(plan_path), cwd
        assert File.directory?(File.join(cwd, ".git")) || File.file?(File.join(cwd, ".git"))
        assert_includes prompt, "ce-doc-review"
        assert_includes prompt, "Repository root: `#{cwd}`"
        assert_includes prompt,
                        "`selected_lenses` names may use lowercase letters, digits, hyphens, and underscores"
        assert_includes prompt, "`residual_evidence` must be exactly an empty array"
        File.write(File.join(cwd, "review-notes.md"), "reviewer scratch work")
        File.write(output_path, JSON.generate(valid_result(request)))
        { "status" => "ok", "actual_route" => request.reviewer }
      end
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner:,
        capability_probe: ->(**) { { "status" => "present", "path" => "/skills/ce-doc-review/SKILL.md" } }
      )

      result = adapter.call(request)

      assert_equal "success", result.outcome
      assert_equal original, File.binread(plan_path)
      assert_equal 1, result.findings.length
    end
  end

  def test_success_preserves_findings_when_selected_lenses_are_hyphenated
    with_request do |request, _plan_path|
      runner = lambda do |output_path:, request:, **|
        payload = valid_result(request).merge(
          "selected_lenses" => [ "product-lens", "security-lens", "scope-guardian" ]
        )
        File.write(output_path, JSON.generate(payload))
        { "status" => "ok", "actual_route" => request.reviewer }
      end

      result = adapter_for(runner).call(request)

      assert_equal "success", result.outcome
      assert_equal 1, result.findings.length
      assert_equal %w[product-lens security-lens scope-guardian], result.selected_lenses
    end
  end

  def test_stable_unsupported_does_not_invoke_runner
    calls = 0
    with_request do |request, _plan_path|
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner: ->(**) { calls += 1 },
        capability_probe: ->(**) { { "status" => "unsupported", "diagnostic" => "missing skill" } }
      )
      result = adapter.call(request)
      assert_equal "unsupported", result.outcome
      assert_equal 0, calls
    end
  end

  def test_pi_primary_uses_the_built_in_direct_review_contract_without_skill_probe
    with_request do |request, _plan_path|
      pi_request = request.with(
        reviewer: request.reviewer.merge(
          "provider" => "pi",
          "model" => "openrouter/deepseek/deepseek-v4-pro:xhigh",
          "family" => "deepseek",
          "route" => "pi-openrouter"
        )
      )
      prompt = nil
      runner = lambda do |output_path:, request:, **kwargs|
        prompt = kwargs.fetch(:prompt)
        payload = valid_result(request)
        File.write(output_path, JSON.generate(payload))
        { "status" => "ok", "actual_route" => request.reviewer }
      end
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner:,
        capability_probe: ->(**) { flunk "Pi direct review must not probe a host skill" },
        capability_resolver: ->(*) { flunk "Pi direct review must not resolve a host skill" }
      )

      result = adapter.call(pi_request)

      assert_equal "success", result.outcome
      assert_includes prompt, "Review the immutable executable-plan copy"
      assert_includes prompt, "do not require an external skill or subagent"
      assert_match(/Repository root: `.*hive-plan-review-worktree-.*\/checkout`/, prompt)
      assert_includes prompt, "Write one JSON object to `"
      refute_includes prompt, 'files["hive-plan-review-result.json"]'
      refute_includes prompt, "This confined route has no hashing tool"
      refute_includes prompt, "Invoke `"
      assert_equal valid_result(pi_request).dig("findings", 0, "evidence", "anchor_digest"),
                   result.findings.first["evidence"].fetch("anchor_digest")
      assert_empty result.residual_evidence
    end
  end

  def test_parser_failure_preserves_the_actual_reviewer_route
    with_request do |request, _plan_path|
      runner = lambda do |output_path:, request:, **|
        payload = valid_result(request)
        payload["coverage"] = "invalid"
        File.write(output_path, JSON.generate(payload))
        { "status" => "ok", "actual_route" => request.reviewer }
      end

      result = adapter_for(runner).call(request)

      assert_equal "terminal_failure", result.outcome
      assert_equal request.reviewer, result.route_receipt.fetch("actual")
      assert_equal "different_model_family", result.route_receipt.fetch("independence_reason")
      assert_equal "parser", result.route_receipt.fetch("diagnostic_source")
    end
  end

  def test_reviewer_authored_diagnostic_is_distinct_from_a_parser_failure
    with_request do |request, _plan_path|
      runner = lambda do |output_path:, request:, **|
        payload = valid_result(request).merge(
          "outcome" => "terminal_failure",
          "diagnostic" => "plan review selected_lenses must contain lowercase names"
        )
        File.write(output_path, JSON.generate(payload))
        { "status" => "ok", "actual_route" => request.reviewer }
      end

      result = adapter_for(runner).call(request)

      assert_equal "terminal_failure", result.outcome
      assert_equal "reviewer", result.route_receipt.fetch("diagnostic_source")
    end
  end

  def test_adapter_config_error_preserves_the_actual_route_and_diagnostic_source
    with_request do |request, _plan_path|
      runner = lambda do |output_path:, request:, **|
        File.write(output_path, JSON.generate(valid_result(request)))
        { "status" => "ok", "actual_route" => request.reviewer }
      end

      result = with_replaced_singleton_method(
        Hive::PlanReview::ResultParser, :parse,
        ->(*, **) { raise Hive::ConfigError, "invalid adapter configuration" }
      ) do
        adapter_for(runner).call(request)
      end

      assert_equal "terminal_failure", result.outcome
      assert_equal request.reviewer, result.route_receipt.fetch("actual")
      assert_equal "adapter", result.route_receipt.fetch("diagnostic_source")
    end
  end

  def test_pi_anchor_rewrite_defers_unparsable_output_to_the_result_parser
    with_request do |request, _plan_path|
      pi_request = request.with(
        reviewer: request.reviewer.merge(
          "provider" => "pi",
          "model" => "openrouter/deepseek/deepseek-v4-pro:xhigh",
          "family" => "deepseek",
          "route" => "pi-openrouter"
        )
      )
      runner = lambda do |output_path:, request:, **|
        File.write(output_path, "{not json")
        { "status" => "ok", "actual_route" => request.reviewer }
      end
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner:,
        capability_probe: ->(**) { flunk "Pi direct review must not probe a host skill" },
        capability_resolver: ->(*) { flunk "Pi direct review must not resolve a host skill" }
      )

      result = adapter.call(pi_request)

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "not valid JSON"
    end
  end

  def test_route_receipt_normalizes_model_family_before_attesting_independence
    with_request do |request, _plan_path|
      runner = lambda do |output_path:, request:, **|
        File.write(output_path, JSON.generate(valid_result(request)))
        {
          "status" => "ok",
          "actual_route" => request.reviewer.merge("family" => " CLAUDE ")
        }
      end
      adapter = adapter_for(runner)

      receipt = adapter.call(request).route_receipt

      refute receipt.fetch("independence_verified")
      assert_equal "same_model_family", receipt.fetch("independence_reason")
    end
  end

  def test_timeout_limit_retryable_and_canonical_mutation_are_distinct
    outcomes = {
      "timeout" => { "status" => "timeout" },
      "provider_limit" => { "status" => "provider_limit", "retry_at" => "2026-08-12T13:00:00Z" },
      "retryable_failure" => { "status" => "retryable_failure" }
    }
    outcomes.each do |expected, runner_result|
      with_request do |request, _plan_path|
        adapter = adapter_for(->(**) { runner_result })
        assert_equal expected, adapter.call(request).outcome
      end
    end

    with_request do |request, plan_path|
      adapter = adapter_for(lambda do |**|
        File.write(plan_path, "tampered")
        { "status" => "ok" }
      end)
      assert_equal "terminal_failure", adapter.call(request).outcome
    end
  end

  def test_result_nested_evidence_is_immutable
    result = Hive::PlanReview::Adapters::Base::Result.new(
      outcome: "success",
      coverage: [ { "name" => "whole_document", "status" => "completed" } ],
      route_receipt: { "actual" => { "family" => "openai" } }
    )

    assert_predicate result.coverage.first, :frozen?
    assert_predicate result.route_receipt.fetch("actual"), :frozen?
    assert_raises(FrozenError) { result.coverage.first["status"] = "failed" }
  end

  def test_capability_configuration_errors_are_normalized_as_unsupported
    with_request do |request, _plan_path|
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner: ->(**) { flunk "configuration failure must not invoke the runner" },
        capability_resolver: lambda do |*|
          raise Hive::ConfigError, "invalid capability manifest"
        end
      )

      result = adapter.call(request)

      assert_equal "unsupported", result.outcome
      assert_includes result.diagnostic, "invalid capability manifest"
    end
  end

  def test_provider_route_error_is_a_retryable_adapter_outcome_with_route_evidence
    with_request do |request, _plan_path|
      adapter = adapter_for(lambda do |**|
        raise Hive::ProviderRouteFailed, "admitted route failed"
      end)

      result = adapter.call(request)

      assert_equal "retryable_failure", result.outcome
      assert_equal request.reviewer, result.route_receipt.fetch("requested")
      assert_includes result.diagnostic, "admitted route failed"
    end
  end

  def test_output_is_read_with_the_parser_byte_bound
    with_request do |request, _plan_path|
      runner = lambda do |output_path:, **|
        File.binwrite(output_path, "x" * (Hive::PlanReview::ResultParser::MAX_BYTES + 1))
        { "status" => "ok", "actual_route" => request.reviewer }
      end

      result = adapter_for(runner).call(request)

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "size limit"
    end
  end

  def test_production_runner_restores_forged_authoritative_review_state
    with_request do |request, _plan_path|
      current_path = File.join(request.project_root, "plan-review", "current.json")
      meta_path = File.join(request.project_root, "meta.yml")
      FileUtils.mkdir_p(File.dirname(current_path))
      File.write(current_path, "authoritative\n")
      File.write(meta_path, "id: task-1\n")
      task = Struct.new(:folder, :meta_yml_path, keyword_init: true).new(
        folder: request.project_root, meta_yml_path: meta_path
      )
      runner = Hive::PlanReview::Adapters::CeDocReview::HiveRunner.new(
        task:, cfg: Hive::Config::DEFAULTS
      )
      valid_payload = valid_result(request)
      launch = nil
      replacement = lambda do |_task, expected_output:, **kwargs|
        launch = kwargs
        File.write(current_path, "forged clearance\n")
        File.write(expected_output, JSON.generate(valid_payload))
        { status: :ok, usage: { model: request.reviewer.fetch("model") } }
      end

      observed = nil
      with_replaced_singleton_method(
        Hive::Stages::Base, :spawn_agent, replacement
      ) do
        observed = runner.call(
          prompt: "review", cwd: request.output_directory,
          output_path: File.join(request.output_directory, "result.json"), request:
        )
      end

      assert_equal "terminal_failure", observed.fetch("status")
      assert_includes observed.fetch("diagnostic"), "plan-review/current.json"
      assert_equal "authoritative\n", File.read(current_path)
      assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                   launch.fetch(:permission_mode)
    end
  end

  def test_production_runner_batches_large_review_history_without_dropping_custody
    with_runner do |runner, request, output_path|
      review_root = File.join(request.project_root, "plan-review", "reviews", "historical")
      FileUtils.mkdir_p(review_root)
      paths = (Hive::ArtifactFirewall::MAX_ENTRIES + 5).times.map do |index|
        path = File.join(review_root, format("record-%03d.json", index))
        File.write(path, "original #{index}\n")
        path
      end
      target = paths.last
      launched = false
      payload = valid_result(request)
      replacement = lambda do |_task, expected_output:, **|
        launched = true
        File.write(target, "forged\n")
        File.write(expected_output, JSON.generate(payload))
        { status: :ok, usage: { model: request.reviewer.fetch("model") } }
      end

      observed = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
        observed = runner.call(
          prompt: "review", cwd: request.output_directory, output_path:, request:
        )
      end

      assert launched, "large histories must reach the reviewer instead of failing manifest admission"
      assert_equal "terminal_failure", observed.fetch("status")
      assert_includes observed.fetch("diagnostic"), "record-132.json"
      assert_equal "original 132\n", File.read(target)
    end
  end

  def test_production_runner_maps_agent_results_onto_transport_status
    cases = {
      "ok" => { status: :ok, usage: { model: "gpt-5.6-sol" } },
      "timeout" => { status: :error, timed_out: true },
      "provider_limit" => { status: :error, error_reason: "rate limit reached" },
      "retryable_failure" => { status: :error, error_message: "connection reset" }
    }
    cases.each do |expected, agent_result|
      with_runner do |runner, request, output_path|
        payload = valid_result(request)
        replacement = lambda do |_task, expected_output:, **|
          File.write(expected_output, JSON.generate(payload))
          agent_result
        end

        observed = nil
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
          observed = runner.call(
            prompt: "review", cwd: request.output_directory,
            output_path:, request:
          )
        end

        assert_equal expected, observed.fetch("status"), "agent result #{agent_result.inspect}"
        assert_equal "codex", observed.dig("actual_route", "provider")
      end
    end
  end

  def test_production_runner_attests_the_explicitly_launched_model_and_detects_a_served_override
    with_runner do |runner, request, output_path|
      payload = valid_result(request)
      replacement = lambda do |_task, expected_output:, **|
        File.write(expected_output, JSON.generate(payload))
        { status: :ok, usage: { model: "gpt-5.6-sol" } }
      end
      served = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
        served = runner.call(
          prompt: "review", cwd: request.output_directory, output_path:, request:
        )
      end

      assert_equal "gpt-5.6-sol", served.dig("actual_route", "model")
      assert_equal "openai", served.dig("actual_route", "family")
    end

    with_runner do |runner, request, output_path|
      payload = valid_result(request)
      replacement = lambda do |_task, expected_output:, **|
        File.write(expected_output, JSON.generate(payload))
        { status: :ok }
      end
      silent = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
        silent = runner.call(
          prompt: "review", cwd: request.output_directory, output_path:, request:
        )
      end

      assert_equal request.reviewer.fetch("model"), silent.dig("actual_route", "model")
      assert_equal request.reviewer.fetch("family"), silent.dig("actual_route", "family")
    end

    with_runner do |runner, request, output_path|
      payload = valid_result(request)
      replacement = lambda do |_task, expected_output:, **|
        File.write(expected_output, JSON.generate(payload))
        { status: :ok, usage: { model: "unexpected-model" } }
      end
      overridden = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
        overridden = runner.call(
          prompt: "review", cwd: request.output_directory, output_path:, request:
        )
      end

      assert_equal "unexpected-model", overridden.dig("actual_route", "model")
      refute overridden.fetch("actual_route").key?("family")
    end
  end

  def test_production_runner_attests_only_the_exact_grok_46_build_served_name
    with_runner do |runner, request, output_path|
      cases = [
        [ "grok", "grok-4.6", "grok-4.6-build", "grok", true ],
        [ "grok", "grok-4.6", "grok-4.6-build", " GROK ", true ],
        [ "grok", "grok-4.5", "grok-4.6-build", "grok", false ],
        [ "grok", "grok-4.6", "grok-4.7-build", "grok", false ],
        [ "grok", "grok-4.6", "grok-4.6-build", "openai", false ],
        [ "codex", "grok-4.6", "grok-4.6-build", "grok", false ],
        [ "grok", nil, "unknown-model", "grok", false ]
      ]

      cases.each do |provider, requested_model, served_model, family, attested|
        grok_request = request.with(
          reviewer: {
            "provider" => provider, "model" => requested_model, "family" => family,
            "effort" => "high", "route" => "native_grok_build"
          },
          kind: "adversarial"
        )
        payload = valid_result(grok_request)
        replacement = lambda do |_task, expected_output:, **|
          File.write(expected_output, JSON.generate(payload))
          { status: :ok, usage: { model: served_model } }
        end

        observed = nil
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
          observed = runner.call(
            prompt: "review", cwd: grok_request.output_directory,
            output_path:, request: grok_request
          )
        end

        assert_equal served_model, observed.dig("actual_route", "model")
        assert_equal attested, observed.fetch("actual_route").key?("family"),
                     "provider=#{provider.inspect} requested=#{requested_model.inspect} " \
                     "served=#{served_model.inspect} family=#{family.inspect}"
      end
    end
  end

  def test_production_runner_reports_custody_and_agent_failures_without_raising
    with_runner do |runner, request, output_path|
      raiser = lambda do |_manifest|
        raise Hive::ArtifactFirewall::Error, "custody manifest is unusable"
      end

      observed = nil
      with_replaced_singleton_method(Hive::ArtifactFirewall, :capture, raiser) do
        observed = runner.call(
          prompt: "review", cwd: request.output_directory, output_path:, request:
        )
      end

      assert_equal "terminal_failure", observed.fetch("status")
      assert_includes observed.fetch("diagnostic"), "custody manifest is unusable"
    end

    with_runner do |runner, request, output_path|
      payload = valid_result(request)
      replacement = lambda do |_task, expected_output:, **|
        File.write(expected_output, JSON.generate(payload))
        raise Hive::AgentError, "agent process died"
      end

      observed = nil
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, replacement) do
        observed = runner.call(
          prompt: "review", cwd: request.output_directory, output_path:, request:
        )
      end

      assert_equal "retryable_failure", observed.fetch("status")
      assert_includes observed.fetch("diagnostic"), "agent process died"
      assert_equal request.reviewer, observed.fetch("actual_route")
    end
  end

  def test_mutating_the_disposable_copy_is_terminal_even_when_the_original_is_intact
    with_request do |request, plan_path|
      original = File.binread(plan_path)
      runner = lambda do |cwd:, output_path:, request:, **|
        File.binwrite(File.join(cwd, "plan.md"), "rewritten by the reviewer")
        File.write(output_path, JSON.generate(valid_result(request)))
        { "status" => "ok", "actual_route" => request.reviewer }
      end

      result = adapter_for(runner).call(request)

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "disposable plan snapshot"
      assert_equal original, File.binread(plan_path)
    end
  end

  def test_adapter_timeouts_and_filesystem_faults_are_normalized
    with_request do |request, _plan_path|
      adapter = adapter_for(->(**) { raise Timeout::Error })
      result = adapter.call(request)

      assert_equal "timeout", result.outcome
      assert_includes result.diagnostic, "timed out"
    end

    with_request do |request, _plan_path|
      adapter = adapter_for(->(**) { raise Errno::EACCES, "disposable workspace" })
      result = adapter.call(request)

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "filesystem failure"
    end
  end

  def test_disposable_worktree_creation_failure_is_cleaned_and_reported
    failed = Object.new
    failed.define_singleton_method(:success?) { false }
    succeeded = Object.new
    succeeded.define_singleton_method(:success?) { true }

    with_request do |request, _plan_path|
      capture = lambda do |*argv|
        if argv.include?("add")
          [ "", "cannot add", failed ]
        else
          [ "", "", succeeded ]
        end
      end
      error = nil
      with_replaced_singleton_method(Open3, :capture3, capture) do
        error = assert_raises(Hive::PlanReview::InvalidRecord) do
          Hive::PlanReview::DisposableWorktree.new(
            project_root: request.project_root
          ).create
        end
      end

      assert_includes error.message, "could not create a disposable Git worktree"
      assert_includes error.message, "cannot add"
    end
  end

  def test_disposable_cleanup_reports_filesystem_failures
    Dir.mktmpdir("hive-plan-review-worktree-") do |parent|
      path = File.join(parent, "checkout")
      FileUtils.mkdir_p(path)
      worktree = Hive::PlanReview::DisposableWorktree.new(
        project_root: request_for_cleanup.project_root
      )
      worktree.instance_variable_set(:@temp_root, parent)
      worktree.instance_variable_set(:@path, path)
      worktree.instance_variable_set(:@added, true)
      _out, err = capture_io do
        with_replaced_singleton_method(
          Open3, :capture3, ->(*) { raise Errno::EIO, "cleanup" }
        ) do
          worktree.cleanup
        end
      end

      assert_includes err, "disposable worktree cleanup failed"
      assert_includes err, "EIO"
    end
  end

  def test_disposable_cleanup_warns_and_prunes_when_git_removal_fails
    failed = Object.new
    failed.define_singleton_method(:success?) { false }
    succeeded = Object.new
    succeeded.define_singleton_method(:success?) { true }
    parent = Dir.mktmpdir("hive-plan-review-worktree-")
    path = File.join(parent, "checkout")
    FileUtils.mkdir_p(path)
    worktree = Hive::PlanReview::DisposableWorktree.new(
      project_root: request_for_cleanup.project_root
    )
    worktree.instance_variable_set(:@temp_root, parent)
    worktree.instance_variable_set(:@path, path)
    worktree.instance_variable_set(:@added, true)
    calls = []
    capture = lambda do |*argv|
      calls << argv
      argv.include?("remove") ? [ "", "cannot remove", failed ] : [ "", "", succeeded ]
    end

    _out, err = capture_io do
      with_replaced_singleton_method(Open3, :capture3, capture) do
        worktree.cleanup
      end
    end

    assert_includes err, "disposable worktree cleanup failed: cannot remove"
    assert calls.any? { |argv| argv.include?("remove") }
    assert calls.any? { |argv| argv.include?("prune") }
    refute_path_exists parent
  ensure
    FileUtils.rm_rf(parent) if parent
  end

  def test_capability_probe_faults_degrade_to_unsupported_instead_of_raising
    with_request do |request, _plan_path|
      contract = Struct.new(:invocation).new("/ce-doc-review")
      adapter = Hive::PlanReview::Adapters::CeDocReview.new(
        runner: ->(**) { flunk "probe failure must not invoke the runner" },
        capability_resolver: ->(*) { contract }
      )

      result = nil
      with_replaced_singleton_method(
        Hive::AgentProfiles, :lookup, ->(*) { raise "profile registry is unreachable" }
      ) do
        result = adapter.call(request)
      end

      assert_equal "unsupported", result.outcome
      assert_includes result.diagnostic, "profile registry is unreachable"
    end
  end

  def test_snapshot_digest_drift_is_rejected_before_the_reviewer_runs
    with_request do |request, plan_path|
      File.write(plan_path, "# Plan changed after the digest was taken\n")
      adapter = adapter_for(->(**) { flunk "stale snapshot must not invoke the runner" })

      result = adapter.call(request)

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "digest changed"
    end
  end

  def test_each_review_kind_renders_its_own_prompt_template
    headings = {
      "primary" => "# Hive readable-plan review",
      "adversarial" => "# Hive adversarial readable-plan review",
      "verification" => "# Hive disposition verification"
    }
    headings.each do |kind, heading|
      with_request do |request, _plan_path|
        scoped = request.with(kind:)
        observed = nil
        runner = lambda do |prompt:, output_path:, request:, **|
          observed = prompt
          File.write(output_path, JSON.generate(valid_result(request)))
          { "status" => "ok", "actual_route" => request.reviewer }
        end

        assert_equal "success", adapter_for(runner).call(scoped).outcome
        assert_includes observed, heading
        assert_match(
          /Every newly emitted finding must use\s+`"lifecycle": "open"`/,
          observed
        )
        unless kind == "verification"
          rubric_patterns = [
            /`safe_auto`: one concrete, low-risk, reversible technical correction follows\s+from the plan, product contract, or established repository patterns/,
            /`gated_auto`: the preferred technical correction is clear, but applying it\s+materially changes architecture, external behavior, compatibility/,
            /`manual`: a human must supply a choice because the existing contract and\s+repository patterns do not determine a safe answer/,
            /`fyi`: useful information that requires no plan change/
          ]
          rubric_patterns.each { |pattern| assert_match pattern, observed }
          assert_match(
            /For the final JSON written to Hive, this rubric is authoritative and overrides\s+any classification, autofix, or routing rubric from an invoked skill/,
            observed
          )
          assert_includes observed, "Classification is about decision authority, not severity."
          assert_match(
            /Do not use `manual`\s+merely because the plan must choose/,
            observed
          )
        end
      end
    end
  end

  def test_unpublished_and_escaping_results_are_terminal
    with_request do |request, _plan_path|
      adapter = adapter_for(->(**) { { "status" => "ok" } })

      result = adapter.call(request)

      assert_equal "terminal_failure", result.outcome
      assert_includes result.diagnostic, "did not publish its JSON result"
    end

    Dir.mktmpdir("hive-plan-review-escape") do |disposable|
      escaped = File.join(disposable, "..", "elsewhere.json")
      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        Hive::PlanReview::Adapters::CeDocReview.allocate.send(:validate_output!, escaped, disposable)
      end

      assert_includes error.message, "escapes the disposable directory"
    end
  end

  def test_unsupported_and_terminal_runner_status_are_carried_through
    { "unsupported" => "unsupported", "terminal_failure" => "terminal_failure" }.each do |reported, expected|
      with_request do |request, _plan_path|
        adapter = adapter_for(->(**) { { "status" => reported, "diagnostic" => "reported #{reported}" } })

        result = adapter.call(request)

        assert_equal expected, result.outcome
        assert_includes result.diagnostic, "reported #{reported}"
      end
    end
  end

  def test_request_rejects_malformed_identity_and_non_positive_timeouts
    with_request do |request, _plan_path|
      assert_raises(ArgumentError) { request.with(plan_digest: "not-a-digest") }
      assert_raises(ArgumentError) { request.with(attempt_id: "pra-short") }
      assert_raises(ArgumentError) { request.with(timeout_sec: 0) }
      assert_raises(ArgumentError) { request.with(timeout_sec: "60") }
    end
  end

  private

  def request_for_cleanup
    Struct.new(:project_root).new(Dir.tmpdir)
  end

  def with_runner
    with_request do |request, _plan_path|
      meta_path = File.join(request.project_root, "meta.yml")
      File.write(meta_path, "id: task-1\n")
      task = Struct.new(:folder, :meta_yml_path, keyword_init: true).new(
        folder: request.project_root, meta_yml_path: meta_path
      )
      runner = Hive::PlanReview::Adapters::CeDocReview::HiveRunner.new(
        task:, cfg: Hive::Config::DEFAULTS
      )
      yield runner, request, File.join(request.output_directory, "result.json")
    end
  end

  def adapter_for(runner)
    Hive::PlanReview::Adapters::CeDocReview.new(
      runner:,
      capability_probe: ->(**) { { "status" => "present" } }
    )
  end

  def with_request
    Dir.mktmpdir("hive-plan-review-adapter") do |root|
      plan_path = File.join(root, "input-plan.md")
      File.write(plan_path, "# Plan\n")
      output = File.join(root, "output")
      FileUtils.mkdir_p(output)
      run!("git", "-C", root, "init", "--quiet")
      run!("git", "-C", root, "config", "user.name", "Hive Test")
      run!("git", "-C", root, "config", "user.email", "hive@example.test")
      run!("git", "-C", root, "add", "input-plan.md")
      run!("git", "-C", root, "commit", "-m", "plan review fixture", "--quiet")
      request = Hive::PlanReview::Adapters::Base::Request.new(
        plan_path:, plan_digest: Digest::SHA256.file(plan_path).hexdigest,
        document_type: "executable_plan", level: "standard",
        required_coverage: %w[whole_document adversarial],
        policy_fingerprint: "c" * 64,
        planner_identity: { "provider" => "claude", "family" => "claude" },
        reviewer: {
          "provider" => "codex", "model" => "gpt-5.6-sol", "family" => "openai",
          "effort" => "high", "route" => "native"
        },
        output_directory: output, timeout_sec: 60,
        attempt_id: "pra-#{'a' * 64}", kind: "primary", project_root: root
      )
      yield request, plan_path
    end
  end

  def valid_result(request)
    {
      "schema" => "hive-plan-review-adapter-result", "schema_version" => 1,
      "attempt_id" => request.attempt_id, "plan_digest" => request.plan_digest,
      "policy_fingerprint" => request.policy_fingerprint, "outcome" => "success",
      "findings" => [
        {
          "source" => "whole_document", "classification" => "safe_auto", "risk" => "low",
          "title" => "Clarify test", "description" => "Name the focused test.",
          "evidence" => {
            "path" => "plan.md", "start_line" => 1, "end_line" => 1,
            "anchor_digest" => Digest::SHA256.hexdigest("# Plan")
          },
          "lifecycle" => "open", "display_order" => 1
        }
      ],
      "coverage" => request.required_coverage.map do |name|
        { "name" => name, "required" => true, "status" => "completed" }
      end,
      "selected_lenses" => [ "coherence" ], "residual_evidence" => [], "diagnostic" => nil
    }
  end
end
