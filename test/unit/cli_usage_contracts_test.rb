# frozen_string_literal: true

require "test_helper"
require "json"
require "hive/cli_usage_contracts"
require "open3"
require "rbconfig"

# Each command boundary (lib/hive/commands/<command>.rb) declares its own
# pre-dispatch JSON usage contract via Hive::CliUsageContracts.declare; the
# module itself is a generic resolution protocol. These unit tests pin the
# per-command contract resolution and payload construction directly, so each
# command boundary's pre-dispatch JSON envelope stays authoritative without
# paying for a launcher subprocess; the launcher-level behavior itself remains
# covered end-to-end by test/integration/cli_usage_error_json_test.rb.
class CliUsageContractsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_single_shape_commands_resolve_from_their_boundary_declarations
    [
      [ %w[run], { schema: "hive-run", error_kind: "invalid_task_path" } ],
      [ %w[digest], { schema: "hive-digest", error_kind: "usage" } ],
      [ %w[approve], { schema: "hive-approve", error_kind: "invalid_task_path" } ],
      [ %w[brainstorm], { schema: "hive-stage-action", error_kind: "invalid_task_path", extras: { "verb" => "brainstorm" } } ],
      [ %w[metrics], { schema: "hive-metrics-rollback-rate", error_kind: "error", omit_error_class: true } ],
      [ %w[connect], { error_kind: "usage", extras: { "service" => "screenote" } } ]
    ].each do |argv, expected|
      assert_equal expected, Hive::CliUsageContracts.contract(argv)
    end
  end

  def test_leading_options_do_not_impersonate_a_command_token
    assert_nil Hive::CliUsageContracts.contract(%w[--json])
    assert_equal(
      { schema: "hive-run", error_kind: "invalid_task_path" },
      Hive::CliUsageContracts.contract(%w[--json run])
    )
  end

  def test_act_variant_preserves_action_identity_from_positionals
    contract = Hive::CliUsageContracts.contract(%w[act workflow.advance demo:task --observation abc])
    assert_equal "hive-act", contract.fetch(:schema)
    assert_equal "usage", contract.fetch(:error_kind)
    assert_equal({ "action_id" => "workflow.advance", "target" => "demo:task" }, contract.fetch(:extras))

    bare = Hive::CliUsageContracts.contract(%w[act])
    assert_equal({ "action_id" => "", "target" => "" }, bare.fetch(:extras))
  end

  def test_status_variant_selects_the_mode_schema
    assert_equal(
      { schema: "hive-status-diagnose", error_kind: "error" },
      Hive::CliUsageContracts.contract(%w[status --diagnose task])
    )
    assert_equal(
      { schema: "hive-operational-status", error_kind: "error" },
      Hive::CliUsageContracts.contract(%w[status --operational])
    )
    assert_equal(
      { schema: "hive-status", error_kind: "error" },
      Hive::CliUsageContracts.contract(%w[status --internal-task-graph])
    )
    # No mode flags: the boundary's own running-status contract.
    assert_equal(
      { schema: "hive-running-status", error_kind: "error" },
      Hive::CliUsageContracts.contract(%w[status extra])
    )
  end

  def test_web_variant_resolves_install_and_status_only
    %w[hive-web-status hive-web-install].zip([ %w[web status], %w[web --bind 0.0.0.0 install] ]).each do |schema, argv|
      contract = Hive::CliUsageContracts.contract(argv)
      assert_equal schema, contract.fetch(:schema)
      assert_equal "invalid_task_path", contract.fetch(:error_kind)
      assert_respond_to contract.fetch(:payload), :call,
                       "the web boundary owns its native-context payload construction"
    end
    assert_nil Hive::CliUsageContracts.contract(%w[web other])
  end

  def test_pairing_variant_selects_approve_or_list
    assert_equal(
      { schema: "hive-pairing-approve", error_kind: "invalid_arguments" },
      Hive::CliUsageContracts.contract(%w[pairing approve CODE])
    )
    assert_equal(
      { schema: "hive-pairing-list", error_kind: "invalid_arguments" },
      Hive::CliUsageContracts.contract(%w[pairing unknown approve])
    )
  end

  def test_bot_variant_is_the_whole_surface_contract
    assert_equal(
      { schema: "hive-bot-status", error_kind: "extra_arguments" },
      Hive::CliUsageContracts.contract(%w[bot status extra])
    )
  end

  # Contract resolution runs inside bin/hive's `rescue Thor::Error` handler,
  # so a boundary file that fails to cold-load must degrade to "no contract"
  # (human usage error at exit 64) instead of letting the LoadError escape
  # the launcher rescue. LoadError is a ScriptError, not a StandardError, so
  # this pins the exact rescue list.
  def test_contract_resolution_degrades_to_no_contract_when_the_boundary_fails_to_load
    out = cold_ruby(<<~RUBY)
      require "hive/cli_usage_contracts"
      abort "bot already declared" if Hive::CliUsageContracts.instance_variable_get(:@contracts).key?("bot")
      abort "bot already loaded" if $LOADED_FEATURES.any? { |path| path.end_with?("/commands/bot.rb") }
      attempts = 0
      Hive::CliUsageContracts.define_singleton_method(:load_boundary_declaration!) do |_command|
        attempts += 1
        raise LoadError, "forced cold-load failure"
      end
      selected = Hive::CliUsageContracts.contract(%w[bot status extra --json])
      error = Hive::CliUsageContracts.usage_error(selected, "boom")
      puts JSON.generate([selected, error.class.name, error.exit_code, attempts])
    RUBY
    assert_equal [ nil, "Hive::UsageError", 64, 1 ], JSON.parse(out)
  end

  def test_cold_command_load_orders_keep_distinct_contracts
    [ %w[bot run], %w[run bot] ].each do |order|
      out = cold_ruby(<<~RUBY)
        require "hive/cli_usage_contracts"
        abort "declarations are not cold" unless Hive::CliUsageContracts.instance_variable_get(:@contracts).empty?
        contracts = #{order.inspect}.to_h { |command| [command, Hive::CliUsageContracts.contract([command])] }
        puts JSON.generate(contracts)
      RUBY
      contracts = JSON.parse(out)
      assert_equal "hive-bot-status", contracts.fetch("bot").fetch("schema")
      assert_equal "extra_arguments", contracts.fetch("bot").fetch("error_kind")
      assert_equal "hive-run", contracts.fetch("run").fetch("schema")
      assert_equal "invalid_task_path", contracts.fetch("run").fetch("error_kind")
    end
  end

  def test_contract_resolution_degrades_to_no_contract_when_a_boundary_resolver_raises
    Hive::CliUsageContracts.declare("unit-crashy-resolver") do
      raise ArgumentError, "boundary resolver bug"
    end
    assert_nil Hive::CliUsageContracts.contract(%w[unit-crashy-resolver --json])
    assert_instance_of Hive::UsageError, Hive::CliUsageContracts.usage_error(Hive::CliUsageContracts.contract(%w[unit-crashy-resolver --json]), "boom")
  ensure
    contracts = Hive::CliUsageContracts.instance_variable_get(:@contracts)
    contracts.delete("unit-crashy-resolver") if contracts
  end

  def test_module_variant_maps_subcommands_to_schemas
    assert_equal(
      { schema: "hive-module-list", error_kind: "usage" },
      Hive::CliUsageContracts.contract(%w[module list])
    )
    assert_equal(
      { schema: "hive-module-status", error_kind: "usage" },
      Hive::CliUsageContracts.contract(%w[module --receipt r status])
    )
    assert_equal(
      { schema: "hive-module-lifecycle", error_kind: "usage" },
      Hive::CliUsageContracts.contract(%w[module unknown])
    )
  end

  def test_workflow_variant_validates_arity_error_keeps_the_validate_envelope
    contract = Hive::CliUsageContracts.contract(%w[workflow validate editorial extra])
    assert_equal "hive-workflow-validate", contract.fetch(:schema)
    # Positionals include the subcommand token, so fetch(1) selects the
    # workflow id ("editorial"), not the extra arity offender.
    assert_equal({ "valid" => false, "id" => "editorial" }, contract.fetch(:extras))
    assert_respond_to contract.fetch(:payload), :call,
                     "the workflow boundary owns the validate diagnostics arm"

    assert_equal(
      { schema: "hive-workflow-install", error_kind: "usage", extras: {} },
      Hive::CliUsageContracts.contract(%w[workflow install])
    )
  end

  def test_refactor_patrol_variant_uses_jobs_envelope_when_job_flags_present
    contract = Hive::CliUsageContracts.contract(%w[refactor-patrol --show])
    assert_equal "hive-refactor-patrol-jobs", contract.fetch(:schema)
    assert_equal "usage", contract.fetch(:error_kind)
    assert_equal({ "action" => "show" }, contract.fetch(:extras))

    fallback = Hive::CliUsageContracts.contract(%w[refactor-patrol])
    assert_equal "error", fallback.fetch(:error_kind)
    assert_nil fallback[:schema]
    assert_respond_to fallback.fetch(:payload), :call,
                      "the refactor-patrol boundary owns the reporter envelope"
  end

  def test_refactor_patrol_payload_rides_the_reporter_envelope
    contract = Hive::CliUsageContracts.contract(%w[refactor-patrol])
    payload = Hive::CliUsageContracts.error_payload(contract, Hive::UsageError.new("boom"))

    assert_equal "hive-refactor-patrol", payload.fetch("schema")
    assert_equal Hive::RefactorPatrol::Reporter::V4_SCHEMA_VERSION, payload.fetch("schema_version")
    assert_equal "error", payload.fetch("error_kind")

    jobs_payload = Hive::CliUsageContracts.error_payload(
      Hive::CliUsageContracts.contract(%w[refactor-patrol --list]), Hive::UsageError.new("boom")
    )
    assert_equal "usage", jobs_payload.fetch("error_kind")
  end

  def test_refactor_patrol_jobs_payload_rides_the_generic_jobs_envelope
    payload = Hive::CliUsageContracts.error_payload(
      Hive::CliUsageContracts.contract(%w[refactor-patrol --show job-7]), Hive::UsageError.new("boom")
    )

    assert_equal "hive-refactor-patrol-jobs", payload.fetch("schema"),
                 "jobs-variant usage errors must ride the generic jobs envelope, not the v4 reporter envelope"
    assert_equal 2, payload.fetch("schema_version")
    assert_equal "usage", payload.fetch("error_kind")
    assert_equal "show", payload.fetch("action")

    selectorless = Hive::CliUsageContracts.error_payload(
      Hive::CliUsageContracts.contract(%w[refactor-patrol --limit 1]), Hive::UsageError.new("boom")
    )
    assert_equal "hive-refactor-patrol-jobs", selectorless.fetch("schema")
    assert_nil selectorless.fetch("action")
  end

  def test_web_payload_rides_the_native_web_context
    payload = Hive::CliUsageContracts.error_payload(
      Hive::CliUsageContracts.contract(%w[web status]), Hive::UsageError.new("boom")
    )
    assert_equal "hive-web-status", payload.fetch("schema")
    assert_equal "managed_service", payload.fetch("mode")
    assert payload.key?("service_installed")
  end

  def test_setup_payload_rides_the_versioned_native_bootstrap_context
    payload = Hive::CliUsageContracts.error_payload(
      Hive::CliUsageContracts.contract(%w[setup --no-bootstrap]),
      Hive::UsageError.new("boom"),
      argv: %w[setup --no-bootstrap]
    )
    assert_equal "hive-setup", payload.fetch("schema")
    assert_equal "diagnose_only", payload.fetch("mode")
    assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-setup"), payload.fetch("schema_version")
  end

  def test_workflow_validate_payload_keeps_the_diagnostics_arm
    payload = Hive::CliUsageContracts.error_payload(
      Hive::CliUsageContracts.contract(%w[workflow validate editorial extra]), Hive::UsageError.new("boom")
    )
    assert_equal "hive-workflow-validate", payload.fetch("schema")
    assert_equal false, payload.fetch("valid")
    assert_equal "editorial", payload.fetch("id")
    assert_equal [ { "message" => "boom" } ], payload.fetch("diagnostics")
  end

  def test_error_payload_omits_error_class_for_the_metrics_contract
    contract = Hive::CliUsageContracts.contract(%w[metrics])
    payload = Hive::CliUsageContracts.error_payload(contract, Hive::UsageError.new("boom"))

    assert_equal "hive-metrics-rollback-rate", payload.fetch("schema")
    refute payload.key?("error_class"), "the metrics v1 error schema has no error_class field"
    assert_equal "error", payload.fetch("error_kind")
  end

  def test_error_payload_builds_unversioned_envelope_for_screenote
    contract = Hive::CliUsageContracts.contract(%w[connect])
    payload = Hive::CliUsageContracts.error_payload(contract, Hive::UsageError.new("missing SERVICE"))

    assert_equal false, payload.fetch("ok")
    assert_equal "usage", payload.fetch("error_kind")
    assert_equal "screenote", payload.fetch("service")
    refute payload.key?("schema"), "Screenote connect/disconnect JSON failures are unversioned"
  end

  def test_usage_error_selects_the_invalid_task_path_class_for_slug_commands
    error = Hive::CliUsageContracts.usage_error(Hive::CliUsageContracts.contract(%w[run]), "bad path")
    assert_instance_of Hive::InvalidTaskPath, error

    error = Hive::CliUsageContracts.usage_error(Hive::CliUsageContracts.contract(%w[run --json]), "bad path")
    assert_instance_of Hive::InvalidTaskPath, error
  end

  def test_module_is_a_protocol_and_owns_no_per_command_contracts
    refute Hive::CliUsageContracts.const_defined?(:REGISTRY, false),
           "per-command contract data must live in each command boundary file"
    refute Hive::CliUsageContracts.const_defined?(:VARIANT_RESOLVERS, false)
  end

  def test_contracts_are_declared_in_their_own_command_boundary_files
    {
      "run" => "lib/hive/commands/run.rb",
      "status" => "lib/hive/commands/status.rb",
      "act" => "lib/hive/commands/act.rb",
      "runtime" => "lib/hive/commands/runtime.rb",
      "workflow" => "lib/hive/commands/workflow.rb",
      "module" => "lib/hive/commands/module.rb",
      "web" => "lib/hive/commands/web.rb",
      "bot" => "lib/hive/commands/bot.rb",
      "pairing" => "lib/hive/commands/pairing.rb",
      "refactor-patrol" => "lib/hive/commands/refactor_patrol.rb",
      "accept-finding" => "lib/hive/commands/finding_toggle.rb",
      "setup" => "lib/hive/commands/setup.rb",
      "metrics" => "lib/hive/commands/metrics.rb",
      "connect" => "lib/hive/commands/connect.rb"
    }.each do |command, boundary|
      source = File.read(File.join(ROOT, boundary))
      # Whitespace-tolerant so declaration formatting (line wrapping) does not
      # matter; only the boundary declaring its own contract does.
      assert_match(/Hive::CliUsageContracts\.declare\(\s*"#{Regexp.escape(command)}"/,
                   source,
                   "#{command}'s usage contract must be declared by its own boundary file #{boundary}")
    end

    # The stage-action boundary declares every workflow stage verb together
    # (plus the `pr` alias of open-pr) via one verb list.
    stage_action = File.read(File.join(ROOT, "lib/hive/commands/stage_action.rb"))
    assert_includes(
      stage_action,
      "%w[brainstorm plan develop open-pr review artifacts finalize archive]",
      "the stage verbs' usage contracts must be declared by the stage-action boundary"
    )
    assert_match(/Hive::CliUsageContracts\.declare\(\s*"pr"/, stage_action)
  end

  def test_direct_module_load_does_not_depend_on_launcher_bootstrap
    code = <<~RUBY
      require "hive/cli_usage_contracts"
      error = Hive::CliUsageContracts.usage_error(Hive::CliUsageContracts.contract(%w[run]), "bad path")
      puts error.class
    RUBY
    out = cold_ruby(code)
    assert_equal "Hive::InvalidTaskPath", out.strip
  end

  def test_resolution_diagnostics_are_local_and_process_control_exceptions_escape
    diagnostics = []
    callback = ->(klass) { diagnostics << klass }
    %w[unit-syntax unit-interrupt unit-exit].zip([ SyntaxError, Interrupt, SystemExit ]).each do |command, klass|
      Hive::CliUsageContracts.declare(command) { raise klass, "private message" }
    end
    assert_nil Hive::CliUsageContracts.contract(%w[unit-syntax], on_failure: callback)
    assert_equal [ SyntaxError ], diagnostics
    assert_raises(Interrupt) { Hive::CliUsageContracts.contract(%w[unit-interrupt], on_failure: callback) }
    assert_raises(SystemExit) { Hive::CliUsageContracts.contract(%w[unit-exit], on_failure: callback) }
    assert_nil Hive::CliUsageContracts.contract(%w[unknown-command], on_failure: callback)
    assert_equal [ SyntaxError ], diagnostics
  ensure
    contracts = Hive::CliUsageContracts.instance_variable_get(:@contracts)
    %w[unit-syntax unit-interrupt unit-exit].each { |command| contracts.delete(command) }
  end

  def test_declaration_requires_a_contract_or_resolver
    assert_raises(ArgumentError) { Hive::CliUsageContracts.declare("missing") }
  end

  def test_invalid_command_and_unsupported_boundaries_have_no_contract
    [ [], %w[--json], [ "bad\xFF" ], %w[../run], %w[not-a-command], %w[version] ].each do |argv|
      assert_nil Hive::CliUsageContracts.contract(argv), argv.inspect
    end
  end

  def test_region_helpers_keep_values_and_delimited_positionals_separate
    policy = Hive::CliUsageContracts
    assert_equal [ "--operational" ], policy.option_region(%w[status --operational -- --diagnose], 0)
    assert_nil policy.subcommand(%w[web --bind host --json], 0, value_options: %w[--bind])
    assert_nil policy.subcommand([ "web", "bad\xFF" ], 0)
    assert_equal "--status", policy.subcommand(%w[web -- --status], 0)
    assert_equal [ "x", "--json" ], policy.positionals(
      [ "act", "--observation", "value", "--observation=other", "--json", "bad\xFF", "x", "--", "--json" ],
      0, value_options: %w[--observation]
    )
  end

  def test_legacy_schema_versions_and_non_hive_error_exit_fallback
    error = RuntimeError.new("boom")
    payload = Hive::CliUsageContracts.generic_payload(
      { schema: "legacy", schema_version: false, error_kind: "usage" }, error
    )
    refute payload.key?("schema_version")
    assert_equal 1, payload.fetch("exit_code")
    assert_equal "RuntimeError", payload.fetch("error_class")
    payload = Hive::CliUsageContracts.generic_payload({ schema: "legacy", error_kind: "usage" }, error)
    assert_equal 1, payload.fetch("schema_version")
  end

  def test_payload_builder_errors_are_not_resolution_failures
    contract = { payload: ->(*) { raise ArgumentError, "builder failed" } }
    error = assert_raises(ArgumentError) { Hive::CliUsageContracts.error_payload(contract, Hive::UsageError.new("boom")) }
    assert_equal "builder failed", error.message
  end

  def test_setup_modes_and_refactor_job_boolean_variants
    %w[--no-service --no-bootstrap].zip(%w[service_opt_out diagnose_only]).each do |flag, mode|
      argv = [ "setup", flag ]
      contract = Hive::CliUsageContracts.contract(argv)
      payload = Hive::CliUsageContracts.error_payload(contract, Hive::UsageError.new("boom"), argv: argv)
      assert_equal mode, payload.fetch("mode")
    end
    {
      %w[--archive=x --list] => "show", %w[--show=x] => "show",
      %w[--list=true] => "list", %w[--list --no-list] => nil,
      %w[--full] => nil, %w[--full=true] => nil,
      %w[--full --no-full --list] => "list"
    }.each do |flags, action|
      contract = Hive::CliUsageContracts.contract([ "refactor-patrol", *flags ])
      if flags == %w[--list --no-list]
        assert_respond_to contract.fetch(:payload), :call
      else
        assert_equal "hive-refactor-patrol-jobs", contract.fetch(:schema)
        action.nil? ? assert_nil(contract.fetch(:extras).fetch("action")) : assert_equal(action, contract.fetch(:extras).fetch("action"))
      end
    end
  end

  def test_remaining_inventory_variants_resolve_without_leaking_previous_values
    %w[install list remove update publish].each do |subcommand|
      selected = Hive::CliUsageContracts.contract([ "workflow", subcommand ])
      assert_equal "hive-workflow-#{subcommand}", selected.fetch(:schema)
      assert_equal "usage", selected.fetch(:error_kind)
      assert_empty selected.fetch(:extras)
    end
    { "inspect" => "status", "status" => "status", "doctor" => "doctor", "dry-run" => "dry-run" }.each do |subcommand, schema|
      assert_equal({ schema: "hive-module-#{schema}", error_kind: "usage" },
        Hive::CliUsageContracts.contract([ "module", subcommand ]))
    end
    payload = Hive::CliUsageContracts.error_payload(
      Hive::CliUsageContracts.contract(%w[web install]), Hive::InvalidTaskPath.new("boom")
    )
    assert_equal "hive-web-install", payload.fetch("schema")
    refute payload.key?("runtime")
    assert_equal "managed_service", payload.fetch("mode")
    %w[pr brainstorm plan develop open-pr review artifacts finalize archive].each do |verb|
      selected = Hive::CliUsageContracts.contract([ verb ])
      assert_equal({ "verb" => verb == "pr" ? "open-pr" : verb }, selected.fetch(:extras))
      assert_equal "invalid_task_path", selected.fetch(:error_kind)
    end
  end

  private

  def cold_ruby(code)
    # Keep RUBYOPT, including the coverage boot preload, in the child.
    out, err, status = Open3.capture3(
      { "GEM_HOME" => Gem.dir, "GEM_PATH" => Gem.path.uniq.join(File::PATH_SEPARATOR) },
      RbConfig.ruby, "-Ilib", "-e", code, chdir: ROOT
    )
    assert_predicate status, :success?, "cold process failed: #{err}"
    out
  end
end
