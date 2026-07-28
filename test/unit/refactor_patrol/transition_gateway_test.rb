require "test_helper"
require "hive/refactor_patrol/transition_gateway"

class RefactorPatrolTransitionGatewayTest < Minitest::Test
  Capture = Struct.new(:owner, keyword_init: true)

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

  private

  def gateway
    Hive::RefactorPatrol::TransitionGateway.new(
      project_root: Dir.pwd,
      hive_state_path: File.join(Dir.pwd, ".hive-state"),
      capture: Capture.new(owner: "legacy"),
      job_store: Object.new,
      evidence_store: Object.new,
      config_loader: ->(_root) { {} }
    )
  end
end
