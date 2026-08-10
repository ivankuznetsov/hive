require_relative "../../test_helper"
require "hive/provider_health/evidence"

class ProviderHealthEvidenceTest < Minitest::Test
  def test_every_closed_provider_and_model_class_accepts_only_its_scope
    Hive::ProviderHealth::PROVIDER_FAILURE_CLASSES.each do |klass|
      evidence = build_evidence(scope: provider_scope, failure_class: klass)
      assert_equal provider_scope, evidence.scope
      assert_match(/\A[0-9a-f]{64}\z/, evidence.fingerprint)
      assert_raises(Hive::ProviderHealth::InvalidEvidence) do
        build_evidence(scope: model_scope, failure_class: klass)
      end
    end

    Hive::ProviderHealth::MODEL_FAILURE_CLASSES.each do |klass|
      evidence = build_evidence(scope: model_scope, failure_class: klass)
      assert_equal model_scope, evidence.scope
      assert_raises(Hive::ProviderHealth::InvalidEvidence) do
        build_evidence(scope: provider_scope, failure_class: klass)
      end
    end
  end

  def test_untrusted_ambiguous_and_route_mismatched_evidence_is_rejected
    assert_raises(Hive::ProviderHealth::InvalidEvidence) do
      build_evidence(provenance: "stdout")
    end
    assert_raises(Hive::ProviderHealth::InvalidEvidence) do
      build_evidence(failure_class: "timeout")
    end
    assert_raises(Hive::ProviderHealth::InvalidEvidence) do
      build_evidence(
        scope: Hive::ProviderHealth::Scope.model(
          account_id: "codex-primary", model_id: "gpt-other"
        ),
        failure_class: "model_capacity"
      )
    end
  end

  def test_fingerprint_uses_only_canonical_safe_fields
    first = build_evidence
    second = build_evidence(source_reference: reference(path: "outputs/other.json"))

    assert_equal first.fingerprint, second.fingerprint
    refute_includes JSON.generate(first.to_h), "raw provider message"
    assert_raises(ArgumentError) do
      Hive::ProviderHealth::Evidence.new(
        **evidence_arguments,
        raw_message: "Bearer secret-canary"
      )
    end
  end

  def test_output_reference_shape_cannot_carry_raw_fields
    unsafe = reference.merge("message" => "secret-canary")

    error = assert_raises(Hive::ProviderHealth::InvalidEvidence) do
      build_evidence(source_reference: unsafe)
    end
    refute_includes error.message, "secret-canary"
  end

  def test_idempotency_key_binds_terminal_receipt_without_persisting_it
    evidence = build_evidence

    first = evidence.idempotency_key(receipt_identity: { "version" => 2, "id" => "terminal-1" })
    same = evidence.idempotency_key(receipt_identity: { "id" => "terminal-1", "version" => 2 })
    changed = evidence.idempotency_key(receipt_identity: { "id" => "terminal-2", "version" => 2 })

    assert_equal first, same
    refute_equal first, changed
  end

  private

  def build_evidence(**overrides)
    Hive::ProviderHealth::Evidence.new(**evidence_arguments.merge(overrides))
  end

  def evidence_arguments
    {
      scope: provider_scope,
      failure_class: "provider_outage",
      provenance: "codex_jsonl_transport",
      route: route,
      reset_hint_seconds: 300,
      source_reference: reference,
      attempt_id: "attempt-1"
    }
  end

  def route
    @route ||= Hive::ProviderHealth::RouteIdentity.new(
      route_id: "codex-primary/gpt-5.6-sol",
      account_id: "codex-primary",
      adapter: "codex",
      launch_binding_id: "default",
      model_id: "gpt-5.6-sol"
    )
  end

  def provider_scope
    @provider_scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "codex-primary")
  end

  def model_scope
    @model_scope ||= Hive::ProviderHealth::Scope.model(
      account_id: "codex-primary", model_id: "gpt-5.6-sol"
    )
  end

  def reference(path: "outputs/safe.json")
    { "path" => path, "size" => 12, "sha256" => "a" * 64 }
  end
end
