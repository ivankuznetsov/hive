require_relative "../../test_helper"
require "hive/config"
require "hive/provider_routing/router"

class ProviderRoutingRouterTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def setup
    @now = NOW
  end

  def test_healthy_pool_always_selects_first_declared_candidate
    with_router do |router, _circuits, _leases|
      config = configuration(pool: [ candidate("claude-main", "claude"), candidate("codex-main", "codex") ])

      decision = router.select(request(config, "a1"))

      assert decision.selected?
      assert_equal "claude-main", decision.provider
      assert_equal "first_eligible", decision.reason
      router.cancel(decision)
    end
  end

  def test_provider_open_falls_back_and_model_open_leaves_sibling_eligible
    with_router do |router, circuits, _leases|
      provider_config = configuration(
        pool: [ candidate("claude-main", "claude"), candidate("codex-main", "codex") ]
      )
      circuits.record(signal("session_limit", provider: "claude-main"),
                      account: provider_config.accounts.fetch("claude-main"), now: @now)

      fallback = router.select(request(provider_config, "provider-open"))
      assert_equal "codex-main", fallback.provider
      assert_equal "circuit_open", fallback.rejections.first.reason
      router.cancel(fallback)

      model_config = configuration(
        pool: [
          candidate("claude-main", "claude", model: "opus"),
          candidate("claude-main", "claude", model: "sonnet")
        ]
      )
      circuits.clear(provider: "claude-main", reason: "test reset", now: @now)
      circuits.record(signal("quota", provider: "claude-main", model: "opus", scope: "model"),
                      account: model_config.accounts.fetch("claude-main"), now: @now)

      sibling = router.select(request(model_config, "model-open"))
      assert_equal "sonnet", sibling.model
      router.cancel(sibling)
    end
  end

  def test_hard_pin_to_open_provider_waits_without_fallback
    with_router do |router, circuits, _leases|
      config = configuration(
        pool: [ candidate("claude-main", "claude"), candidate("codex-main", "codex") ],
        pin: { "provider" => "claude-main" }
      )
      circuits.record(signal("session_limit", provider: "claude-main"),
                      account: config.accounts.fetch("claude-main"), now: @now)

      decision = router.select(request(config, "pinned"))

      assert decision.wait?
      assert_equal "limits_reached", decision.wait_reason
      assert_equal [ "claude-main" ], decision.rejections.map(&:provider)
    end
  end

  def test_quality_tools_permissions_and_context_are_strict_constraints
    with_router do |router, _circuits, _leases|
      config = configuration(
        pool: [
          candidate(
            "codex-main", "codex", context: "standard", quality: "standard",
            tools: [ "filesystem" ], permissions: [ "read" ]
          )
        ],
        required: {
          "context" => "large", "quality" => "high", "tools" => [ "shell" ],
          "permissions" => %w[read write]
        }
      )

      decision = router.select(request(config, "strict"))

      assert decision.wait?
      assert_equal "routing_constraints_unsatisfied", decision.wait_reason
      assert_equal "context_too_small", decision.reason
    end
  end

  def test_context_overflow_excludes_only_failed_entry_for_checkpoint
    with_router do |router, circuits, _leases|
      config = configuration(
        pool: [
          candidate("claude-main", "claude", context: "standard"),
          candidate("codex-main", "codex", context: "large")
        ]
      )
      first_request = request(config, "before-context")
      first = router.select(first_request)
      context_signal = signal(
        "context_length", provider: "claude-main", scope: "none"
      )
      outcome = router.record_outcome(
        decision: first, success: false, signal: context_signal, checkpoint: "generation-1"
      )
      retried = first_request.with_exclusion(
        provider: outcome.exclusion.provider, model: outcome.exclusion.model
      )

      second = router.select(retried)
      assert_equal "codex-main", second.provider
      assert_equal "context_excluded", second.rejections.first.reason
      assert_equal "closed", circuits.state("claude-main").fetch("state")
      router.cancel(second)

      unrelated = router.select(request(config, "unrelated", checkpoint: "generation-2"))
      assert_equal "claude-main", unrelated.provider
      router.cancel(unrelated)
    end
  end

  def test_configured_provider_cap_falls_back_while_unset_cap_never_blocks
    with_router do |router, _circuits, leases|
      capped = configuration(
        pool: [ candidate("claude-main", "claude"), candidate("codex-main", "codex") ],
        max_concurrent: { "claude-main" => 1 }
      )
      occupied = leases.claim_provider(
        provider: "claude-main", model: nil, attempt_id: "occupied",
        max_concurrent: 1, ttl_sec: 3600, now: @now
      )

      fallback = router.select(request(capped, "capped"))
      assert_equal "codex-main", fallback.provider
      assert_equal "provider_cap", fallback.rejections.first.reason
      router.cancel(fallback)
      leases.release(occupied.lease, now: @now)

      unlimited = configuration(
        pool: [ candidate("claude-main", "claude") ],
        max_concurrent: { "claude-main" => nil }
      )
      first = router.select(request(unlimited, "unlimited-1"))
      second = router.select(request(unlimited, "unlimited-2"))
      assert first.selected?
      assert second.selected?
      router.cancel(first)
      router.cancel(second)
    end
  end

  def test_exactly_one_probe_runs_then_success_restores_preferred_for_new_work
    with_router do |router, circuits, _leases|
      config = configuration(
        pool: [ candidate("claude-main", "claude"), candidate("codex-main", "codex") ]
      )
      circuits.record(signal("rate_limit", provider: "claude-main"),
                      account: config.accounts.fetch("claude-main"), now: @now)
      @now += 300

      probe = router.select(request(config, "probe"))
      fallback = router.select(request(config, "other"))
      assert probe.probe?
      assert_equal "claude-main", probe.provider
      assert_equal "codex-main", fallback.provider
      assert_equal "probe_claimed", fallback.rejections.first.reason

      router.record_outcome(decision: probe, success: true)
      restored = router.select(request(config, "restored"))
      assert_equal "claude-main", restored.provider
      assert_equal "codex-main", fallback.provider, "already-selected fallback work is never preempted"
      router.cancel(fallback)
      router.cancel(restored)
    end
  end

  def test_concurrent_cooldown_dispatches_claim_exactly_one_real_probe
    skip "fork unavailable" unless Process.respond_to?(:fork)

    with_router do |_router, circuits, leases|
      config = configuration(
        pool: [ candidate("claude-main", "claude"), candidate("codex-main", "codex") ]
      )
      circuits.record(signal("rate_limit", provider: "claude-main"),
                      account: config.accounts.fetch("claude-main"), now: @now)
      @now += 300
      circuit_path = circuits.path
      lease_path = leases.path

      pids = 4.times.map do |index|
        fork do
          child_router = Hive::ProviderRouting::Router.new(
            circuit_store: Hive::ProviderRouting::Store.new(path: circuit_path, clock: -> { @now }),
            lease_store: Hive::AttemptLeaseStore.new(
              path: lease_path, clock: -> { @now }, owner_alive: ->(_pid, _start) { true }
            ),
            clock: -> { @now }
          )
          decision = child_router.select(request(config, "race-#{index}"))
          exit!(decision.provider == "claude-main" ? 0 : 1)
        end
      end
      statuses = pids.map { |pid| Process.wait2(pid).last.exitstatus }

      assert_equal 1, statuses.count(0)
      assert_equal 3, statuses.count(1)
    end
  end

  def test_probe_claim_is_rolled_back_when_capacity_reservation_loses
    with_router do |router, circuits, leases|
      config = configuration(
        pool: [ candidate("claude-main", "claude"), candidate("codex-main", "codex") ],
        max_concurrent: { "claude-main" => 1 }
      )
      circuits.record(signal("rate_limit", provider: "claude-main"),
                      account: config.accounts.fetch("claude-main"), now: @now)
      occupied = leases.claim_provider(
        provider: "claude-main", model: nil, attempt_id: "occupied-probe",
        max_concurrent: 1, ttl_sec: 3600, now: @now
      )
      @now += 300

      fallback = router.select(request(config, "probe-cap"))

      assert_equal "codex-main", fallback.provider
      state = circuits.state("claude-main")
      assert_equal "open", state.fetch("state")
      assert_nil state["probe"]
      router.cancel(fallback)
      leases.release(occupied.lease, now: @now)
    end
  end

  def test_failed_probe_reopens_with_capped_exponential_backoff
    with_router do |router, circuits, _leases|
      config = configuration(pool: [ candidate("claude-main", "claude") ])
      circuits.record(signal("rate_limit", provider: "claude-main"),
                      account: config.accounts.fetch("claude-main"), now: @now)
      @now += 300
      probe = router.select(request(config, "failed-probe"))

      router.record_outcome(
        decision: probe,
        success: false,
        signal: signal("unknown", provider: "claude-main", scope: "none")
      )
      state = circuits.state("claude-main")

      assert_equal "open", state.fetch("state")
      assert_equal 1, state.fetch("backoff_count")
      assert_equal(@now + 600, Time.iso8601(state.fetch("retry_at")))
    end
  end

  def test_corrupt_shared_state_fails_closed_with_visible_reason
    with_tmp_dir do |dir|
      circuit_path = File.join(dir, "circuits.json")
      File.write(circuit_path, "broken\n")
      router = Hive::ProviderRouting::Router.new(
        circuit_store: Hive::ProviderRouting::Store.new(path: circuit_path),
        lease_store: Hive::AttemptLeaseStore.new(path: File.join(dir, "leases.json"))
      )
      config = configuration(pool: [ candidate("claude-main", "claude") ])

      decision = router.select(request(config, "corrupt"))

      assert decision.wait?
      assert_equal "routing_state_unavailable", decision.reason
      assert_equal "limits_reached", decision.wait_reason
    end
  end

  private

  def with_router
    with_tmp_dir do |dir|
      circuits = Hive::ProviderRouting::Store.new(
        path: File.join(dir, "circuits.json"), clock: -> { @now }
      )
      leases = Hive::AttemptLeaseStore.new(
        path: File.join(dir, "leases.json"), clock: -> { @now },
        owner_alive: ->(_pid, _start) { true }
      )
      router = Hive::ProviderRouting::Router.new(
        circuit_store: circuits, lease_store: leases, clock: -> { @now }
      )
      yield router, circuits, leases
    end
  end

  def request(config, id, checkpoint: "generation-1")
    Hive::ProviderRouting::Request.new(
      configuration: config,
      checkpoint: checkpoint,
      attempt_id: id,
      provenance: { "task" => "router-test" }
    )
  end

  def configuration(pool:, pin: nil, required: nil, max_concurrent: {})
    accounts = {
      "claude-main" => { "adapter" => "claude" },
      "codex-main" => { "adapter" => "codex" }
    }
    max_concurrent.each do |provider, cap|
      accounts.fetch(provider)["max_concurrent"] = cap unless cap.nil?
    end
    cfg = Hive::Config.merge_defaults(
      "execute" => {
        "routing" => {
          "pool" => pool,
          "pin" => pin,
          "required" => required
        }.compact
      }
    )
    cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] =
      Hive::ProviderRouting::Configuration.normalize_accounts(accounts, source: "test providers")
    Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute")
  end

  def candidate(provider, agent, model: nil, context: "large", quality: "high",
                tools: %w[shell filesystem], permissions: %w[read write])
    {
      "provider" => provider,
      "agent" => agent,
      "model" => model,
      "capabilities" => {
        "context" => context,
        "quality" => quality,
        "tools" => tools,
        "permissions" => permissions
      }
    }.compact
  end

  def signal(failure_class, provider:, model: nil, scope: "provider")
    Hive::ProviderRouting::Signal.new(
      provider: provider,
      model: model,
      failure_class: failure_class,
      scope: scope,
      reset_at: nil,
      safe_summary: failure_class,
      fingerprint: "fp-#{failure_class}",
      evidence_ref: "logs/router-test.log"
    )
  end
end
