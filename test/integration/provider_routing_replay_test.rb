require "test_helper"
require_relative "../support/provider_routing_replay"
require "hive/daemon/status_consumer"
require "hive/daemon/workflow_recovery"
require "hive/workflows/bench"

class ProviderRoutingReplayIntegrationTest < Minitest::Test
  include HiveTestHelper

  FIXTURES = File.expand_path("../fixtures/provider_routing", __dir__)

  def test_claude_session_limit_has_one_open_one_probe_and_no_retry_storm
    with_replay("claude_session_limit.jsonl") do |replay|
      assert_equal %w[claude-main codex-main codex-main claude-main claude-main],
                   replay.selections.map { |entry| entry.fetch("provider") }
      assert_equal [ false, false, false, true, false ],
                   replay.selections.map { |entry| entry.fetch("probe") }
      assert_equal 3, replay.selections.count { |entry| entry.fetch("provider") == "claude-main" }

      transitions = replay.transition_events.map { |event| [ event["from"], event["to"], event["reason"] ] }
      assert_equal [ [ "closed", "open", "session_limit" ], [ "half_open", "closed", "probe_succeeded" ] ],
                   transitions
      assert_equal "closed", replay.store.state("claude-main").fetch("state")
    end
  end

  def test_grok_credit_is_isolated_and_returns_after_one_real_probe
    with_replay("grok_credit.jsonl") do |replay|
      assert_equal %w[grok-main codex-main grok-main grok-main],
                   replay.selections.map { |entry| entry.fetch("provider") }
      assert_equal 1, replay.selections.count { |entry| entry.fetch("probe") }
      assert_equal "closed", replay.store.state("grok-main").fetch("state")
      assert_equal "closed", replay.store.state("codex-main").fetch("state")
      assert_equal %w[credit probe_succeeded], replay.transition_events.map { |event| event["reason"] }
    end
  end

  def test_negative_lanes_keep_pins_quality_admin_unknown_and_context_strict
    with_tmp_dir do |home|
      with_env("HIVE_PROVIDER_ROUTING_STATE_HOME" => home) do
        now = Time.utc(2026, 7, 16, 12, 0, 0)
        accounts = Hive::ProviderRouting::Configuration.normalize_accounts(
          {
            "claude-main" => { "adapter" => "claude" },
            "codex-main" => { "adapter" => "codex" }
          }, source: "negative replay"
        )
        store = Hive::ProviderRouting::Store.new(clock: -> { now })
        leases = Hive::AttemptLeaseStore.new(clock: -> { now })
        router = Hive::ProviderRouting::Router.new(
          circuit_store: store, lease_store: leases, clock: -> { now }
        )
        config = routing_config(accounts, pin: { "provider" => "claude-main" })
        initial = router.select(request(config, "admin"))
        auth = initial.profile.normalize_error(
          evidence: "Synthetic fixture: authentication failed", exit_code: 1,
          timed_out: false, model: nil, provider: "claude-main",
          evidence_ref: "fixture:admin", success: false
        )
        router.record_outcome(decision: initial, success: false, signal: auth, now: now)

        now += 7 * 86_400
        pinned = router.select(request(config, "pinned"))
        assert pinned.wait?
        assert_equal "limits_reached", pinned.wait_reason
        assert store.state("claude-main").fetch("indefinite")

        store.clear(provider: "claude-main", reason: "credentials refreshed", now: now)
        restored = router.select(request(config, "restored"))
        assert_equal "claude-main", restored.provider
        router.cancel(restored, now: now)

        quality = routing_config(accounts, quality_floor: true)
        store.record(signal("claude-main", "session_limit"), account: accounts.fetch("claude-main"), now: now)
        quality_wait = router.select(request(quality, "quality"))
        assert quality_wait.wait?
        assert_equal "limits_reached", quality_wait.wait_reason
        assert_includes quality_wait.rejections.map(&:reason), "quality_too_low"

        before = store.snapshot.fetch("generation")
        %w[unknown network timeout].each do |failure_class|
          assert_nil store.record(signal("codex-main", failure_class), account: accounts.fetch("codex-main"), now: now)
        end
        assert_equal before, store.snapshot.fetch("generation")

        store.clear(provider: "claude-main", reason: "context lane", now: now)
        context_config = Hive::ProviderRouting::Configuration.from(
          cfg: { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => accounts },
          stage_name: "replay",
          routing: {
            "pool" => [
              { "provider" => "claude-main", "capabilities" => { "context" => "standard" } },
              { "provider" => "codex-main", "capabilities" => { "context" => "large" } }
            ]
          },
          agent: "claude", source: "context replay"
        )
        context_request = request(context_config, "context")
        context_attempt = router.select(context_request)
        context_signal = context_attempt.profile.normalize_error(
          evidence: "Synthetic fixture: maximum context length exceeded", exit_code: 1,
          timed_out: false, model: context_attempt.model, provider: context_attempt.provider,
          evidence_ref: "fixture:context", success: false
        )
        generation = store.snapshot.fetch("generation")
        outcome = router.record_outcome(
          decision: context_attempt, success: false, signal: context_signal,
          checkpoint: "context", now: now
        )
        rerouted = router.select(
          Hive::ProviderRouting::Request.new(
            configuration: context_config, checkpoint: "context", attempt_id: "context-fallback",
            exclusions: [ outcome.exclusion ], provenance: { "fixture" => true }
          )
        )
        assert_equal "codex-main", rerouted.provider
        assert_equal generation, store.snapshot.fetch("generation"), "context mismatch must not open shared health"
        router.cancel(rerouted, now: now)

        legacy = Hive::ProviderRouting::Configuration.from(
          cfg: { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => accounts },
          stage_name: "legacy", agent: "codex", model: "gpt-5", effort: "high"
        )
        assert_equal [ [ "codex-main", "codex", "gpt-5", "high" ] ],
                     legacy.pool.map { |candidate| [ candidate.provider, candidate.agent, candidate.model, candidate.effort ] }
      end
    end
  end

  def test_grok_recovery_resumes_one_bench_generation_without_rebuying_artifacts
    with_tmp_dir do |root|
      with_env("HIVE_PROVIDER_ROUTING_STATE_HOME" => root) do
        folder = File.join(root, ".hive-state", "stages", "3-generate", "bench-run")
        FileUtils.mkdir_p(folder)
        File.write(
          File.join(folder, "campaign.yml"),
          YAML.dump(
            "campaign_id" => "credit-replay",
            "tasks" => %w[complete retry terminal],
            "candidates" => [ "all-grok" ]
          )
        )
        write_bench_result(
          root, "complete",
          "cells" => [ { "task_id" => "complete", "agent_id" => "all-grok", "run_status" => "generated" } ]
        )
        write_bench_result(
          root, "retry",
          "pending" => [
            { "task_id" => "retry", "agent_id" => "all-grok",
              "failed_provider" => "grok", "reason" => "credit" }
          ]
        )
        write_bench_result(
          root, "terminal",
          "failed" => [
            { "task_id" => "terminal", "agent_id" => "all-grok", "reason" => "semantic failure" }
          ]
        )
        artifact = bench_result_path(root, "complete")
        artifact_before = File.binread(artifact)

        now = Time.utc(2026, 7, 16, 12, 0, 0)
        store = Hive::ProviderRouting::Store.new(clock: -> { now })
        leases = Hive::AttemptLeaseStore.new(clock: -> { now })
        router = Hive::ProviderRouting::Router.new(
          circuit_store: store, lease_store: leases, clock: -> { now }
        )
        account = Hive::ProviderRouting.default_accounts.fetch("grok")
        store.record(signal("grok", "credit"), account: account, now: now)
        row = Hive::Daemon::StatusConsumer::Row.new(
          project: "demo", slug: "bench-run", stage: "3-generate", workflow: "bench",
          folder: folder, state_file: File.join(folder, "generate.md"),
          state_file_mtime: now, action: "error", suggested_command: "hive generate bench-run",
          live_task_lock: false
        )
        build = lambda do
          Hive::Daemon::WorkflowRecovery.new(
            router: router, lease_store: leases,
            project_resolver: ->(_name) { { "path" => root } },
            config_loader: ->(_path) { {} },
            workflow_resolver: ->(_name, _path) { Hive::Workflows::Bench::DESCRIPTOR }
          )
        end

        assert_empty build.call.candidates([ row ], now: now), "open Grok must not rerun a paid cell"
        store.clear(provider: "grok", reason: "credits replenished", now: now)
        resume = build.call.candidates([ row ], now: now)
        assert_equal 1, resume.length
        assert_empty build.call.candidates([ row ], now: now), "workflow/generation lease must deduplicate"
        assert_equal %w[complete provider_retryable terminal], resume.first.snapshot.children.map(&:status)
        build.call.finish(resume.first, dispatched: true, now: now)
        assert_equal artifact_before, File.binread(artifact)
      end
    end
  end

  private

  def with_replay(name)
    with_tmp_dir do |home|
      with_env("HIVE_PROVIDER_ROUTING_STATE_HOME" => home) do
        replay = HiveTestProviderRoutingReplay::Replay.new(
          path: File.join(FIXTURES, name), state_home: home
        ).run
        yield replay
      end
    end
  end

  def routing_config(accounts, pin: nil, quality_floor: false)
    pool = [
      { "provider" => "claude-main", "capabilities" => { "quality" => "high" } },
      { "provider" => "codex-main", "capabilities" => { "quality" => "standard" } }
    ]
    routing = { "pool" => pool, "pin" => pin }.compact
    routing["required"] = { "quality" => "high" } if quality_floor
    Hive::ProviderRouting::Configuration.from(
      cfg: { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => accounts },
      stage_name: "replay", routing: routing, agent: "claude", source: "negative replay"
    )
  end

  def request(config, id)
    Hive::ProviderRouting::Request.new(
      configuration: config, checkpoint: id, attempt_id: id,
      provenance: { "fixture" => true }
    )
  end

  def signal(provider, failure_class)
    scope = %w[unknown network timeout].include?(failure_class) ? "none" : "provider"
    Hive::ProviderRouting::Signal.new(
      provider: provider, model: nil, failure_class: failure_class, scope: scope,
      reset_at: nil, safe_summary: "synthetic fixture", fingerprint: "sha256:fixture",
      evidence_ref: "fixture"
    )
  end

  def bench_result_path(root, task)
    File.join(root, "runs", "credit-replay", "all-grok--#{task}", "results.json")
  end

  def write_bench_result(root, task, payload)
    path = bench_result_path(root, task)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload))
  end
end
