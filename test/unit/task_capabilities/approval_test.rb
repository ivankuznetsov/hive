require "test_helper"
require "hive/task_capabilities/approval"

class TaskCapabilitiesApprovalTest < Minitest::Test
  def envelope
    { "capability" => "security", "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved" },
      "permissions" => { "tools" => [ "Read", "Bash" ], "commands" => [ "ruby check.rb" ], "domains" => [] },
      "targets" => [ "fixtures/local" ], "budget_usd" => 3, "timeout_sec" => 60 }
  end

  def test_exact_actor_and_subset_scope_budget_are_required
    approval = Hive::TaskCapabilities::Approval.new(reference: "local", envelope: envelope)
    assert approval.covers?(envelope.merge("budget_usd" => 1, "timeout_sec" => 30))
    refute approval.covers?(envelope.merge("budget_usd" => 4))
    refute approval.covers?(envelope.merge("actor" => envelope.fetch("actor").merge("model" => "other")))
    refute approval.covers?(envelope.merge("targets" => [ "fixtures/other" ]))
    refute approval.covers?(envelope.merge("permissions" => { "tools" => [ "Write" ] }))
  end
end

class TaskCapabilitiesApprovalTest
  def test_approval_references_are_task_bound_redacted_and_never_broadened
    approval = Hive::TaskCapabilities::Approval.new(reference: "local", envelope: envelope)
    blob = approval.blob(task_identity: { "id" => "1", "slug" => "task", "workflow" => "coding" })
    assert_equal "operator-written", blob.fetch("source")
    assert_equal "1", blob.dig("task", "id")
    refute approval.covers?(nil)
    refute approval.covers?(envelope.merge("capability" => "other"))
    refute approval.covers?(envelope.merge("timeout_sec" => nil))
    refute approval.covers?(envelope.merge("targets" => "fixtures/local"))
    refute approval.covers?(envelope.merge("permissions" => []))
    refute approval.covers?(envelope.merge("permissions" => { "tools" => "Read" }))
    refute approval.covers?(envelope.merge("permissions" => { "unknown" => [ "Read" ] }))
    assert approval.envelope.frozen?
    assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Approval.new(reference: "../unsafe", envelope: envelope) }
    assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Approval.new(reference: "local", envelope: envelope.merge("targets" => [ "ghp_abcdefghijklmnopqrstuvwxyz0123456789" ])) }
  end
end

class TaskCapabilitiesApprovalTest
  def test_requested_scope_must_retain_all_approved_denials
    approved = envelope.merge("permissions" => envelope.fetch("permissions").merge("deny" => [ "Write" ]))
    approval = Hive::TaskCapabilities::Approval.new(reference: "local", envelope: approved)
    refute approval.covers?(envelope)
    refute approval.covers?(approved.merge("permissions" => approved.fetch("permissions").merge("deny" => [])))
    assert approval.covers?(approved.merge("permissions" => approved.fetch("permissions").merge("deny" => %w[Write Edit])))
  end

  def test_narrower_valid_commands_use_the_runtime_policy_prefix_contract
    approved = envelope.merge("permissions" => envelope.fetch("permissions").merge("commands" => [ "ruby check.rb *" ]))
    approval = Hive::TaskCapabilities::Approval.new(reference: "local", envelope: approved)
    assert approval.covers?(envelope)
    assert approval.covers?(approved.merge("permissions" => approved.fetch("permissions").merge("commands" => [ "ruby check.rb fixture *" ])))
    refute approval.covers?(approved.merge("permissions" => approved.fetch("permissions").merge("commands" => [ "ruby *" ])))
    refute approval.covers?(approved.merge("permissions" => approved.fetch("permissions").merge("commands" => [ "ruby check.rb && curl external.test" ])))
    refute approval.covers?(approved.merge("permissions" => approved.fetch("permissions").merge("commands" => [ "ruby 'unterminated" ])))
    exact = Hive::TaskCapabilities::Approval.new(reference: "local", envelope: envelope)
    refute exact.covers?(approved)
  end
end
