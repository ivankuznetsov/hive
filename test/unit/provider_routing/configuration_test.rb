require_relative "../../test_helper"
require "hive/config"
require "hive/provider_routing"

class ProviderRoutingConfigurationTest < Minitest::Test
  include HiveTestHelper

  def test_missing_pool_is_a_structural_legacy_bypass
    configuration = Hive::ProviderRouting::Configuration.from(
      cfg: Hive::Config.merge_defaults("execute" => { "agent" => "codex" }),
      stage_name: "execute"
    )

    assert configuration.legacy?
    assert configuration.policy.legacy?
    assert_empty configuration.accounts
    assert_empty configuration.routes
    assert_nil configuration.digest
  end

  def test_explicit_pool_resolves_model_routing_per_candidate_without_changing_account
    cfg = routed_config(
      "models" => {
        "execute" => { "effort" => "high" },
        "execute_implementation" => { "model" => "gpt-5.6-sol" }
      },
      "execute" => {
        "routing" => {
          "pool" => [
            route("codex-primary", model: "gpt-5.6-terra", effort: "medium"),
            route("claude-primary", model: "sonnet", effort: "low")
          ]
        }
      }
    )

    configuration = Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute")

    assert configuration.explicit?
    assert_equal %w[codex-primary claude-primary], configuration.routes.map(&:account)
    assert_equal %w[gpt-5.6-sol gpt-5.6-sol], configuration.routes.map(&:model)
    assert_equal %w[high high], configuration.routes.map(&:effort)
    assert_equal %w[codex claude], configuration.routes.map(&:adapter)
    assert_equal [ :exact, :exact ],
                 configuration.routes.map { |candidate| candidate.model_routing.provenance[:model].kind }
    assert_equal [ :coarse, :coarse ],
                 configuration.routes.map { |candidate| candidate.model_routing.provenance[:effort].kind }
  end

  def test_provider_and_exact_pins_never_cross_account_boundaries
    provider_policy = configuration_for(
      pool: [
        route("codex-primary", model: "gpt-5.6-sol"),
        route("codex-primary", model: "gpt-5.6-terra"),
        route("claude-primary", model: "sonnet")
      ],
      pin: { "provider" => "codex-primary" }
    ).policy

    assert_equal %w[gpt-5.6-sol gpt-5.6-terra],
                 provider_policy.eligible_routes.map(&:model)

    exact_policy = configuration_for(
      pool: provider_policy.routes.map { |candidate| route(candidate.account, model: candidate.model) },
      pin: { "provider" => "codex-primary", "model" => "gpt-5.6-terra" }
    ).policy

    assert_equal [ [ "codex-primary", "gpt-5.6-terra" ] ],
                 exact_policy.eligible_routes.map { |candidate| [ candidate.account, candidate.model ] }
  end

  def test_requirements_filter_without_reordering_survivors
    configuration = configuration_for(
      pool: [
        route("codex-primary", model: "gpt-5.6-sol", quality: "high", tools: %w[shell filesystem]),
        route("codex-primary", model: "gpt-5.6-terra", quality: "standard", tools: %w[shell]),
        route("claude-primary", model: "sonnet", quality: "high", tools: %w[shell filesystem])
      ],
      required: { "quality" => "high", "tools" => %w[filesystem] }
    )

    assert_equal %w[codex-primary/gpt-5.6-sol claude-primary/sonnet],
                 configuration.policy.eligible_routes.map(&:id)
    assert_equal %w[codex-primary/gpt-5.6-sol codex-primary/gpt-5.6-terra claude-primary/sonnet],
                 configuration.routes.map(&:id)
  end

  def test_invalid_accounts_routes_requirements_and_pins_fail_before_dispatch
    cases = {
      "unknown account" => [
        -> { configuration_for(pool: [ route("missing", model: "gpt-5.6-sol") ]) },
        /references unknown provider account "missing"/
      ],
      "unknown model" => [
        -> { configuration_for(pool: [ route("codex-primary", model: "gpt-unknown") ]) },
        /model "gpt-unknown" is not configured for provider account "codex-primary"/
      ],
      "candidate adapter override" => [
        -> {
          entry = route("codex-primary", model: "gpt-5.6-sol").merge("agent" => "claude")
          configuration_for(pool: [ entry ])
        },
        /per-candidate adapter overrides are not allowed/
      ],
      "duplicate normalized route" => [
        -> {
          entry = route("codex-primary", model: "gpt-5.6-sol")
          configuration_for(pool: [ entry, entry.dup ])
        },
        /duplicate normalized route/
      ],
      "impossible requirement" => [
        -> {
          configuration_for(
            pool: [ route("codex-primary", model: "gpt-5.6-sol", quality: "standard") ],
            required: { "quality" => "high" }
          )
        },
        /requirements exclude every route/
      ],
      "unmatched pin" => [
        -> {
          configuration_for(
            pool: [ route("codex-primary", model: "gpt-5.6-sol") ],
            pin: { "provider" => "claude-primary" }
          )
        },
        /pin does not match a configured route/
      ]
    }

    cases.each do |label, (operation, pattern)|
      error = assert_raises(Hive::ConfigError, label, &operation)
      assert_match pattern, error.message, label
    end
  end

  def test_accounts_on_one_adapter_require_distinct_non_secret_launch_bindings
    error = assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts(
        {
          "codex-a" => account("codex", binding: "default", models: %w[gpt-5.6-sol]),
          "codex-b" => account("codex", binding: "default", models: %w[gpt-5.6-terra])
        },
        source: "global providers"
      )
    end

    assert_match(/indistinguishable launch binding/, error.message)

    accounts = Hive::ProviderRouting::Configuration.normalize_accounts(
      {
        "codex-a" => account("codex", binding: "default", models: %w[gpt-5.6-sol]),
        "codex-b" => account("codex", binding: "team-b", models: %w[gpt-5.6-terra])
      },
      source: "global providers"
    )

    assert_equal %w[default team-b], accounts.values.map(&:launch_binding)
    assert accounts.frozen?
  end

  def test_policy_digest_is_stable_and_covers_every_selection_input
    first = configuration_for(
      pool: [ route("codex-primary", model: "gpt-5.6-sol") ],
      required: { "quality" => "high" }
    )
    same = configuration_for(
      pool: [ route("codex-primary", model: "gpt-5.6-sol") ],
      required: { "quality" => "high" }
    )
    changed = configuration_for(
      pool: [ route("codex-primary", model: "gpt-5.6-sol", permissions: %w[read]) ],
      required: { "quality" => "high" }
    )

    assert_match(/\A[0-9a-f]{64}\z/, first.digest)
    assert_equal first.digest, same.digest
    refute_equal first.digest, changed.digest
    assert first.frozen?
    assert first.policy.frozen?
    assert first.routes.all?(&:frozen?)
  end

  def test_config_load_skips_the_global_registry_without_a_pool_and_loads_it_for_opt_in
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => [], "providers" => "malformed-but-dormant" }.to_yaml
      )
      Dir.mktmpdir("provider-routing-project") do |project|
        FileUtils.mkdir_p(File.join(project, ".hive-state"))
        File.write(
          File.join(project, ".hive-state", "config.yml"),
          { "execute" => { "agent" => "codex" } }.to_yaml
        )

        cfg = Hive::Config.load(project)

        refute cfg.key?(Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY)
      end

      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [],
          "providers" => {
            "codex-primary" => account(
              "codex", binding: "default", models: %w[gpt-5.6-sol]
            )
          }
        }.to_yaml
      )
      Dir.mktmpdir("provider-routing-project") do |project|
        FileUtils.mkdir_p(File.join(project, ".hive-state"))
        File.write(
          File.join(project, ".hive-state", "config.yml"),
          {
            "execute" => {
              "agent" => "codex",
              "routing" => {
                "pool" => [ route("codex-primary", model: "gpt-5.6-sol") ]
              }
            }
          }.to_yaml
        )

        cfg = Hive::Config.load(project)
        accounts = cfg.fetch(Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY)

        assert_equal [ "codex-primary" ], accounts.keys
        assert_instance_of Hive::ProviderRouting::Account, accounts.fetch("codex-primary")
      end
    end
  end

  def test_config_load_rejects_routing_options_without_an_explicit_pool
    with_tmp_global_config do
      Dir.mktmpdir("provider-routing-project") do |project|
        FileUtils.mkdir_p(File.join(project, ".hive-state"))
        File.write(
          File.join(project, ".hive-state", "config.yml"),
          {
            "execute" => {
              "agent" => "codex",
              "routing" => { "required" => { "quality" => "high" } }
            }
          }.to_yaml
        )

        error = assert_raises(Hive::ConfigError) { Hive::Config.load(project) }
        assert_match(/routing.*pool is required/, error.message)
      end
    end
  end

  def test_sanitized_provenance_inventory_is_complete_and_fail_closed
    root = File.expand_path("../../fixtures/provider_errors", __dir__)
    inventory = YAML.safe_load_file(File.join(root, "inventory.yml"), aliases: false)

    assert_equal %w[claude codex grok pi], inventory.fetch("adapters").keys.sort
    inventory.fetch("adapters").each do |adapter, entry|
      capture = JSON.parse(File.read(File.join(root, entry.fetch("fixture"))))

      assert_equal adapter, capture.fetch("adapter")
      assert_equal "real_capture_pending", capture.fetch("capture_status")
      assert_equal "task_local", capture.fetch("classification")
      assert_nil capture.fetch("trusted_scope")
      assert_empty entry.fetch("stable_explicit_scopes")
      refute_match(/token|credential|prompt|stderr|stdout/i, JSON.generate(capture))
    end
  end

  private

  def configuration_for(pool:, required: nil, pin: nil)
    routing = { "pool" => pool }
    routing["required"] = required if required
    routing["pin"] = pin if pin
    cfg = routed_config("execute" => { "routing" => routing })
    Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute")
  end

  def routed_config(overrides)
    cfg = Hive::Config.merge_defaults(overrides)
    cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] =
      Hive::ProviderRouting::Configuration.normalize_accounts(
        {
          "codex-primary" => account(
            "codex", binding: "default", models: %w[gpt-5.6-sol gpt-5.6-terra]
          ),
          "claude-primary" => account(
            "claude", binding: "default", models: %w[gpt-5.6-sol sonnet]
          )
        },
        source: "global providers"
      )
    cfg
  end

  def account(adapter, binding:, models:)
    {
      "adapter" => adapter,
      "launch_binding" => binding,
      "models" => models,
      "max_concurrent" => 2
    }
  end

  def route(provider, model:, effort: "high", quality: "high",
            context: "large", tools: %w[shell filesystem], permissions: %w[read write])
    {
      "provider" => provider,
      "model" => model,
      "effort" => effort,
      "capabilities" => {
        "quality" => quality,
        "context" => context,
        "tools" => tools,
        "permissions" => permissions
      }
    }
  end
end
