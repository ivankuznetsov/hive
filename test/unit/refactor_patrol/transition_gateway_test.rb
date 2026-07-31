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

  def test_manifest_capture_uses_the_canonical_project_repository_identity
    capture =
      Hive::RefactorPatrol::TransitionGateway.capture_for_manifest(
        manifest: manifest,
        project: project,
        owner: "legacy",
        owner_epoch: 1,
        recorded_at: Time.utc(2026, 7, 31, 12)
      )

    assert_equal(
      "github.com/owner/demo",
      capture.project.fetch("repository")
    )
    assert_equal(
      "owner/demo:7:#{"b" * 40}",
      capture.trigger.fetch("id")
    )
  end

  def test_manifest_capture_rejects_a_mismatched_project_repository_identity
    error = assert_raises(Hive::ConfigError) do
      Hive::RefactorPatrol::TransitionGateway.capture_for_manifest(
        manifest: manifest,
        project: project.merge(
          "repository" => "github.com/other/demo"
        ),
        owner: "legacy",
        owner_epoch: 1
      )
    end

    assert_equal(
      "architecture patrol project binding does not match " \
      "manifest source",
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

  def project
    {
      "project_id" => "project-1",
      "name" => "demo",
      "repository" => "github.com/owner/demo"
    }
  end

  def manifest
    Hive::RefactorPatrol::PrManifest.build(
      source: {
        "url" => "https://github.com/owner/demo/pull/7",
        "number" => 7,
        "repository" => "owner/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => Time.utc(2026, 7, 31, 12).iso8601
      },
      files: [
        {
          "path" => "lib/demo.rb",
          "status" => "modified"
        }
      ]
    )
  end

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
