require "test_helper"
require_relative "../../support/task_capabilities_revision_fixture"
require_relative "../../support/task_capabilities_fixture"
require "hive/task_capabilities/projection"
require "hive/task_workspace"

class TaskCapabilitiesProjectionTest < Minitest::Test
  include HiveTestHelper
  include TaskCapabilitiesRevisionFixture
  include TaskCapabilitiesFixture

  def test_persisted_choices_and_proposals_are_bounded_and_reads_do_not_repin
    with_revision do |service, task, store, cfg|
      proposal = service.propose(selections: [ "ui=off" ], reason: "Keep the current design", **expectation(service))
      before = store.current.digest
      value = Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      assert_equal before, value.fetch("execution_plan_digest")
      assert_equal "on", value.dig("choices", "qa", "effective")
      assert_equal proposal.fetch("proposal_digest"), value.fetch("proposals").first.fetch("proposal_digest")
      assert_equal "Keep the current design", value.fetch("proposals").first.fetch("reason")
      assert_equal "Pending check", value.dig("gate", "checks", 0, "label")
      refute_includes JSON.generate(value), "runner"
      refute_includes JSON.generate(value), "instruction_content"
      cfg["task_capabilities"]["policy"] = { "required" => [ "ui" ] }
      assert_equal value, Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      assert_equal before, store.current.digest
      assert_empty Hive::TaskWorkspace.safe_value!(value).fetch("waivers")
    end
  end

  def test_legacy_task_has_no_fabricated_projection
    with_tmp_dir do |dir|
      task = Struct.new(:folder).new(dir)
      assert_nil Hive::TaskCapabilities::Projection.new(task: task, cfg: {}).call
    end
  end

  def test_unavailable_approved_security_route_has_shared_recovery_without_waiving_unrun_checks
    security = actor_definition(id: "security")
    security.fetch("actor")["launch_binding"] = "default"
    security["permissions"] = { "tools" => [ "Read" ], "commands" => [], "domains" => [] }
    approval = security.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => "security")
    configure = ->(cfg, _dir) { cfg["task_capabilities"]["approvals"] = { "approved" => approval } }
    with_verification(catalog: [ security ], selections: [ "security=on" ], approval_references: [ "security=approved" ], configure: configure) do |_verification, _plan, _store, _code, cfg, task|
      cfg["agents"]["claude"]["bin"] = "/missing/approved-route"
      value = Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      assert_equal "blocked", value.dig("gate", "capabilities").find { |item| item["id"] == "security" }.fetch("state")
      blocker = value.fetch("blockers").find { |item| item["capability_id"] == "security" }
      assert_includes blocker.fetch("message"), "restore the exact approved route or archive/cancel"
      assert_nil blocker.fetch("command")
      assert_equal "pending", value.dig("gate", "checks").find { |check| check["capability_id"] == "security" }.fetch("state")
      assert_empty value.fetch("waivers")
    end
  end

  def test_failed_execution_has_evidence_references_without_raw_output_and_terminal_annotation
    with_verification(command: "ruby -e 'puts :PRIVATE_OUTPUT; exit 1'") do |verification, _plan, _store, _code, cfg, task|
      verification.run!
      value = Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      check = value.dig("gate", "checks", 0)
      assert_equal "Failed", check.fetch("label")
      assert_match(/^[0-9a-f]{64}$/, check.fetch("result_digest"))
      assert_equal "command", check.fetch("evidence").first.fetch("kind")
      refute_includes JSON.generate(value), "PRIVATE_OUTPUT"
      assert_includes value.fetch("mutation_unavailable"), "owning attempt"
      before = value.fetch("refresh_digest")
      Hive::TaskCapabilities::ResultStore.new(task.folder).record_terminal!(disposition: "cancelled", reference: "receipt-ref")
      closed = Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      refute_equal before, closed.fetch("refresh_digest")
      assert_equal "failed", closed.dig("gate", "checks", 0, "state")
      assert_equal "Cancelled — gate not evaluated", closed.dig("gate", "terminal_dispositions", 0, "label")
      assert_empty Hive::TaskWorkspace.safe_value!(closed).fetch("proposals")
    end
  end

  def test_waiver_and_stale_proposal_are_inspected_from_accepted_history
    with_revision do |service, task, _store, cfg|
      proposal = service.propose(selections: [ "ui=off" ], **expectation(service))
      service.waive(reason: "Documentation inspected by operator", checks: [ "all" ], **expectation(service))
      value = Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      assert_equal "Waived by operator", value.dig("gate", "label")
      assert_equal "qa", value.fetch("waivers").first.fetch("capability_id")
      assert_equal "Documentation inspected by operator", value.fetch("waivers").first.fetch("reason")
      stale = value.fetch("proposals").find { |entry| entry["proposal_digest"] == proposal.fetch("proposal_digest") }
      assert_includes stale.fetch("disabled_reason"), "changed"
    end
  end

  def test_missing_configuration_and_exact_task_approval_are_actionable
    with_revision(command: nil) do |_service, task, _store, cfg|
      value = Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      assert value.fetch("blockers").any? { |item| item["command"].include?("--verification-plan") }
    end
    settings = { "catalog" => [ { "id" => "security", "kind" => "verification", "stages" => [ "review" ],
      "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" },
      "permissions" => { "tools" => [ "Read" ], "directories" => [ "." ], "domains" => [] },
      "targets" => [ "local-source" ], "budget_usd" => 1, "timeout_sec" => 10,
      "checks" => [ { "id" => "source", "kind" => "source_review", "claim" => "inspect source" } ] } ],
      configure: ->(cfg, _dir) { cfg["agents"]["claude"]["bin"] = "ruby" } }
    with_revision(settings: settings) do |service, task, _store, cfg|
      with_replaced_singleton_method(Hive::Config, :load, ->(*) { cfg }) do
        service.propose(selections: [ "security=on" ], task_approvals: [ "security=task-owner" ], reason: "Approve exact scope", **expectation(service))
      end
      value = Hive::TaskCapabilities::Projection.new(task: task, cfg: cfg).call
      approval = value.fetch("proposals").first.fetch("approval_previews").first
      assert_equal "task-owner", approval.fetch("reference")
      assert_equal "security", approval.dig("envelope", "capability_id")
      assert_empty Hive::TaskWorkspace.safe_value!(value).fetch("waivers")
    end
  end
end
