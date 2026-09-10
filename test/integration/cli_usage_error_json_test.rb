require "test_helper"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"

class CliUsageErrorJsonTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  # Thor's exact two-line arity error for `hive workflow a b c` (too many
  # positionals), rejected before command dispatch. Shared by the --json and
  # human-mode arity tests below so a Thor upgrade or a `desc "workflow
  # SUBCOMMAND [ID]"` reword updates one literal, not two. Each call site keeps
  # its own intentional pin: `.chomp` for the JSON `message` field, the trailing
  # newline as-is for the human stderr stream.
  THOR_WORKFLOW_ARITY_PROSE = <<~MSG.freeze
    ERROR: "hive workflow" was called with arguments ["a", "b", "c"]
    Usage: "hive workflow SUBCOMMAND [ID]"
  MSG

  def run_hive(home, *args)
    Open3.capture3({ "HIVE_HOME" => home }, RbConfig.ruby, "-Ilib", HIVE_BIN, *args)
  end

  def assert_pre_dispatch_error(home, argv, schema:, error_kind:, version: :registered, extras: {})
    out, _err, status = run_hive(home, *argv)

    refute status.success?, "#{argv.inspect} should fail"
    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    payload = JSON.parse(out)
    assert_equal schema, payload["schema"]
    assert_equal false, payload["ok"]
    if schema == "hive-metrics-rollback-rate"
      refute payload.key?("error_class"), "the metrics v1 error schema has no error_class field"
    else
      expected_class = error_kind == "invalid_task_path" ? "InvalidTaskPath" : "UsageError"
      assert_equal expected_class, payload["error_class"]
    end
    assert_equal error_kind, payload["error_kind"]
    assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]

    extras.each do |key, value|
      value.nil? ? assert_nil(payload.fetch(key)) : assert_equal(value, payload.fetch(key))
    end
    assert_equal version, payload.fetch("schema_version") unless version == :registered || version.nil?

    if Hive::Schemas::SCHEMA_VERSIONS.key?(schema)
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch(schema), payload["schema_version"]
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema))))
      assert_empty schemer.validate(payload).map { |error| error["error"] },
                   "#{argv.inspect} envelope must validate against #{schema}"
    elsif version == :registered || version.nil?
      refute payload.key?("schema_version"), "#{schema} is an unversioned legacy envelope"
    end
    payload
  end

  def test_json_usage_errors_emit_envelopes_before_command_dispatch
    cases = [
      [ %w[run --json], "hive-run", {} ],
      [ %w[approve --json], "hive-approve", {} ],
      [ %w[decide task approve --json], "hive-decide", {} ],
      [ %w[markers clear --json], "hive-markers-clear", {} ],
      [ %w[drop --json], "hive-drop", {} ],
      [ %w[findings --json], "hive-findings", {} ],
      [ %w[accept-finding --json], "hive-findings", { "operation" => "accept" } ],
      [ %w[reject-finding --json], "hive-findings", { "operation" => "reject" } ],
      [ %w[rebase-status --json], "hive-rebase-status", {} ],
      [ %w[brainstorm --json], "hive-stage-action", { "verb" => "brainstorm" } ],
      [ %w[pr --json], "hive-stage-action", { "verb" => "open-pr" } ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema, extras|
        out, _err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal schema, payload["schema"]
        assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch(schema, 1), payload["schema_version"]
        assert_equal false, payload["ok"]
        assert_equal "InvalidTaskPath", payload["error_class"]
        assert_equal "invalid_task_path", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        extras.each { |key, value| assert_equal value, payload[key] }
      end
    end
  end

  # Fixed expectations transcribed from the pre-extraction inventory in
  # docs/implementation/cli-usage-contracts-baseline.md. The deliberately invalid
  # assignment followed by --json guarantees wrapper rejection before dispatch,
  # even for commands whose variable arity otherwise permits these positionals.
  def test_current_main_inventory_retains_pre_dispatch_contracts
    cases = [
      [ %w[run], "run", 2, "invalid_task_path" ],
      [ %w[rebase-status], "rebase-status", 1, "invalid_task_path" ],
      [ %w[approve], "approve", 2, "invalid_task_path" ],
      [ %w[drop], "drop", 2, "invalid_task_path" ],
      [ %w[findings], "findings", 1, "invalid_task_path" ],
      [ %w[patrol], "patrol", 3, "error" ],
      [ %w[refactor-patrol], "refactor-patrol", 4, "error" ],
      [ %w[accept-finding], "findings", 1, "invalid_task_path", { "operation" => "accept" } ],
      [ %w[reject-finding], "findings", 1, "invalid_task_path", { "operation" => "reject" } ],
      [ %w[markers clear], "markers-clear", 1, "invalid_task_path" ],
      [ %w[status extra], "running-status", 2, "error" ],
      [ %w[status --diagnose=task extra], "status-diagnose", 2, "error" ],
      [ %w[status --operational extra], "operational-status", 4, "error" ],
      [ %w[status --internal-task-graph extra], "status", 8, "error" ],
      [ %w[status --daemon-task=task extra], "status", 8, "error" ],
      [ %w[runtime unknown extra], "runtime-maintenance", 1, "usage",
        { "action" => "unknown", "runtime_code" => "usage", "next_action" => nil, "details" => {} } ],
      [ %w[runtime], "runtime-maintenance", 1, "usage", { "action" => "status" } ],
      [ %w[act], "act", 2, "usage", { "action_id" => "", "target" => "" } ],
      [ %w[act workflow.advance], "act", 2, "usage", { "action_id" => "workflow.advance", "target" => "" } ],
      [ %w[act --observation ignored workflow.advance demo:task extra], "act", 2, "usage",
        { "action_id" => "workflow.advance", "target" => "demo:task" } ],
      [ %w[prune extra], "prune", 1, "usage" ],
      [ %w[forget project extra], "forget", 1, "usage" ],
      [ %w[metrics rollback-rate extra], "metrics-rollback-rate", 1, "error" ],
      [ %w[answer-digest extra], "answer-digest", 1, "usage" ],
      [ %w[answer], "answer", 1, "usage" ],
      [ %w[workflow validate editorial extra], "workflow-validate", 1, "usage", { "valid" => false, "id" => "editorial" } ],
      [ %w[worktree status demo extra], "worktree", 1, "invalid_arguments" ],
      [ %w[bot status extra], "bot-status", 1, "extra_arguments" ],
      [ %w[pairing approve extra], "pairing-approve", 1, "invalid_arguments" ],
      [ %w[pairing list extra], "pairing-list", 1, "invalid_arguments" ],
      [ %w[pairing unknown extra], "pairing-list", 1, "invalid_arguments" ],
      [ %w[pairing], "pairing-list", 1, "invalid_arguments" ],
      [ %w[decide task approve], "decide", 1, "invalid_task_path" ]
    ]
    %w[pr brainstorm plan develop open-pr review artifacts finalize archive].each do |verb|
      cases << [ [ verb ], "stage-action", 2, "invalid_task_path", { "verb" => verb == "pr" ? "open-pr" : verb } ]
    end
    { "install" => 2, "list" => 2, "remove" => 1, "update" => 2, "publish" => 2 }.each do |sub, version|
      cases << [ [ "workflow", sub, "x", "extra" ], "workflow-#{sub}", version, "usage" ]
    end
    [ [], %w[new], %w[commit], %w[unknown] ].each do |sub|
      cases << [ [ "workflow", *sub ], "workflow-new", 1, "usage" ]
    end
    { "install" => "lifecycle", "unknown" => "lifecycle", "list" => "list", "inspect" => "status",
      "status" => "status", "doctor" => "doctor", "dry-run" => "dry-run" }.each do |sub, schema|
      cases << [ [ "module", sub, "x", "extra" ], "module-#{schema}", 1, "usage" ]
    end
    cases << [ %w[module], "module-lifecycle", 1, "usage" ]
    { "--list" => "list", "--show=x" => "show", "--archive=x" => "show",
      "--full" => nil, "--limit=1" => nil, "--cursor=x" => nil }.each do |flag, action|
      cases << [ [ "refactor-patrol", flag ], "refactor-patrol-jobs", 2, "usage", { "action" => action } ]
    end
    with_tmp_global_config do |home|
      cases.each do |argv, schema, version, kind, extras|
        payload = assert_pre_dispatch_error(home, [ *argv, "--json=yes", "--json" ],
          schema: "hive-#{schema}", error_kind: kind, version: version, extras: extras || {})
        assert_equal [ { "message" => payload.fetch("message") } ], payload.fetch("diagnostics") if schema == "workflow-validate"
      end
    end
  end

  def test_inventory_native_context_variants_remain_command_owned
    with_tmp_global_config do |home|
      { nil => "managed_service", "--no-bootstrap" => "diagnose_only", "--no-service" => "service_opt_out" }.each do |flag, mode|
        payload = assert_pre_dispatch_error(home, [ "setup", flag, "--json=yes", "--json" ].compact,
          schema: "hive-setup", version: 1, error_kind: "usage", extras: { "mode" => mode })
        assert_kind_of String, payload.fetch("url")
        assert_kind_of Array, payload.fetch("warnings")
        assert_equal %w[platform readiness ready service_enabled service_installed service_manager_available service_running unit_path url],
          payload.fetch("service").keys.sort
      end
      %w[status install].each do |sub|
        payload = assert_pre_dispatch_error(home, [ "web", sub, "extra", "--json=yes", "--json" ],
          schema: "hive-web-#{sub}", version: 1, error_kind: "invalid_task_path", extras: { "mode" => "managed_service" })
        assert_kind_of String, payload.fetch("url")
        assert_kind_of String, payload.fetch("readiness")
        assert_kind_of Array, payload.fetch("warnings")
        assert_equal sub == "status", payload.key?("runtime")
      end
      out, err, status = run_hive(home, "web", "unknown", "extra", "--json=yes", "--json")
      assert_equal 64, status.exitstatus
      assert_empty out
      assert_match(/--json/, err)
      refute_includes err, "usage_contract_resolution_failed"
    end
  end

  def test_runtime_usage_and_early_activation_failures_use_the_runtime_contract
    with_tmp_global_config(runtime: false) do |home|
      File.binwrite(File.join(home, "task-counter.yml"), "---\ngeneration: 1\n")
      schemer = JSONSchemer.schema(JSON.parse(File.read(
        Hive::Schemas.schema_path("hive-runtime-maintenance")
      )))

      out, _err, status = run_hive(home, "run", "demo:task", "--json")
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-runtime-maintenance", payload.fetch("schema")
      assert_equal "fleet_cutover_required", payload.fetch("runtime_code")
      assert_equal "run", payload.fetch("action")
      assert_empty schemer.validate(payload).to_a

      File.unlink(File.join(home, "task-counter.yml"))
      out, _err, status = run_hive(home, "runtime", "unknown", "extra", "--json")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "unknown", payload.fetch("action")
      assert_equal "usage", payload.fetch("runtime_code")
      assert_empty schemer.validate(payload).to_a
    end
  end

  def test_act_json_usage_errors_preserve_required_action_identity
    cases = [
      [ %w[act --json], "", "" ],
      [ %w[act workflow.advance --json], "workflow.advance", "" ],
      [ %w[act workflow.advance demo:task --json], "workflow.advance", "demo:task" ],
      [
        [ "act", "workflow.advance", "demo:task", "extra", "--observation", "a" * 64, "--json" ],
        "workflow.advance",
        "demo:task"
      ]
    ]
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-act"))))

    with_tmp_global_config do |home|
      cases.each do |argv, action_id, target|
        out, _err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.inspect} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal "hive-act", payload.fetch("schema")
        assert_equal false, payload.fetch("ok")
        assert_equal "usage", payload.fetch("error_kind")
        assert_equal action_id, payload.fetch("action_id")
        assert_equal target, payload.fetch("target")
        assert_empty schemer.validate(payload).map { |error| error.fetch("error") },
                     "#{argv.inspect} envelope must validate against hive-act"
      end
    end
  end

  def test_status_mode_conflicts_are_usage_errors_with_the_selected_schema
    with_tmp_global_config do |home|
      out, _err, status = run_hive(
        home, "status", "--internal-task-graph", "--operational", "--json"
      )

      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-operational-status", payload.fetch("schema")
      assert_equal false, payload.fetch("ok")
      assert_match(
        /--internal-task-graph cannot be combined with --operational/,
        payload.fetch("message")
      )

      out, _err, status = run_hive(
        home, "status", "--operational", "--diagnose", "task", "--json"
      )
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-status-diagnose", payload.fetch("schema")
      assert_match(/--operational cannot be combined/, payload.fetch("message"))

      out, _err, status = run_hive(home, "status", "--internal-task-graph", "--json")
      assert status.success?
      payload = JSON.parse(out)
      assert_equal "hive-status", payload.fetch("schema")
      assert_equal 8, payload.fetch("schema_version")

      out, _err, status = run_hive(home, "status", "--full", "--json")
      refute status.success?
      payload = JSON.parse(out)
      assert_equal "hive-running-status", payload.fetch("schema")
      assert_match(/called with arguments \["--full"\]/, payload.fetch("message"))
    end
  end

  def test_worktree_pre_dispatch_usage_errors_preserve_the_json_contract
    with_tmp_global_config do |home|
      [
        %w[worktree status demo extra --json],
        %w[worktree repair demo --strategy unknown --json]
      ].each do |argv|
        assert_pre_dispatch_error(
          home,
          argv,
          schema: "hive-worktree",
          error_kind: "invalid_arguments"
        )
      end
    end
  end

  def test_watch_rejects_single_document_json_with_stream_guidance
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "watch", "demo:task", "--json")

      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_match(/--json-lines/, err)
      assert_match(/stream/, err)
    end
  end

  def test_screenote_commands_json_usage_errors_emit_unversioned_envelopes
    with_tmp_global_config do |home|
      [
        [ %w[connect --json], /Usage: "hive connect SERVICE"/ ],
        [ %w[disconnect --json], /Usage: "hive disconnect SERVICE"/ ]
      ].each do |argv, message_pattern|
        out, err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal false, payload["ok"]
        assert_equal "screenote", payload["service"]
        assert_equal "UsageError", payload["error_class"]
        assert_equal "usage", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        assert_match message_pattern, payload["message"]
        refute payload.key?("schema"), "Screenote connect/disconnect JSON failures are unversioned"
        assert_match(/^hive: ERROR: /, err.lines.first)
      end
    end
  end

  def test_setup_extra_positional_json_usage_error_uses_setup_envelope
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "setup", "extra", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-setup", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "UsageError", payload["error_class"]
      assert_equal "usage", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/Usage: "hive setup"/, payload["message"])
      assert_equal "managed_service", payload["mode"]
      assert_kind_of String, payload["url"]
      assert_kind_of Hash, payload["service"]
      assert payload.dig("service", "readiness")
      assert_kind_of Array, payload["warnings"]
      assert_match(/^hive: ERROR: /, err.lines.first)
    end
  end

  # Bare `hive workflow` (no subcommand) with --json must ride the
  # hive-workflow-new envelope (error_kind "usage"), not Thor's generic arity
  # prose. The sibling `hive workflow new` no-id case raises the command's own
  # UsageError ("missing workflow id"); that arm is verified only as a raised
  # message via `new!` in the unit suite (test_rejects_reserved_and_invalid_ids),
  # not re-driven through the JSON envelope here.
  def test_bare_workflow_json_usage_error_uses_workflow_new_envelope
    with_tmp_global_config do |home|
      out, _err, status = run_hive(home, "workflow", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-workflow-new", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-workflow-new"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "UsageError", payload["error_class"]
      assert_equal "usage", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_equal "missing SUBCOMMAND (expected: new, validate, commit, install, list, update, remove, publish)", payload["message"]
      assert_equal %w[new validate commit install list update remove publish], payload["expected"]
    end
  end

  def test_bare_workflow_human_usage_error_names_expected_subcommand
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "workflow")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_equal "hive workflow: missing SUBCOMMAND (expected: new, validate, commit, install, list, update, remove, publish)\n", err
    end
  end

  # `hive workflow a b c` (too many positionals) is rejected by Thor *before*
  # command dispatch, so it never reaches the command's own UsageError. With
  # --json it must still ride the hive-workflow-new envelope via the bin/hive
  # "workflow" usage-error contract (error_kind "usage", exit 64,
  # error_class "UsageError") — not plain Thor arity prose on stderr.
  # This is the sole reason the "workflow" entry exists in
  # JSON_USAGE_ERROR_CONTRACTS; without this assertion a regression dropping
  # the contract entry would silently revert to bare stderr with no failing test.
  def test_too_many_positionals_workflow_json_usage_error_uses_workflow_new_envelope
    with_tmp_global_config do |home|
      out, _err, status = run_hive(home, "workflow", "a", "b", "c", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-workflow-new", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-workflow-new"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "UsageError", payload["error_class"]
      assert_equal "usage", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_equal THOR_WORKFLOW_ARITY_PROSE.chomp, payload["message"]
      # Argv-shape (Thor) errors ride the envelope but never gain the
      # in-command UsageError discovery fields — those come only from the
      # command's own raise path (bare `hive workflow`), not the bin/hive
      # contract that wraps Thor's arity error.
      refute payload.key?("expected"), "Thor arity errors must not carry `expected`"
      refute payload.key?("value"), "Thor arity errors must not carry `value`"
    end
  end

  def test_workflow_validate_arity_error_uses_validate_envelope
    with_tmp_global_config do |home|
      assert_pre_dispatch_error(
        home,
        %w[workflow validate editorial extra --json],
        schema: "hive-workflow-validate",
        error_kind: "usage"
      )
    end
  end

  # Human-mode (non-`--json`) sibling of the case above. bin/hive branches its
  # stderr prefix on whether a JSON envelope was emitted (`hive: ...` only when
  # JSON rode out); without --json the raw Thor arity prose must surface on
  # stderr with empty stdout (exit 64). Guards that prefix branch and the Thor
  # arity message against a silent regression.
  def test_too_many_positionals_workflow_human_usage_error_emits_thor_arity_prose
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "workflow", "a", "b", "c")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_equal THOR_WORKFLOW_ARITY_PROSE, err
    end
  end

  def test_launcher_resolves_once_and_reuses_the_selected_contract
    with_tmp_global_config do |home|
      out, err, status, probe = traced_usage(home, "success", %w[run --json])
      assert_equal 64, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "InvalidTaskPath", payload.fetch("error_class")
      assert_equal "invalid_task_path", payload.fetch("error_kind")
      assert_equal 1, probe.fetch("resolutions")
      assert_equal true, probe.fetch("classification_identity")
      assert_equal true, probe.fetch("render_identity")
      refute_includes err, "usage_contract_resolution_failed"
    end
  end

  def test_one_shot_loader_and_resolver_failures_are_terminal_and_safe
    with_tmp_global_config do |home|
      %w[loader resolver].product([ true, false ]).each do |mode, json|
        argv = json ? %w[run --json] : %w[run]
        out, err, status, probe = traced_usage(home, mode, argv)
        assert_equal 64, status.exitstatus
        assert_empty out
        assert_equal 1, probe.fetch("resolutions")
        assert_equal 1, probe.fetch("loads") if mode == "loader"
        assert_equal "Hive::UsageError", probe.fetch("error_class")
        assert_equal true, probe.fetch("classification_identity")
        assert_equal true, probe.fetch("render_identity")
        klass = mode == "loader" ? "LoadError" : "ArgumentError"
        diagnostics = err.lines.grep(/^\[hive.cli\]/)
        assert_equal [ "[hive.cli] usage_contract_resolution_failed exception=#{klass}\n" ], diagnostics
        assert_equal 1, err.scan(klass).length
        assert_match(/Usage: "hive run TARGET"/, err)
        refute_includes err, "secret-sentinel"
        refute_includes err, "hive:"
        refute_match(/\.rb:\d+/, err)
      end
    end
  end

  def test_absent_contract_has_no_resolution_failure_diagnostic
    with_tmp_global_config do |home|
      out, err, status, probe = traced_usage(home, "unsupported", %w[unknown-command --json])
      assert_equal 64, status.exitstatus
      assert_empty out
      assert_equal 1, probe.fetch("resolutions")
      assert_equal "Hive::UsageError", probe.fetch("error_class")
      refute_includes err, "usage_contract_resolution_failed"
    end
  end

  def test_successful_command_does_not_resolve_a_usage_contract
    with_tmp_global_config do |home|
      _out, _err, status, probe = traced_usage(home, "success", %w[--version])
      assert status.success?
      assert_equal 0, probe.fetch("resolutions")
    end
  end

  def traced_usage(home, mode, argv)
    with_tmp_dir do |dir|
      patch = File.join(dir, "trace-usage.rb")
      File.write(patch, <<~RUBY)
        require "hive/cli_usage_contracts"
        require "json"
        $usage_probe = { "resolutions" => 0, "loads" => 0 }
        $usage_mode = #{mode.inspect}
        abort "run boundary is not cold" if Hive::CliUsageContracts.instance_variable_get(:@contracts).key?("run")
        abort "run file is not cold" if $LOADED_FEATURES.any? { |path| path.end_with?("/commands/run.rb") }
        if $usage_mode == "resolver"
          Hive::CliUsageContracts.declare("run") { raise ArgumentError, "secret-sentinel" }
        end
        module UsageProbe
          def contract(...)
            $usage_probe["resolutions"] += 1
            $usage_selected = super
          end

          def load_boundary_declaration!(command)
            $usage_probe["loads"] += 1
            if $usage_mode == "loader" && $usage_probe["loads"] == 1
              raise LoadError, "secret-sentinel"
            end
            super
          end

          def usage_error(selected, message)
            $usage_probe["classification_identity"] = selected.equal?($usage_selected)
            error = super
            $usage_probe["error_class"] = error.class.name
            error
          end
        end
        module UsageRenderProbe
          def emit_json_usage_error(selected, *args)
            $usage_probe["render_identity"] = selected.equal?($usage_selected)
            super
          end
        end
        Hive::CliUsageContracts.singleton_class.prepend(UsageProbe)
        Object.prepend(UsageRenderProbe)
        at_exit { warn "USAGE_PROBE=" + JSON.generate($usage_probe) }
      RUBY
      out, err, status = Open3.capture3(
        { "HIVE_HOME" => home, "RUBYOPT" => [ ENV["RUBYOPT"], "-r#{patch}" ].compact.join(" ") },
        RbConfig.ruby, "-Ilib", HIVE_BIN, *argv
      )
      trace = err.lines.find { |line| line.start_with?("USAGE_PROBE=") }
      refute_nil trace, err
      [ out, err.lines.reject { |line| line == trace }.join, status,
       JSON.parse(trace.delete_prefix("USAGE_PROBE=")) ]
    end
  end

  def test_json_generator_failure_falls_back_to_human_usage_error
    with_tmp_global_config do |home|
      with_tmp_dir do |dir|
        patch = File.join(dir, "break-json-generate.rb")
        File.write(patch, <<~RUBY)
          require "json"
          class << JSON
            alias __hive_original_generate generate

            def generate(*args)
              if caller_locations.any? { |location| location.base_label == "emit_json_usage_error" }
                raise JSON::GeneratorError, "forced generator failure"
              end

              __hive_original_generate(*args)
            end
          end
        RUBY

        out, err, status = Open3.capture3(
          { "HIVE_HOME" => home, "RUBYOPT" => [ ENV["RUBYOPT"], "-r#{patch}" ].compact.join(" ") },
          RbConfig.ruby, "-Ilib", HIVE_BIN, "connect", "--json"
        )

        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        assert_empty out, "a failed serializer must not claim that a JSON envelope was emitted"
        assert_match(/Usage: "hive connect SERVICE"/, err)
        refute_match(/forced generator failure/, err)
      end
    end
  end

  def test_patrol_missing_project_json_usage_error_uses_patrol_envelope
    with_tmp_global_config do |home|
      out, _err, status = run_hive(home, "patrol", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-patrol", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-patrol"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "UsageError", payload["error_class"]
      assert_equal "error", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
    end
  end

  def test_bot_json_usage_errors_emit_bot_envelopes
    # Every bot --json usage error rides the hive-bot-status schema with
    # ok:false; validate each emitted payload against the published schema so
    # a schema-conforming agent client would actually accept it (the
    # ErrorPayload arm regression that produced an unvalidatable envelope).
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "bot", "status", "--force", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-bot-status", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "wrong_subcommand_flag", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/--force only applies/, payload["message"])
      assert_match(/^hive: hive bot status: --force only applies/, err.lines.last)
      assert_empty schemer.validate(payload).map { |e| e["error"] },
                   "bot status --force --json envelope must validate against hive-bot-status schema"

      out, err, status = run_hive(home, "bot", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-bot-status", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "missing_subcommand", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/missing SUBCOMMAND/, payload["message"])
      assert_match(/^hive: hive bot: missing SUBCOMMAND/, err.lines.last)
      assert_empty schemer.validate(payload).map { |e| e["error"] },
                   "bot --json envelope must validate against hive-bot-status schema"

      out, err, status = run_hive(home, "bot", "unknown", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-bot-status", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unknown_subcommand", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/unknown subcommand "unknown"/, payload["message"])
      assert_match(/^hive: hive bot: unknown subcommand "unknown"/, err.lines.last)
      assert_empty schemer.validate(payload).map { |e| e["error"] },
                   "bot unknown --json envelope must validate against hive-bot-status schema"
    end
  end

  # `hive bot SUBCOMMAND` takes a single positional and (unlike `daemon`) has no
  # `*targets` splat, so an extra positional such as `hive bot status extra` is
  # rejected by Thor *before* `Hive::Commands::Bot#call` runs — bypassing the
  # command-level usage-error emitters. With --json it must still ride the
  # hive-bot-status envelope via the bin/hive "bot" usage-error contract
  # (error_kind "extra_arguments", error_class "UsageError", exit 64), not
  # bare Thor arity prose on stderr. This is the sole reason the resolver has a
  # dedicated `bot` branch in json_usage_error_contract.
  def test_bot_extra_positional_json_usage_error_rides_bot_status_envelope
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    with_tmp_global_config do |home|
      [ %w[bot status extra --json], %w[bot install extra --json] ].each do |argv|
        out, err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal "hive-bot-status", payload["schema"]
        assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"), payload["schema_version"]
        assert_equal false, payload["ok"]
        assert_equal "UsageError", payload["error_class"]
        assert_equal "extra_arguments", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        assert_match(/was called with arguments/, payload["message"])
        assert_match(/^hive: ERROR: /, err.lines.first)
        assert_empty schemer.validate(payload).map { |e| e["error"] },
                     "#{argv.join(' ')} envelope must validate against hive-bot-status schema"
      end
    end
  end

  # Human-mode (non-`--json`) sibling: without --json the raw Thor arity prose
  # must surface on stderr with empty stdout (exit 64), guarding bin/hive's
  # stderr-prefix branch against a silent regression.
  def test_bot_extra_positional_human_usage_error_emits_thor_arity_prose
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "bot", "status", "extra")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_match(/was called with arguments \["status", "extra"\]/, err)
    end
  end

  def test_documented_json_surfaces_wrap_thor_arity_errors
    cases = [
      [ %w[status extra --json], "hive-running-status", "error" ],
      [ %w[status --diagnose task extra --json], "hive-status-diagnose", "error" ],
      [ %w[status --json -- extra --diagnose=task], "hive-running-status", "error" ],
      [ %w[prune extra --json], "hive-prune", "usage" ],
      [ %w[forget project extra --json], "hive-forget", "usage" ],
      [ %w[metrics rollback-rate extra --json], "hive-metrics-rollback-rate", "error" ],
      [ %w[web status extra --json], "hive-web-status", "invalid_task_path" ],
      [ %w[web install extra --json], "hive-web-install", "invalid_task_path" ],
      [ %w[web --bind install status extra --json], "hive-web-status", "invalid_task_path" ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema, error_kind|
        assert_pre_dispatch_error(home, argv, schema: schema, error_kind: error_kind)
      end
    end
  end

  def test_web_status_json_config_failure_retains_the_versioned_contract
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), "web: [\n")

      out, err, status = run_hive(home, "web", "status", "--json")

      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-web-status", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-web-status"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "ConfigError", payload["error_class"]
      assert_equal "config_error", payload["error_kind"]
      assert_equal Hive::ExitCodes::CONFIG, payload["exit_code"]
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-web-status"))))
      assert_empty schemer.validate(payload).map { |error| error["error"] }
      assert_match(/^hive: /, err)
    end
  end

  def test_web_install_json_service_write_failure_retains_the_versioned_contract
    with_tmp_global_config do |home|
      invalid_home = File.join(home, "home-is-a-file")
      File.write(invalid_home, "not a directory")

      out, err, status = Open3.capture3(
        { "HIVE_HOME" => home, "HOME" => invalid_home },
        RbConfig.ruby, "-Ilib", HIVE_BIN,
        "web", "install", "--no-bootstrap", "--json"
      )

      assert_equal Hive::ExitCodes::GENERIC, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-web-install", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-web-install"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "Error", payload["error_class"]
      assert_equal "service_install_failed", payload["error_kind"]
      assert_equal Hive::ExitCodes::GENERIC, payload["exit_code"]
      assert_equal(
        "Hive::UserService::Transaction::Unsafe: user-service home must be a directory",
        payload["message"]
      )
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-web-install"))))
      assert_empty schemer.validate(payload).map { |error| error["error"] }
      assert_equal 1, out.lines.length, "JSON mode must emit exactly one install document"
      assert_match(/^hive: /, err)
    end
  end

  def test_invalid_byte_errors_use_the_selected_json_surface
    invalid = "bad\xFF".b
    cases = [
      [ [ "status", "--diagnose", "task", "--json", invalid ], "hive-status-diagnose", "error" ],
      [ [ "web", "status", "--json", invalid ], "hive-web-status", "invalid_task_path" ],
      [ [ "bot", "status", "--json", invalid ], "hive-bot-status", "extra_arguments" ],
      [ [ "pairing", "list", "--json", invalid ], "hive-pairing-list", "invalid_arguments" ],
      [ [ "pairing", "unknown", "approve", "--json", invalid ],
        "hive-pairing-list", "invalid_arguments" ],
      [ [ "pairing", "approve", "telegram", "CODE", "--json", invalid ],
        "hive-pairing-approve", "invalid_arguments" ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema, error_kind|
        assert_pre_dispatch_error(home, argv, schema: schema, error_kind: error_kind)
      end
    end
  end

  def test_invalid_command_encoding_is_not_attributed_to_a_later_command
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "bad\xFF".b, "status", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_match(/invalid byte sequence/, err)
    end
  end

  def test_invalid_byte_json_arg_uses_command_usage_envelope
    with_tmp_global_config do |home|
      out, err, status = Open3.capture3(
        { "HIVE_HOME" => home, "LC_ALL" => "C" },
        RbConfig.ruby, "-Ilib", HIVE_BIN, "run", "--json", "bad\xFF".b
      )

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      refute_empty out, "JSON usage errors must emit an envelope"
      refute_match(%r{/thor/}, err)
      payload = JSON.parse(out)
      assert_equal "hive-run", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-run"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "InvalidTaskPath", payload["error_class"]
      assert_equal "invalid_task_path", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/invalid byte sequence/, payload["message"])
    end
  end
end
