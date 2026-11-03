require "test_helper"
require "json_schemer"
require "hive/commands/task_capabilities"
require "hive/cli"
require_relative "../../support/task_capabilities_revision_fixture"

class TaskCapabilitiesCommandTest < Minitest::Test
  include HiveTestHelper
  include TaskCapabilitiesRevisionFixture

  def command(task, action, **options)
    result = nil
    out, = capture_io { result = Hive::Commands::TaskCapabilities.new(action, task.slug, resolver: -> { task }, json: true, **options).call }
    assert_equal result, JSON.parse(out)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-capabilities"))))
    assert_empty schema.validate(result).to_a
    result.fetch("data")
  end

  def options_for(service)
    token = service.show.fetch("expected")
    { identity: JSON.generate(token.fetch("expected_identity")), plan_version: token.fetch("expected_version"), sha: token.fetch("expected_sha") }
  end

  def test_visible_cli_command_uses_the_shared_versioned_mutation_service
    assert Hive::CLI.all_commands.key?("task_capabilities")
    with_revision do |service, task, store|
      assert_equal store.current.to_h, command(task, "show").fetch("plan")
      token = options_for(service)
      proposal = command(task, "propose", **token, selections: [ "ui=off" ], verification_plan: "{}")
      assert_equal 1, store.current.version
      assert_equal "accepted", command(task, "accept", **token, proposal: proposal.fetch("proposal_digest")).fetch("status")
      token = options_for(service)
      proposal = command(task, "propose", **token, selections: [ "ui=off" ])
      assert_equal "rejected", command(task, "reject", **token, proposal: proposal.fetch("proposal_digest"), reason: "retain current").fetch("status")
      assert_equal "accepted", command(task, "waive", **token, reason: "creator QA exception", checks: [ "all" ]).fetch("status")
      assert_equal "waived", store.current.data.dig("choices", "qa", "state")
    end
  end

  def test_every_operator_cli_action_rejects_attempt_context_before_writes
    with_revision do |service, task, store|
      token = options_for(service)
      with_attempt_context(attempt_id: "agent", task_generation: 0) do
        %w[accept reject waive risk-accept].each do |action|
          out, = capture_io do
            error = assert_raises(Hive::TaskCapabilities::Admission::Error) do
              Hive::Commands::TaskCapabilities.new(action, task.slug, resolver: -> { task }, json: true, **token).call
            end
            assert_equal "task_capability_operator_required", error.reason
          end
          payload = JSON.parse(out)
          assert_equal "task_capability_operator_required", payload.fetch("error_kind")
          assert JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-capabilities")))).valid?(payload)
        end
      end
      refute File.exist?(File.join(task.folder, "capability-proposals"))
      assert_equal 1, store.current.version
    end
  end

  def test_cli_json_input_errors_are_typed_and_never_mutate
    with_revision do |service, task, store|
      [ [ "unknown", {} ], [ "propose", {} ], [ "propose", options_for(service).merge(identity: "invalid") ],
        [ "propose", options_for(service).merge(verification_plan: "[]") ] ].each do |action, options|
        out, = capture_io do
          assert_raises(Hive::UsageError) { Hive::Commands::TaskCapabilities.new(action, task.slug, resolver: -> { task }, json: true, **options).call }
        end
        assert_equal "usage", JSON.parse(out).fetch("error_kind")
      end
      assert_equal 1, store.current.version
      out, = capture_io { Hive::Commands::TaskCapabilities.new("show", task.slug, resolver: -> { task }).call }
      assert_equal store.current.to_h, JSON.parse(out).fetch("plan")
      assert_raises(Hive::TaskCapabilities::Admission::Error) do
        capture_io { Hive::Commands::TaskCapabilities.new("risk-accept", task.slug, resolver: -> { task }, **options_for(service)).call }
      end
    end
  end
end

class TaskCapabilitiesCommandTest
  def test_thor_dispatches_the_visible_command_to_the_same_inspector
    with_revision do |service, task|
      resolver = Object.new
      resolver.define_singleton_method(:resolve) { task }
      out = nil
      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*, **) { resolver }) do
        out, = capture_io { Hive::CLI.start([ "task-capabilities", "show", task.slug, "--json" ]) }
      end
      assert_equal service.show, JSON.parse(out).fetch("data")
    end
  end
end

class TaskCapabilitiesCommandTest
  def test_task_approval_proposal_exposes_the_exact_pinned_envelope_before_acceptance
    security = { "id" => "security", "kind" => "verification", "stages" => [ "review" ],
      "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" },
      "permissions" => { "tools" => [ "Read" ], "directories" => [ "." ], "domains" => [] },
      "targets" => [ "local-source" ], "budget_usd" => 1, "timeout_sec" => 10,
      "checks" => [ { "id" => "source", "kind" => "source_review", "claim" => "inspect source" } ] }
    settings = { "catalog" => [ security ], configure: ->(cfg, _) { cfg["agents"]["claude"]["bin"] = "ruby" } }
    with_revision(settings: settings, selections: [ "security=on" ]) do |service, task, store, cfg|
      with_replaced_singleton_method(Hive::Config, :load, ->(*) { cfg }) do
        proposed = command(task, "propose", **options_for(service), task_approvals: [ "security=task-owner" ])
        assert_equal "task-owner", proposed.fetch("approval_previews").first.fetch("reference")
        assert_equal security.fetch("permissions"), proposed.fetch("approval_previews").first.dig("envelope", "permissions")
        assert_equal 1, store.current.version
        assert_equal "accepted", command(task, "accept", **options_for(service), proposal: proposed.fetch("proposal_digest")).fetch("status")
      end
    end
  end
end
