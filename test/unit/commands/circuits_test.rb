require_relative "../../test_helper"
require "json_schemer"
require "hive/commands/circuits"

class CommandsCircuitsTest < Minitest::Test
  NOW = Time.utc(2026, 8, 10, 12)

  class DecisionIndex
    def initialize(rows = []) = @rows = rows
    def routing_decisions(limit:) = @rows.first(limit)
  end

  AttemptStore = Data.define(:decision_index) do
    def scan
      Hive::Attempts::Scan.new(records: [].freeze, invalid_records: [].freeze)
    end
  end

  def setup
    @root = Dir.mktmpdir("circuits-command")
    @health = Hive::ProviderHealth::Store.new(root: File.join(@root, "health"), clock: -> { NOW })
    @attempts = AttemptStore.new(decision_index: DecisionIndex.new)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_json_inspection_is_schema_valid_and_complete
    payload = invoke("list")

    assert_equal "hive-circuits", payload.fetch("schema")
    assert_equal "available", payload.fetch("status")
    assert_nil payload.fetch("mutation")
    assert_equal %w[model-a model-b], payload.dig("accounts", 0, "models").map { |row| row.fetch("model") }
    assert_empty schemer.validate(payload).to_a
  end

  def test_json_includes_exact_durable_decision_and_admitted_attempt_identity
    @attempts = AttemptStore.new(decision_index: DecisionIndex.new([ decision_entry ]))

    payload = invoke("list")
    identity = payload.dig("decisions", 0, "identity")

    assert_equal "demo", identity.fetch("project")
    assert_equal "attempt-1", identity.fetch("attempt_id")
    assert_equal "account-a/model-a", payload.dig("decisions", 0, "decision", "selected_route")
    assert_empty schemer.validate(payload).to_a
  end

  def test_human_inspection_explains_durable_decision_and_ordered_candidates
    @attempts = AttemptStore.new(decision_index: DecisionIndex.new([ decision_entry ]))

    stdout, = capture_io { command("list", json: false).call }

    assert_includes stdout, "decision decision-1 demo/routed-task"
    assert_includes stdout, "owner=attempt selected=account-a/model-a"
    assert_includes stdout, "candidate account-a/model-a eligible=true capacity=0/2"
    assert_includes stdout, "exclusions=none"
  end

  def test_block_requires_explicit_approval_and_does_not_mutate_without_it
    error = assert_raises(Hive::Commands::Circuits::UsageError) do
      command("block", reason: "planned provider maintenance", expected_generation: 0).call
    end

    assert_equal "consent_required", error.error_kind
    inspection = @health.inspect_scope(provider_scope)
    assert_equal 0, inspection.generation
    refute inspection.circuit.blocked?
  end

  def test_block_and_unblock_are_reason_required_generation_fenced_and_audited
    blocked = invoke(
      "block", yes: true, reason: "planned provider maintenance", expected_generation: 0
    )

    assert_equal "block", blocked.dig("mutation", "action")
    assert_equal 1, blocked.dig("mutation", "generation")
    assert_equal "uid:1234:test", blocked.dig("mutation", "audit", "actor")
    assert_equal "manual_block", blocked.dig("accounts", 0, "circuit", "state")

    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      command(
        "unblock", yes: true, reason: "maintenance complete", expected_generation: 0
      ).call
    end
    assert_equal 1, @health.inspect_scope(provider_scope).generation

    unblocked = invoke(
      "unblock", yes: true, reason: "maintenance complete", expected_generation: 1
    )
    assert_equal 2, unblocked.dig("mutation", "generation")
    assert_equal "closed", unblocked.dig("accounts", 0, "circuit", "state")
  end

  def test_model_action_is_exact_and_secret_like_reason_is_rejected_before_mutation
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      command(
        "block", provider: "account-a", model: "model-a", yes: true,
        reason: "api_key=secret-canary", expected_generation: 0
      ).call
    end
    assert_equal 0, @health.inspect_scope(model_scope("model-a")).generation

    payload = invoke(
      "block", provider: "account-a", model: "model-a", yes: true,
      reason: "model maintenance", expected_generation: 0
    )
    assert_equal "model", payload.dig("mutation", "target", "kind")
    assert_equal "manual_block", payload.dig("accounts", 0, "models", 0, "circuit", "state")
    assert_equal "closed", @health.inspect_scope(model_scope("model-b")).circuit.effective_state(now: NOW)
  end

  def test_corrupt_reset_requires_full_fresh_token_and_preserves_manual_block
    invoke(
      "block", yes: true, reason: "planned provider maintenance", expected_generation: 0
    )
    journal = File.join(
      @health.root, "scopes", "provider-account", provider_scope.key, "journal.jsonl"
    )
    File.open(journal, "ab") { |file| file.write("interior-corruption\n") }
    unavailable = invoke("inspect").dig("accounts", 0, "circuit")
    token = unavailable.fetch("corruption_token")

    repaired = invoke(
      "reset", yes: true, reason: "verified scoped journal repair",
      journal_epoch: token.fetch("journal_epoch"),
      corruption_fingerprint: token.fetch("corruption_fingerprint"),
      last_verified_generation: token.fetch("last_verified_generation")
    )

    circuit = repaired.dig("accounts", 0, "circuit")
    assert_equal "manual_block", circuit.fetch("state")
    assert_equal 2, circuit.fetch("generation")
    assert_equal 1, circuit.fetch("journal_epoch")
    assert_equal "reset", repaired.dig("mutation", "audit", "action")
    assert repaired.dig("mutation", "audit", "artifact_reference", "path")
    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      command(
        "reset", yes: true, reason: "repeat stale scoped repair",
        journal_epoch: token.fetch("journal_epoch"),
        corruption_fingerprint: token.fetch("corruption_fingerprint"),
        last_verified_generation: token.fetch("last_verified_generation")
      ).call
    end
  end

  def test_fractional_generation_and_model_without_provider_are_rejected
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "block", yes: true, reason: "planned maintenance", expected_generation: 0.5
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command("list", provider: nil, model: "model-a").call
    end
    assert_equal 0, @health.inspect_scope(provider_scope).generation
  end

  private

  def invoke(action, **options)
    stdout, = capture_io { command(action, **options.merge(json: true)).call }
    JSON.parse(stdout)
  end

  def command(action, **options)
    defaults = {
      provider: options.key?(:provider) ? options.delete(:provider) : "account-a",
      accounts: { "account-a" => account },
      health_store: @health,
      attempt_store: @attempts,
      actor_resolver: -> { "uid:1234:test" },
      clock: -> { NOW }
    }
    Hive::Commands::Circuits.new(action, **defaults.merge(options))
  end

  def account
    @account ||= Hive::ProviderRouting::Account.new(
      id: "account-a", adapter: "codex", launch_binding: "default",
      models: %w[model-b model-a], max_concurrent: 2,
      cooldown_sec: Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
    )
  end

  def decision_entry
    route = Hive::ProviderRouting::Route.new(
      id: "account-a/model-a", account: "account-a", adapter: "codex",
      launch_binding: "default", model: "model-a", effort: "high", order: 0,
      capabilities: Hive::ProviderRouting::DEFAULT_CAPABILITIES
    )
    policy = Hive::ProviderRouting::Policy.explicit(
      stage: "execute", routes: [ route ],
      requirements: Hive::ProviderRouting::Requirements.empty, pin: nil,
      account_policy: {
        "account-a" => {
          "adapter" => "codex", "launch_binding" => "default",
          "models" => [ "model-a" ], "max_concurrent" => 2,
          "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
        }
      }
    )
    request = Hive::ProviderRouting::Request.new(
      policy: policy, task_generation: "generation-1"
    )
    candidate = Hive::ProviderRouting::Candidate.new(
      route: route, exclusions: [], observed_concurrency: 0, max_concurrency: 2
    )
    decision = Hive::ProviderRouting::Decision.selected(
      request: request, route: route, considered: [ route ], candidates: [ candidate ],
      decision_id: "decision-1", decided_at: NOW
    )
    {
      "task_generation" => "generation-1",
      "subject" => {
        "kind" => "task_stage", "task_id" => "42", "task_slug" => "routed-task",
        "intended_stage" => "4-execute"
      },
      "project" => "demo",
      "attempt_id" => "attempt-1",
      "decision" => decision.to_h
    }
  end

  def provider_scope
    Hive::ProviderHealth::Scope.provider_account(account_id: "account-a")
  end

  def model_scope(model)
    Hive::ProviderHealth::Scope.model(account_id: "account-a", model_id: model)
  end

  def schemer
    @schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-circuits")))
    )
  end
end
