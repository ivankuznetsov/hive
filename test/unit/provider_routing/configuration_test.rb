require_relative "../../test_helper"
require "hive/config"
require "hive/provider_routing"

class ProviderRoutingConfigurationTest < Minitest::Test
  include HiveTestHelper

  def test_legacy_stage_resolves_to_pool_of_one_without_provider_cap
    cfg = Hive::Config.merge_defaults(
      "execute" => { "agent" => "codex" },
      "claude" => { "model" => "default", "effort" => "default" }
    )

    routing = Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute")

    assert_equal 1, routing.pool.length
    candidate = routing.pool.first
    assert_equal "codex", candidate.provider
    assert_equal "codex", candidate.agent
    assert_nil candidate.model
    assert_nil candidate.effort
    assert_nil routing.accounts.fetch("codex").max_concurrent
  end

  def test_descriptor_agent_model_and_effort_win_when_pool_is_absent
    descriptor = Struct.new(:agent, :model, :effort, :routing).new("claude", "sonnet", "high", nil)
    cfg = Hive::Config.merge_defaults("execute" => { "agent" => "codex" })

    candidate = Hive::ProviderRouting::Configuration.from(
      cfg: cfg,
      stage_name: "execute",
      descriptor: descriptor
    ).pool.first

    assert_equal [ "claude", "claude", "sonnet", "high" ],
                 [ candidate.provider, candidate.agent, candidate.model, candidate.effort ]
  end

  def test_explicit_pool_is_authoritative_and_preserves_declaration_order
    cfg = config_with_accounts(
      "execute" => {
        "agent" => "claude",
        "routing" => {
          "pool" => [
            candidate("codex-main", agent: "codex", model: "gpt-5"),
            candidate("claude-main", agent: "claude", model: "default")
          ],
          "required" => {
            "context" => "large",
            "quality" => "high",
            "tools" => [ "shell" ],
            "permissions" => %w[read write]
          }
        }
      }
    )

    routing = Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute")

    assert_equal %w[codex-main claude-main], routing.pool.map(&:provider)
    assert_equal %w[codex claude], routing.pool.map(&:agent)
    assert_equal "large", routing.required.context
    assert_equal %w[read write], routing.required.permissions
  end

  def test_pin_must_reference_an_entry_in_the_pool
    cfg = config_with_accounts(
      "plan" => {
        "routing" => {
          "pool" => [ candidate("claude-main", agent: "claude") ],
          "pin" => { "provider" => "codex-main" }
        }
      }
    )

    error = assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "plan")
    end

    assert_includes error.message, "plan.routing.pin"
    assert_includes error.message, "does not match an entry"
  end

  def test_rejects_invalid_pool_and_capability_values_with_paths
    invalid = {
      "unknown provider" => [ candidate("missing", agent: "claude"), "execute.routing.pool[0].provider" ],
      "unknown adapter" => [ candidate("claude-main", agent: "missing"), "execute.routing.pool[0].agent" ],
      "unknown context" => [ candidate("claude-main", agent: "claude", context: "huge"), "capabilities.context" ],
      "unknown capability key" => [ candidate("claude-main", agent: "claude").merge("capabilities" => { "vision" => true }), "capabilities contains unknown" ]
    }

    invalid.each_value do |(entry, expected)|
      cfg = config_with_accounts("execute" => { "routing" => { "pool" => [ entry ] } })
      error = assert_raises(Hive::ConfigError) do
        Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute")
      end
      assert_includes error.message, expected
    end
  end

  def test_rejects_duplicate_provider_model_entries
    entry = candidate("claude-main", agent: "claude", model: "default")
    cfg = config_with_accounts("plan" => { "routing" => { "pool" => [ entry, entry.dup ] } })

    error = assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "plan")
    end

    assert_includes error.message, "duplicate provider/model entry"
  end

  def test_one_provider_account_can_be_used_through_two_adapter_identities
    cfg = config_with_accounts(
      "plan" => {
        "routing" => {
          "pool" => [
            candidate("claude-main", agent: "claude", model: "default"),
            candidate("claude-main", agent: "codex", model: "gpt-5")
          ]
        }
      }
    )

    routing = Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "plan")

    assert_equal [ "claude", "codex" ], routing.pool.map(&:agent)
    assert_equal [ "claude-main", "claude-main" ], routing.pool.map(&:provider)
  end

  def test_global_provider_validation_rejects_non_positive_policy_values
    raw = {
      "bad" => {
        "adapter" => "claude",
        "max_concurrent" => 0,
        "cooldown_sec" => { "quota" => -1 },
        "backoff_cap_sec" => 0
      }
    }

    error = assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts(raw, source: "global providers")
    end

    assert_includes error.message, "providers.bad.max_concurrent"
  end

  def test_global_provider_registry_validates_shape_adapter_and_full_policy
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts([], source: "global providers")
    end
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts(
        { "bad" => { "adapter" => "ghost" } }, source: "global providers"
      )
    end

    accounts = Hive::ProviderRouting::Configuration.normalize_accounts(
      {
        claude_main: {
          adapter: :claude,
          backoff_cap_sec: 7200,
          cooldown_sec: { rate_limit: 12 }
        }
      },
      source: "global providers"
    )
    account = accounts.fetch("claude_main")
    assert_equal "claude", account.adapter
    assert_equal 7200, account.backoff_cap_sec
    assert_equal 12, account.cooldown_sec.fetch("rate_limit")
  end

  def test_empty_account_adapter_and_unmapped_legacy_adapter_are_rejected
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts(
        { "empty" => { "adapter" => "" } }, source: "global providers"
      )
    end

    accounts = Hive::ProviderRouting::Configuration.normalize_accounts(
      { "claude-main" => { "adapter" => "claude" } }, source: "global providers"
    )
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.new(
        accounts: accounts,
        routing: nil,
        legacy: { "agent" => "codex", "model" => nil, "effort" => nil },
        source: "test.routing"
      )
    end
  end

  private

  def candidate(provider, agent:, model: nil, context: "large")
    {
      "provider" => provider,
      "agent" => agent,
      "model" => model,
      "capabilities" => {
        "context" => context,
        "quality" => "high",
        "tools" => %w[shell filesystem],
        "permissions" => %w[read write]
      }
    }.compact
  end

  def config_with_accounts(overrides)
    cfg = Hive::Config.merge_defaults(overrides)
    cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] =
      Hive::ProviderRouting::Configuration.normalize_accounts(
        {
          "claude-main" => { "adapter" => "claude", "max_concurrent" => 2 },
          "codex-main" => { "adapter" => "codex" }
        },
        source: "global providers"
      )
    cfg
  end
end
