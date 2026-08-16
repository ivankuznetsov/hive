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

  def test_enclosing_review_stage_discovers_its_own_routing_pool
    routing = { "pool" => [ route("codex-primary", model: "gpt-5.6-sol") ] }
    cfg = Hive::Config.merge_defaults("review" => { "routing" => routing })

    entry = Hive::Config.send(:provider_routing_entries, cfg).find do |candidate|
      candidate.fetch(:stage) == "review"
    end

    refute_nil entry
    assert_equal routing, entry.fetch(:routing)
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

  def test_billing_route_is_closed_and_evidenced_without_inferring_from_ambiguous_harnesses
    normalize = lambda do |id, value|
      Hive::ProviderRouting::Configuration.normalize_accounts(
        { id => value }, source: "global providers"
      ).fetch(id)
    end
    accounts = {
      "codex-api" => normalize.call(
        "codex-api",
        account(
          "codex", binding: "default", models: %w[gpt-5.6-sol],
          billing_route: "api"
        )
      ),
      "codex-subscription" => normalize.call(
        "codex-subscription",
        account("codex", binding: "default", models: %w[gpt-5.6-terra])
      ),
      "pi-ambiguous" => normalize.call(
        "pi-ambiguous",
        account("pi", binding: "default", models: %w[provider/model])
      )
    }

    assert_equal "api", accounts.fetch("codex-api").billing_route
    assert_equal "provider_account_config",
                 accounts.fetch("codex-api").billing_evidence_source
    assert_equal "subscription", accounts.fetch("codex-subscription").billing_route
    assert_equal "agent_profile_contract",
                 accounts.fetch("codex-subscription").billing_evidence_source
    assert_equal "unknown", accounts.fetch("pi-ambiguous").billing_route
    assert_equal "unavailable", accounts.fetch("pi-ambiguous").billing_evidence_source

    cfg = Hive::Config.merge_defaults(
      "execute" => {
        "routing" => {
          "pool" => [ route("codex-api", model: "gpt-5.6-sol") ]
        }
      }
    )
    cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = accounts
    selected = Hive::ProviderRouting::Configuration.from(
      cfg: cfg, stage_name: "execute"
    ).routes.fetch(0)
    assert_equal "api", selected.billing_route
    assert_equal "provider_account_config", selected.billing_evidence_source
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

    with_tmp_dir do |binding_root|
      with_env("HIVE_PROVIDER_BINDING_CODEX_TEAM_B" => binding_root) do
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
    end
  end

  def test_named_launch_binding_must_be_available_during_configuration
    error = with_env("HIVE_PROVIDER_BINDING_CODEX_TEAM_B" => nil) do
      assert_raises(Hive::ConfigError) do
        Hive::ProviderRouting::Configuration.normalize_accounts(
          {
            "codex-primary" => account(
              "codex", binding: "team-b", models: %w[gpt-5.6-sol]
            )
          },
          source: "global providers"
        )
      end
    end

    assert_match(/launch binding "team-b".*unavailable/, error.message)
    assert_match(/HIVE_PROVIDER_BINDING_CODEX_TEAM_B/, error.message)
  end

  def test_effective_launch_binding_aliases_are_rejected
    with_tmp_dir do |root|
      real = File.join(root, "real")
      alias_path = File.join(root, "alias")
      FileUtils.mkdir_p(real)
      File.symlink(real, alias_path)
      with_env(
        "HIVE_PROVIDER_BINDING_CODEX_TEAM_A" => real,
        "HIVE_PROVIDER_BINDING_CODEX_TEAM_B" => alias_path
      ) do
        error = assert_raises(Hive::ConfigError) do
          Hive::ProviderRouting::Configuration.normalize_accounts(
            {
              "codex-a" => account("codex", binding: "team-a", models: %w[gpt-5.6-sol]),
              "codex-b" => account("codex", binding: "team-b", models: %w[gpt-5.6-terra])
            },
            source: "global providers"
          )
        end
        assert_match(/indistinguishable launch binding/, error.message)
      end
    end
  end

  def test_default_and_named_launch_binding_aliases_are_rejected
    with_tmp_dir do |root|
      with_env(
        "CODEX_HOME" => root,
        "HIVE_PROVIDER_BINDING_CODEX_TEAM_A" => root
      ) do
        error = assert_raises(Hive::ConfigError) do
          Hive::ProviderRouting::Configuration.normalize_accounts(
            {
              "codex-default" => account(
                "codex", binding: "default", models: %w[gpt-5.6-sol]
              ),
              "codex-named" => account(
                "codex", binding: "team-a", models: %w[gpt-5.6-terra]
              )
            },
            source: "global providers"
          )
        end
        assert_match(/indistinguishable launch binding/, error.message)
      end
    end
  end

  def test_invalid_default_configuration_directory_is_a_typed_configuration_error
    with_env("CODEX_HOME" => "relative/codex-home") do
      error = assert_raises(Hive::ConfigError) do
        Hive::ProviderRouting::Configuration.normalize_accounts(
          {
            "codex-default" => account(
              "codex", binding: "default", models: %w[gpt-5.6-sol]
            )
          },
          source: "global providers"
        )
      end
      assert_match(/became unavailable during validation/, error.message)
    end
  end

  def test_route_capabilities_cannot_exceed_profile_hard_limits
    error = assert_raises(Hive::ConfigError) do
      configuration_for(
        pool: [ route("codex-primary", model: "gpt-5.6-sol", tools: %w[browser]) ]
      )
    end

    assert_match(/cannot be enforced by agent profile :codex/, error.message)
  end

  def test_route_identity_is_bounded_before_policy_persistence
    model = "m" * 120
    cfg = Hive::Config.merge_defaults(
      "execute" => { "routing" => { "pool" => [ route("codex-primary", model: model) ] } }
    )
    cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] =
      Hive::ProviderRouting::Configuration.normalize_accounts(
        {
          "codex-primary" => account("codex", binding: "default", models: [ model ])
        },
        source: "global providers"
      )

    error = assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute")
    end

    assert_match(/route identifier longer than 128 bytes/, error.message)
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
      capture = JSON.parse(File.read(File.join(root, entry.fetch("real_capture"))))

      assert_equal adapter, capture.fetch("adapter")
      refute_match(/token|credential|prompt|stderr|stdout/i, JSON.generate(capture))

      if adapter == "claude"
        assert_equal "sanitized_real_capture", capture.fetch("capture_status")
        assert_equal "shared_health", capture.fetch("classification")
        assert_equal "provider_account", capture.fetch("trusted_scope")
        assert_equal "account_quota", capture.fetch("trusted_class")
        assert_equal [ "provider_account" ], entry.fetch("stable_explicit_scopes")
        assert_equal [ "account_quota" ], entry.fetch("trusted_classes")
      else
        expected_status = adapter == "pi" ?
          "subscription_capture_unavailable" : "sanitized_real_capture"
        assert_equal expected_status, capture.fetch("capture_status")
        assert_equal "task_local", capture.fetch("classification")
        assert_nil capture.fetch("trusted_scope")
        assert_empty entry.fetch("stable_explicit_scopes")
        assert_empty entry.fetch("trusted_classes")
      end
    end

    assert_equal %w[claude.json codex.json grok.json inventory.yml pi.json], Dir.children(root).sort
  end

  def test_pool_and_registry_shapes_fail_closed_at_the_opt_in_edge
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.from(
        cfg: {}, stage_name: "execute", routing: { "pool" => [] }
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.from(
        cfg: {}, stage_name: "execute",
        routing: { "pool" => [ route("codex-primary", model: "gpt-5.6-sol") ] }
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts([], source: "fixture")
    end
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts(
        {
          "Codex-A" => account("codex", binding: "default", models: %w[gpt-5.6-sol]),
          "codex-a" => account("codex", binding: "team-a", models: %w[gpt-5.6-sol])
        },
        source: "fixture"
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.normalize_accounts(
        { "ghost" => account("ghost", binding: "default", models: %w[model-a]) },
        source: "fixture"
      )
    end

    cfg = Hive::Config.merge_defaults(
      "execute" => {
        "routing" => { "pool" => [ route("codex-primary", model: "gpt-5.6-sol") ] }
      }
    )
    cfg[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] = {
      "codex-primary" => account(
        "codex", binding: "default", models: %w[gpt-5.6-sol]
      )
    }
    assert Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "execute").explicit?
  end

  def test_account_and_capability_scalar_validation_covers_every_hard_limit
    valid = account("codex", binding: "default", models: %w[gpt-5.6-sol])
    normalized = Hive::ProviderRouting::Configuration.normalize_accounts(
      { "codex-primary" => valid.merge("cooldown_sec" => { "account_quota" => 2 }) },
      source: "fixture"
    )
    assert_equal 2, normalized.fetch("codex-primary").cooldown_sec.fetch("account_quota")

    invalid_accounts = [
      { "codex" => valid.merge("cooldown_sec" => { "account_quota" => 0 }) },
      { "codex" => valid.merge("models" => []) },
      { "codex" => valid.merge("launch_binding" => "Bad!") },
      { "bad!" => valid },
      { "codex" => valid.merge("max_concurrent" => 0) },
      { "codex" => valid.merge("adapter" => nil) },
      { "codex" => [] },
      { "codex" => valid.merge(1 => true) },
      { "codex" => valid.merge("future" => true) }
    ]
    invalid_accounts.each do |providers|
      assert_raises(Hive::ConfigError) do
        Hive::ProviderRouting::Configuration.normalize_accounts(providers, source: "fixture")
      end
    end

    invalid_routes = [
      route("codex-primary", model: "gpt-5.6-sol", tools: "shell"),
      route("codex-primary", model: "gpt-5.6-sol", tools: %w[root]),
      route("codex-primary", model: "gpt-5.6-sol", context: "enormous")
    ]
    invalid_routes.each do |candidate|
      assert_raises(Hive::ConfigError) { configuration_for(pool: [ candidate ]) }
    end
  end

  def test_missing_candidate_model_and_unknown_model_stage_are_configuration_errors
    resolution = Struct.new(:model, :effort).new(nil, "high")
    with_replaced_singleton_method(
      Hive::ModelRouting, :resolve_candidate, ->(**) { resolution }
    ) do
      assert_raises(Hive::ConfigError) do
        configuration_for(pool: [ route("codex-primary", model: "gpt-5.6-sol") ])
      end
    end

    cfg = routed_config(
      "execute" => {
        "routing" => { "pool" => [ route("codex-primary", model: "gpt-5.6-sol") ] }
      }
    )
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.from(
        cfg: cfg, stage_name: "unknown.stage",
        routing: cfg.dig("execute", "routing")
      )
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

  def account(adapter, binding:, models:, billing_route: nil)
    {
      "adapter" => adapter,
      "launch_binding" => binding,
      "models" => models,
      "max_concurrent" => 2
    }.tap do |value|
      value["billing_route"] = billing_route if billing_route
    end
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
