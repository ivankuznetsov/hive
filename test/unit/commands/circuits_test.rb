require "test_helper"
require "json_schemer"
require "hive/commands/circuits"
require "hive/provider_routing/signal"

class CommandsCircuitsTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_json_listing_is_stable_schema_valid_and_distinguishes_unlimited_caps
    with_fixture do |store, leases, accounts|
      store.record(signal("claude-main", "session_limit"), account: accounts.fetch("claude-main"), now: NOW)
      store.record(signal("claude-main", "quota", model: "opus", scope: "model"),
                   account: accounts.fetch("claude-main"), now: NOW)
      claim = leases.claim_provider(
        provider: "claude-main", model: "opus", attempt_id: "running",
        max_concurrent: 2, now: NOW
      )

      out, = capture_io do
        Hive::Commands::Circuits.new(
          nil, nil, json: true, store: store, lease_store: leases, accounts: accounts
        ).call
      end
      payload = JSON.parse(out)
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-circuits"))))

      assert schemer.valid?(payload), schemer.validate(payload).to_a.inspect
      assert_equal [ [ "claude-main", nil ], [ "claude-main", "opus" ], [ "codex-main", nil ] ],
                   payload.fetch("circuits").map { |row| [ row.fetch("provider"), row["model"] ] }
      assert_equal 1, payload.dig("circuits", 0, "observed_concurrency")
      assert_equal 2, payload.dig("circuits", 0, "max_concurrent")
      assert_nil payload.dig("circuits", 2, "max_concurrent")
      leases.release(claim.lease, now: NOW)
    end
  end

  def test_manual_clear_requires_a_real_target_and_reason_and_appends_safe_event
    with_fixture do |store, leases, accounts, home|
      store.record(signal("claude-main", "auth"), account: accounts.fetch("claude-main"), now: NOW)

      out, = capture_io do
        Hive::Commands::Circuits.new(
          "clear", "claude-main", reason: "credentials refreshed", json: true,
          store: store, lease_store: leases, accounts: accounts, actor: "operator"
        ).call
      end
      payload = JSON.parse(out)
      assert_equal "closed", payload.dig("cleared", "to")
      assert_equal "manual_clear", payload.dig("cleared", "reason")
      assert_equal "closed", store.state("claude-main").fetch("state")

      events = File.readlines(File.join(home, "provider-circuit-events.jsonl")).map { |line| JSON.parse(line) }
      clear = events.last
      assert_equal "manual_clear", clear.fetch("event")
      assert_equal "credentials refreshed", clear.fetch("summary")
      refute_includes JSON.generate(clear), "secret-token"

      assert_raises(Hive::ConfigError) do
        Hive::Commands::Circuits.new(
          "clear", "missing", reason: "fixed", store: store,
          lease_store: leases, accounts: accounts
        ).call
      end
      assert_raises(Hive::ConfigError) do
        Hive::Commands::Circuits.new(
          "clear", "claude-main", reason: " ", store: store,
          lease_store: leases, accounts: accounts
        ).call
      end
    end
  end

  def test_corrupt_store_surfaces_secret_safe_json_error_without_rewrite
    with_fixture do |store, leases, accounts|
      File.write(store.path, "{not-json secret-token")
      before = File.binread(store.path)

      out, = capture_io do
        assert_raises(Hive::ProviderRouting::StoreError) do
          Hive::Commands::Circuits.new(
            nil, nil, json: true, store: store, lease_store: leases, accounts: accounts
          ).call
        end
      end
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      refute_includes JSON.generate(payload), "secret-token"
      assert_equal before, File.binread(store.path)
    end
  end

  def test_human_listing_renders_retry_and_unlimited_concurrency
    with_fixture do |store, leases, accounts|
      store.record(signal("claude-main", "auth"), account: accounts.fetch("claude-main"), now: NOW)

      out, = capture_io do
        Hive::Commands::Circuits.new(
          nil, nil, store: store, lease_store: leases, accounts: accounts
        ).call
      end

      assert_includes out, "PROVIDER/MODEL\tADAPTER\tSTATE"
      assert_includes out, "claude-main\tclaude\topen\tauth\tmanual\t0/2"
      assert_includes out, "codex-main\tcodex\tclosed\t-\t-\t0/unlimited"
    end
  end

  def test_unknown_subcommand_is_rejected
    assert_raises(Hive::ConfigError) do
      Hive::Commands::Circuits.new("explode").call
    end
  end

  private

  def with_fixture
    with_tmp_dir do |home|
      with_env("HIVE_PROVIDER_ROUTING_STATE_HOME" => home) do
        accounts = Hive::ProviderRouting::Configuration.normalize_accounts(
          {
            "claude-main" => { "adapter" => "claude", "max_concurrent" => 2 },
            "codex-main" => { "adapter" => "codex" }
          },
          source: "test"
        )
        store = Hive::ProviderRouting::Store.new(path: File.join(home, "circuits.json"), clock: -> { NOW })
        leases = Hive::AttemptLeaseStore.new(path: File.join(home, "leases.json"), clock: -> { NOW })
        yield store, leases, accounts, home
      end
    end
  end

  def signal(provider, failure_class, model: nil, scope: "provider")
    Hive::ProviderRouting::Signal.new(
      provider: provider, model: model, failure_class: failure_class, scope: scope,
      reset_at: nil, safe_summary: "safe", fingerprint: "sha256:test", evidence_ref: "fixture"
    )
  end
end
