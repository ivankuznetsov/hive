require_relative "../../test_helper"
require "json_schemer"
require "hive/commands/circuits"

class CommandsCircuitsTest < Minitest::Test
  include HiveTestHelper

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

  def test_default_clock_is_utc
    now = Hive::Commands::Circuits.new(accounts: {}).send(:now)

    assert_instance_of Time, now
    assert now.utc?
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

  def test_corrupt_probe_intent_is_visible_and_requires_exact_approved_quarantine
    intent = File.join(@health.root, "intents", "bad.json")
    File.binwrite(intent, "{")

    unavailable = invoke("list")
    corruption = unavailable.fetch("intent_corruptions").fetch(0)
    assert_equal "degraded", unavailable.fetch("status")
    assert_equal "bad.json", corruption.fetch("intent_file")
    assert_includes unavailable.fetch("issues").join(" "), "probe intent state is unavailable"
    assert_empty schemer.validate(unavailable).to_a

    repaired = invoke(
      "reset-intent",
      provider: nil,
      yes: true,
      reason: "quarantine corrupt global probe intent",
      intent_file: corruption.fetch("intent_file"),
      corruption_fingerprint: corruption.fetch("corruption_fingerprint")
    )
    assert_equal "available", repaired.fetch("status")
    assert_empty repaired.fetch("intent_corruptions")
    assert_equal "reset_intent", repaired.dig("mutation", "action")
    assert_equal "probe_intent", repaired.dig("mutation", "target", "kind")
    assert_nil repaired.dig("mutation", "generation")
    assert File.file?(File.join(
      @health.root,
      repaired.dig("mutation", "audit", "artifact_reference", "path")
    ))
    assert_empty schemer.validate(repaired).to_a

    assert_raises(Hive::ProviderHealth::StaleGeneration) do
      command(
        "reset-intent",
        provider: nil,
        yes: true,
        reason: "repeat stale probe intent repair",
        intent_file: corruption.fetch("intent_file"),
        corruption_fingerprint: corruption.fetch("corruption_fingerprint")
      ).call
    end
  end

  def test_human_inspection_renders_multiple_corrupt_probe_intent_tokens
    File.binwrite(File.join(@health.root, "intents", "first.json"), "{")
    File.binwrite(File.join(@health.root, "intents", "second.json"), "[")

    stdout, = capture_io { command("list", json: false).call }

    assert_includes stdout, "2 corrupt artifacts"
    assert_includes stdout, "probe-intent first.json repair_fingerprint="
    assert_includes stdout, "probe-intent second.json repair_fingerprint="
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

  def test_error_envelope_classification_and_unknown_actions_are_stable
    subject = Hive::Commands::Circuits.new(accounts: {})
    cases = {
      Hive::Commands::Circuits::UsageError.new("usage") => "usage",
      Hive::ProviderHealth::StaleGeneration.new("stale") => "stale_generation",
      Hive::ProviderHealth::InvalidMutation.new("invalid") => "usage",
      Hive::ProviderHealth::InvalidScope.new("scope") => "usage",
      Hive::ProviderHealth::Unavailable.new("unavailable") => "unavailable",
      Hive::Attempts::StoreError.new("store") => "unavailable",
      Hive::ConfigError.new("config") => "config",
      RuntimeError.new("bug") => "internal"
    }
    cases.each do |error, expected|
      assert_equal expected, subject.envelope_error_kind(error)
    end

    error = assert_raises(Hive::Commands::Circuits::UsageError) do
      command("future-action").call
    end
    assert_match(/unknown action/, error.message)
  end

  def test_mutation_options_require_reason_scope_generation_and_complete_tokens
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command("block", yes: true, reason: " ", expected_generation: 0).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command("block", yes: true, reason: "maintenance").call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "block", yes: true, reason: "maintenance", expected_generation: 0,
        journal_epoch: 0
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "block", yes: true, reason: "maintenance", expected_generation: 0,
        intent_file: "bad.json"
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "reset", yes: true, reason: "repair", journal_epoch: 0,
        corruption_fingerprint: "a" * 64
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "reset", yes: true, reason: "repair", expected_generation: 0,
        journal_epoch: 0, corruption_fingerprint: "a" * 64,
        last_verified_generation: 0
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "block", provider: nil, yes: true,
        reason: "maintenance", expected_generation: 0
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "block", provider: "unknown", yes: true,
        reason: "maintenance", expected_generation: 0
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "block", model: "unknown", yes: true,
        reason: "maintenance", expected_generation: 0
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command("list", model: "unknown").call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command("list").send(:integer_option, -1, "--expected-generation")
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "reset-intent", provider: nil, yes: true, reason: "repair",
        corruption_fingerprint: "a" * 64
      ).call
    end
    assert_raises(Hive::Commands::Circuits::UsageError) do
      command(
        "reset-intent", yes: true, reason: "repair", intent_file: "bad.json",
        corruption_fingerprint: "a" * 64
      ).call
    end
  end

  def test_healthy_reset_and_human_mutation_render_the_audited_result
    reset = invoke(
      "reset", yes: true, reason: "clear observed state", expected_generation: 0
    )
    assert_equal 1, reset.dig("mutation", "generation")

    stdout, = capture_io do
      command(
        "block", json: false, yes: true,
        reason: "planned maintenance", expected_generation: 1
      ).call
    end
    assert_includes stdout, "MUTATION block accepted generation=2"
  end

  def test_human_helpers_render_probe_evidence_repair_tokens_and_scoped_exclusions
    circuit = {
      "state" => "open", "generation" => 3, "journal_epoch" => 1,
      "eligible_at" => NOW.iso8601(6), "reason" => "provider_outage",
      "probe_owner" => { "attempt_id" => "attempt-1", "claim_generation" => 3 },
      "evidence" => {
        "failure_class" => "provider_outage", "fingerprint" => "a" * 64,
        "source_reference" => { "path" => "outputs/safe.json" }
      },
      "corruption_token" => {
        "journal_epoch" => 1, "corruption_fingerprint" => "b" * 64,
        "last_verified_generation" => 3
      }
    }
    summary = command("list").send(:circuit_summary, circuit)
    assert_includes summary, "probe=attempt-1@3"
    assert_includes summary, "evidence=provider_outage:"
    assert_includes summary, "ref=outputs/safe.json"
    assert_includes summary, "repair_epoch=1"
    assert_includes summary, "repair_last_verified_generation=3"

    @attempts = AttemptStore.new(decision_index: DecisionIndex.new([ decision_entry ]))
    entry = Marshal.load(Marshal.dump(invoke("list").fetch("decisions").fetch(0)))
    candidate = entry.dig("decision", "candidates", 0)
    candidate["capacity"] = nil
    candidate["eligible"] = false
    candidate["exclusions"] = [
      { "reason" => "manual_block", "scope" => model_scope("model-a").to_h }
    ]
    stdout, = capture_io { command("list").send(:render_decision, entry) }
    assert_includes stdout, "capacity=n/a"
    assert_includes stdout, "manual_block@account-a/model-a"
  end

  def test_trusted_actor_uses_named_and_uid_only_fallbacks
    subject = command("list")
    assert_match(/\Auid:\d+:/, subject.send(:trusted_actor))

    with_replaced_singleton_method(Etc, :getpwuid, ->(*) { raise ArgumentError }) do
      assert_match(/\Auid:\d+\z/, subject.send(:trusted_actor))
    end
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
