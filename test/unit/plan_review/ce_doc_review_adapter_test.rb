require "test_helper"
require "hive/plan_review/adapters/ce_doc_review"
require "hive/stages/base"

class PlanReviewCeDocReviewAdapterTest < Minitest::Test
  include HiveTestHelper

  def test_success_uses_disposable_plan_and_validates_machine_output
    with_request do |request, plan_path|
      original = File.binread(plan_path)
      runner = lambda do |prompt:, cwd:, output_path:, request:, **|
        refute_equal File.dirname(plan_path), cwd
        assert_includes prompt, "ce-doc-review"
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
        File.write(output_path, JSON.generate(valid_result(request)))
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
      refute_includes prompt, "Invoke `"
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

  def test_production_runner_attests_served_model_only_when_the_agent_reports_one
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

      refute silent.fetch("actual_route").key?("model")
      refute silent.fetch("actual_route").key?("family")
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
