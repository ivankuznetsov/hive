require "test_helper"
require "hive/refactor_patrol/transition_gateway"

class RefactorPatrolTransitionGatewayTest < Minitest::Test
  Capture = Struct.new(:owner, keyword_init: true)
  Result = Data.define(:outcome)

  class Gateway
    attr_reader :reconciled

    def perform!(**)
      Result.new(yield(:intent))
    end

    def reconcile_intent!(_intent)
      @reconciled = yield
      Result.new(@reconciled.fetch("outcome"))
    end
  end

  class RecordingCapabilityContext
    attr_reader :paths

    def initialize(allowed:)
      @allowed = allowed
      @paths = []
    end

    def require_filesystem_write!(path)
      @paths << path
      return true if @allowed

      raise Hive::Modules::CapabilityDenied, "filesystem write denied"
    end
  end

  def test_default_gateway_construction_leaves_optional_lifecycle_factory_unset
    subject = gateway

    assert_nil subject.instance_variable_get(:@lifecycle_store_factory)
    assert_equal "legacy", subject.capture.owner
    assert_predicate subject.instance_variable_get(:@clock).call, :utc?
  end

  def test_filesystem_capability_is_required_when_a_context_is_present
    subject = gateway
    allowed = RecordingCapabilityContext.new(allowed: true)
    denied = RecordingCapabilityContext.new(allowed: false)

    assert subject.send(:capability_allowed?, capability_context: nil)
    assert subject.send(:capability_allowed?, capability_context: allowed)
    assert_equal [ ".hive-state/refactor_patrol/**" ], allowed.paths
    refute subject.send(:capability_allowed?, capability_context: denied)
    assert_equal [ ".hive-state/refactor_patrol/**" ], denied.paths
  end

  def test_transition_digest_rejects_non_json_values
    error = assert_raises(Hive::ConfigError) do
      gateway.send(:transition_digest, { "score" => Float::NAN })
    end

    assert_equal(
      "architecture patrol transition result is not JSON serializable",
      error.message
    )
  end

  def test_public_transition_paths_accept_zero_arity_and_replay_rejections
    effect_gateway = Gateway.new
    subject = gateway(gateway_factory: ->(**) { effect_gateway })

    value = subject.perform!(
      sink: "job",
      target: "job-1:checkpoint",
      idempotency_key: "checkpoint",
      scope: { "job_id" => "job-1" },
      claim_validator: ->(**) { true },
      reconcile: ->(_intent) { nil },
      replay: ->(_result) { flunk("applied transition must not replay") }
    ) { { "job_id" => "job-1" } }
    assert_equal({ "job_id" => "job-1" }, value)

    subject.reconcile_recorded!(
      Object.new,
      "outcome" => "rejected",
      "error_code" => "stale_claim"
    )
    assert_equal(
      {
        "status" => "matched",
        "outcome" => {
          "transition_status" => "rejected",
          "error_code" => "stale_claim"
        }
      },
      effect_gateway.reconciled
    )
  end

  private

  def gateway(**options)
    Hive::RefactorPatrol::TransitionGateway.new(
      project_root: Dir.pwd,
      hive_state_path: File.join(Dir.pwd, ".hive-state"),
      capture: Capture.new(owner: "legacy"),
      job_store: Object.new,
      evidence_store: Object.new,
      config_loader: ->(_root) { {} },
      **options
    )
  end
end
