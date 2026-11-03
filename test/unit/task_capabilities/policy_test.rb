require "test_helper"
require "hive/task_capabilities/policy"

class TaskCapabilitiesPolicyTest < Minitest::Test
  def catalog
    Hive::TaskCapabilities::Catalog.new(workflow: Hive::Workflows::Coding::DESCRIPTOR)
  end

  def test_switch_is_dormant_and_signal_provenance_is_explicit
    assert_equal false, Hive::Config::DEFAULTS.dig("task_capabilities", "enabled")
    policy = Hive::TaskCapabilities::Policy.new(
      { "required" => [ "qa" ], "auto_select" => [ { "capability" => "ui", "signals" => [
        { "type" => "task_text", "value" => "screen" }, { "type" => "changed_path", "value" => "web/**" }
      ] } ] }, catalog: catalog
    )
    assert policy.required?("qa")
    refute policy.required?("ui")
    assert_equal [ { "capability" => "ui", "signals" => [ { "type" => "changed_path", "value" => "web/**", "matched" => "web/app.rb" } ] } ],
                 policy.matches(changed_paths: [ "web/app.rb" ])
    assert_equal "screen", policy.matches(task_text: "New Screen").first.fetch("signals").first.fetch("matched")
  end

  def test_unknown_policy_shapes_and_arbitrary_selection_scripts_are_rejected
    [ { "required" => [ "unknown" ] }, { "auto_select" => [ { "capability" => "security", "signals" => [] } ] },
      { "auto_select" => [ { "capability" => "ui", "signals" => [ { "type" => "script", "value" => "true" } ] } ] },
      { "waive_qa" => true } ].each do |data|
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Policy.new(data, catalog: catalog) }
    end
  end

  def test_exact_approval_admits_only_a_scope_enforcing_profile
    approval = { "capability" => "security", "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "approved-model" },
                 "permissions" => { "tools" => [ "Read", "Bash" ], "commands" => [ "ruby check.rb" ], "domains" => [], "directories" => [ "reports" ] },
                 "targets" => [ "fixtures/local" ], "budget_usd" => 3, "timeout_sec" => 60 }
    value = Hive::TaskCapabilities::Policy.new({}, catalog: catalog, approvals: { "local" => approval })
    assert_equal "claude", value.approvals.fetch("local").dig("actor", "profile")
    assert_equal [ "reports" ], value.approvals.fetch("local").dig("permissions", "directories")
    [ approval.merge("actor" => approval.fetch("actor").merge("profile" => "codex")),
      approval.merge("permissions" => { "preset" => "scoped", "bash" => true }),
      approval.merge("permissions" => { "tools" => [ "Read", "Bash" ], "commands" => [ "ruby check.rb" ], "domains" => [ "external.test" ] }),
      approval.merge("targets" => [ "https://external.test" ]), approval.merge("budget_usd" => 0) ].each do |data|
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Policy.new({}, catalog: catalog, approvals: { "bad" => data }) }
    end
    [ "../escape", "/absolute", "~home" ].each do |directory|
      invalid = approval.merge("permissions" => approval.fetch("permissions").merge("directories" => [ directory ]))
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Policy.new({}, catalog: catalog, approvals: { "bad" => invalid }) }
    end
  end

  def test_signal_types_and_empty_matches_are_deterministic
    rules = %w[task_label repository_path].map do |type|
      { "capability" => "ui", "signals" => [ { "type" => type, "value" => type == "task_label" ? "ui" : "web/**" } ] }
    end
    policy = Hive::TaskCapabilities::Policy.new({ "auto_select" => rules }, catalog: catalog)
    assert_empty policy.matches
    assert_equal 2, policy.matches(task_labels: [ "ui" ], repository_paths: [ "web/app.rb" ]).length
    assert policy.to_h.frozen?
    assert_equal({}, policy.to_h.fetch("approvals"))
    [ { "auto_select" => "wrong" }, { "auto_select" => [ { "capability" => "ui", "signals" => [] } ] } ].each do |data|
      assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Policy.new(data, catalog: catalog) }
    end
    assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Policy.new({}, catalog: catalog, approvals: []) }
    assert_raises(Hive::ConfigError) do
      Hive::TaskCapabilities::Policy.new({}, catalog: catalog, approvals: { "guidance" => { "capability" => "ui" } })
    end
    approval = { "capability" => "security", "actor" => { "profile" => "claude", "provider" => "anthropic", "model" => "model" },
                 "permissions" => { "tools" => [ "Read" ] }, "targets" => [], "budget_usd" => 1, "timeout_sec" => 30 }
    assert_raises(Hive::ConfigError) { Hive::TaskCapabilities::Policy.new({}, catalog: catalog, approvals: { "empty" => approval }) }
  end
end
