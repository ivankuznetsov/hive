require "test_helper"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/forget"
require "hive/commands/prune"
require "hive/commands/doctor"
require "hive/commands/update"
require "hive/commands/uninstall"
require "hive/commands/migrate"
require "hive/commands/new"
require "hive/commands/generate_name"
require "hive/commands/run"
require "hive/commands/rebase_status"
require "hive/commands/stage_action"
require "hive/commands/status"
require "hive/commands/approve"
require "hive/commands/findings"
require "hive/commands/finding_toggle"
require "hive/commands/patrol"
require "hive/commands/digest"
require "hive/commands/markers"
require "hive/commands/daemon"
require "hive/commands/bot"
require "hive/commands/metrics"

class HiveCliTest < Minitest::Test
  include HiveTestHelper

  CommandDouble = Struct.new(:return_value, :calls) do
    def call
      calls << :call
      return_value
    end
  end


  def with_command_new_stub(klass, return_value: true)
    calls = []
    double = CommandDouble.new(return_value, calls)
    with_replaced_singleton_method(klass, :new, lambda { |*args, **kwargs|
      calls << { args: args, kwargs: kwargs }
      double
    }) do
      yield calls
    end
  end

  def test_exit_on_failure_and_version_output
    assert_equal true, Hive::CLI.exit_on_failure?

    out, _err = capture_io { Hive::CLI.start([ "version" ]) }
    assert_equal "#{Hive::VERSION}\n", out
  end

  def test_init_forget_prune_update_uninstall_and_migrate_pass_options
    with_command_new_stub(Hive::Commands::Init) do |calls|
      Hive::CLI.start([ "init", "/tmp/project", "--force", "--json", "--workflow", "content_fixture" ])
      assert_equal [ "/tmp/project" ], calls.first.fetch(:args)
      assert_equal({ force: true, json: true, workflow: "content_fixture" }, calls.first.fetch(:kwargs))
      assert_equal :call, calls.last
    end

    with_command_new_stub(Hive::Commands::Forget) do |calls|
      Hive::CLI.start([ "forget", "demo", "--json" ])
      Hive::CLI.start([ "forget", "demo", "--json", "--if-exists" ])

      constructor_calls = calls.grep(Hash)
      assert_equal [ "demo" ], constructor_calls.first.fetch(:args)
      assert_equal({ json: true, if_exists: false }, constructor_calls.first.fetch(:kwargs))
      assert_equal [ "demo" ], constructor_calls.last.fetch(:args)
      assert_equal({ json: true, if_exists: true }, constructor_calls.last.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Prune) do |calls|
      Hive::CLI.start([ "prune", "--dry-run", "--json" ])
      assert_equal({ dry_run: true, json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Update) do |calls|
      Hive::CLI.start([ "update", "--dry-run" ])
      assert_equal({ dry_run: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Uninstall) do |calls|
      Hive::CLI.start([ "uninstall", "--purge", "--force-purge-state" ])
      assert_equal({ purge: true, force_purge_state: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Migrate) do |calls|
      Hive::CLI.start([ "migrate", "/tmp/project" ])
      assert_equal [ "/tmp/project" ], calls.first.fetch(:args)
    end
  end

  def test_doctor_loads_project_config_and_exits_with_command_status
    loaded = []
    with_replaced_singleton_method(Hive::Config, :load, lambda { |path|
      loaded << path
      { "ok" => true }
    }) do
      with_command_new_stub(Hive::Commands::Doctor, return_value: 65) do |calls|
        _out, _err, status = with_captured_exit { Hive::CLI.start([ "doctor", "--json" ]) }

        assert_equal 65, status
        assert_equal [ Dir.pwd ], loaded
        assert_equal({ config: { "ok" => true }, project_root: Dir.pwd, json: true }, calls.first.fetch(:kwargs))
      end
    end
  end

  def test_new_task_dispatches_joined_text_and_rejects_blank_text
    with_command_new_stub(Hive::Commands::New) do |calls|
      Hive::CLI.start([ "new", "proj", "build", "thing" ])
      assert_equal [ "proj", "build thing" ], calls.first.fetch(:args)
      assert_equal({ depends_on: nil, workflow: nil }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::New) do |calls|
      Hive::CLI.start([ "new", "proj", "--depends-on", "base-task", "--workflow", "content_fixture", "build", "thing" ])
      assert_equal [ "proj", "build thing" ], calls.first.fetch(:args)
      assert_equal({ depends_on: "base-task", workflow: "content_fixture" }, calls.first.fetch(:kwargs))
    end

    _out, err, status = with_captured_exit { Hive::CLI.start([ "new", "proj" ]) }
    assert_equal Hive::ExitCodes::GENERIC, status
    assert_match(/missing task text/, err)
  end

  def test_generate_name_passes_lookup_options
    with_command_new_stub(Hive::Commands::GenerateName) do |calls|
      Hive::CLI.start([ "generate-name", "slug", "--project", "proj", "--stage", "inbox" ])

      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ project: "proj", stage: "inbox" }, calls.first.fetch(:kwargs))
      assert_equal :call, calls.last
    end
  end

  def test_run_and_rebase_status_pass_lookup_options
    with_command_new_stub(Hive::Commands::Run) do |calls|
      Hive::CLI.start([ "run", "slug", "--project", "proj", "--stage", "plan", "--json", "--no-rebase" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ project: "proj", stage: "plan", json: true, no_rebase: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::RebaseStatus) do |calls|
      Hive::CLI.start([ "rebase-status", "slug", "--project", "proj", "--stage", "execute", "--json" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ project: "proj", stage: "execute", json: true }, calls.first.fetch(:kwargs))
    end
  end

  def test_workflow_verbs_dispatch_stage_action_with_options
    expected = {
      "brainstorm" => "brainstorm",
      "plan" => "plan",
      "develop" => "develop",
      "open-pr" => "open-pr",
      "pr" => "open-pr",
      "review" => "review",
      "artifacts" => "artifacts",
      "finalize" => "finalize",
      "archive" => "archive"
    }

    with_command_new_stub(Hive::Commands::StageAction) do |calls|
      expected.each_key do |verb|
        Hive::CLI.start([ verb, "slug", "--from", "inbox", "--project", "proj", "--json" ])
      end

      actual = calls.grep(Hash).map { |call| [ call.fetch(:args), call.fetch(:kwargs) ] }
      assert_equal expected.values.map { |verb| [ [ verb, "slug" ], { project: "proj", from: "inbox", json: true } ] }, actual
    end
  end

  def test_archive_without_target_lists_archived_tasks_via_status
    with_command_new_stub(Hive::Commands::Status) do |calls|
      Hive::CLI.start([ "archive", "--json" ])

      assert_equal({ json: true, project: nil, archive: true }, calls.first.fetch(:kwargs))
      assert_equal :call, calls.last
    end
  end

  def test_archive_without_target_warns_when_from_is_supplied
    with_command_new_stub(Hive::Commands::Status) do |calls|
      _stdout, stderr = capture_io do
        Hive::CLI.start([ "archive", "--from", "8-finalize" ])
      end

      assert_includes stderr, "--from is ignored when listing"
      assert_equal({ json: false, project: nil, archive: true }, calls.first.fetch(:kwargs))
    end
  end

  def test_archive_without_target_scopes_to_project
    with_command_new_stub(Hive::Commands::Status) do |calls|
      Hive::CLI.start([ "archive", "--project", "proj" ])

      assert_equal({ json: false, project: "proj", archive: true }, calls.first.fetch(:kwargs))
    end
  end

  def test_status_approve_findings_and_finding_toggles_pass_options
    with_command_new_stub(Hive::Commands::Status) do |calls|
      Hive::CLI.start([ "status", "--diagnose", "slug", "--project", "proj", "--stage", "2-gather", "--write", "--force", "--json" ])
      assert_equal({ json: true, diagnose: "slug", project: "proj", stage: "2-gather", write: true, force: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Approve) do |calls|
      Hive::CLI.start([ "approve", "slug", "--to", "3-report", "--from", "2-gather", "--project", "proj", "--force", "--json" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ to: "3-report", from: "2-gather", project: "proj", force: true, json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Findings) do |calls|
      Hive::CLI.start([ "findings", "slug", "--pass", "2", "--project", "proj", "--stage", "execute", "--json" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ pass: 2, project: "proj", stage: "execute", json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::FindingToggle) do |calls|
      Hive::CLI.start([ "accept-finding", "slug", "1", "2", "--all", "--severity", "high", "--pass", "3", "--project", "proj", "--stage", "execute", "--json" ])
      Hive::CLI.start([ "reject-finding", "slug", "4", "--severity", "low", "--project", "proj", "--json" ])

      accept = calls.grep(Hash).first
      reject = calls.grep(Hash).last
      assert_equal [ Hive::Commands::FindingToggle::ACCEPT, "slug" ], accept.fetch(:args)
      assert_equal({ ids: [ "1", "2" ], all: true, severity: "high", pass: 3, project: "proj", stage: "execute", json: true }, accept.fetch(:kwargs))
      assert_equal [ Hive::Commands::FindingToggle::REJECT, "slug" ], reject.fetch(:args)
      assert_equal({ ids: [ "4" ], all: false, severity: "low", pass: nil, project: "proj", stage: nil, json: true }, reject.fetch(:kwargs))
    end
  end

  def test_patrol_markers_daemon_bot_and_metrics_pass_options
    with_command_new_stub(Hive::Commands::Patrol) do |calls|
      Hive::CLI.start([ "patrol", "proj", "--dry-run", "--json" ])
      assert_equal [ "proj" ], calls.first.fetch(:args)
      assert_equal({ json: true, dry_run: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Digest) do |calls|
      Hive::CLI.start([ "digest", "--date", "2026-06-13", "--dry-run", "--json" ])
      assert_equal [], calls.first.fetch(:args)
      assert_equal({ date: "2026-06-13", json: true, dry_run: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Markers) do |calls|
      Hive::CLI.start([ "markers", "clear", "slug", "--name", "ERROR", "--project", "proj", "--match-attr", "exit_code=1", "--json" ])
      assert_equal [ "clear", "slug" ], calls.first.fetch(:args)
      assert_equal({ name: "ERROR", project: "proj", match_attr: "exit_code=1", json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Daemon) do |calls|
      Hive::CLI.start([ "daemon", "start", "--detach", "--dry-run", "--json" ])
      assert_equal [ "start", nil ], calls.first.fetch(:args)
      assert_equal({ detach: true, dry_run: true, all: false, json: true, force: false, queue_args: [] },
                   calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Bot) do |calls|
      Hive::CLI.start([ "bot", "start", "--detach", "--dry-run", "--json" ])
      assert_equal [ "start" ], calls.first.fetch(:args)
      assert_equal({ foreground: false, dry_run: true, json: true, force: false }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Metrics) do |calls|
      Hive::CLI.start([ "metrics", "rollback-rate", "--days", "30", "--project", "proj", "--json" ])
      assert_equal [ "rollback-rate" ], calls.first.fetch(:args)
      assert_equal({ days: 30, project: "proj", json: true }, calls.first.fetch(:kwargs))
    end
  end


  def test_bot_rejects_foreground_and_detach_together
    _out, err, status = with_captured_exit do
      Hive::CLI.start([ "bot", "start", "--foreground", "--detach" ])
    end

    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/do not combine it with --foreground/, err)
  end

  def test_bot_rejects_force_on_non_install_subcommand
    _out, err, status = with_captured_exit do
      Hive::CLI.start([ "bot", "start", "--force" ])
    end

    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/--force only applies to `install`/, err)
  end

  # P3: `hive web --json` previously accepted the global --json and silently
  # ignored it. Mirror `hive tui`'s rejection: emit a structured error
  # envelope and exit with EX_USAGE rather than booting a long-lived server.
  def test_web_rejects_json_with_usage_error
    out, _err, status = with_captured_exit { Hive::CLI.start([ "web", "--json" ]) }

    assert_equal Hive::ExitCodes::USAGE, status, "hive web --json must exit EX_USAGE, not start a server"
    payload = JSON.parse(out)
    assert_equal false, payload.fetch("ok")
    assert_equal "invalid_task_path", payload.fetch("error_kind")
    assert_match(/no JSON output/, payload.fetch("message"))
  end

  # The non-JSON `hive web` path boots the long-lived server via
  # Commands::Web.new(...).call. A unit test can't run Puma, so swap
  # Commands::Web for a recorder class for the duration of the call (the same
  # constant-swap technique web_command_test.rb uses for Puma::Server). This
  # proves the CLI wires bind/port through to the command and invokes #call,
  # without booting a socket.
  def test_web_wires_bind_and_port_into_the_web_command
    require "hive/commands/web"
    captured = []
    recorder = Class.new do
      define_method(:initialize) { |bind:, port:| captured << { bind: bind, port: port } }
      define_method(:call) { captured << :called }
    end

    original = Hive::Commands.const_get(:Web)
    Hive::Commands.send(:remove_const, :Web)
    Hive::Commands.const_set(:Web, recorder)
    begin
      capture_io { Hive::CLI.start([ "web", "--bind", "0.0.0.0", "--port", "9123" ]) }
    ensure
      Hive::Commands.send(:remove_const, :Web)
      Hive::Commands.const_set(:Web, original)
    end

    assert_equal({ bind: "0.0.0.0", port: 9123 }, captured.first,
                 "the --bind/--port flags must reach the web command")
    assert_equal :called, captured.last, "hive web must invoke the web command's #call"
  end

  def test_daemon_argv_errors_emit_json_envelopes_before_raising
    out, _err, status = with_captured_exit { Hive::CLI.start([ "daemon", "--json" ]) }
    payload = JSON.parse(out)
    assert_equal Hive::ExitCodes::USAGE, status
    assert_equal "hive-daemon-enroll", payload.fetch("schema")
    assert_equal Hive::Schemas::EnrollErrorKind::MISSING_PROJECT, payload.fetch("error_kind")

    out, _err, status = with_captured_exit { Hive::CLI.start([ "daemon", "enable", "one", "two", "--json" ]) }
    payload = JSON.parse(out)
    assert_equal Hive::ExitCodes::USAGE, status
    assert_equal Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL, payload.fetch("error_kind")

    out, _err, status = with_captured_exit { Hive::CLI.start([ "daemon", "status", "--force", "--json" ]) }
    payload = JSON.parse(out)
    assert_equal Hive::ExitCodes::USAGE, status
    assert_equal Hive::Schemas::EnrollErrorKind::WRONG_SUBCOMMAND_FLAG, payload.fetch("error_kind")
  end

  def test_bench_submit_dispatches_to_command
    require "hive/commands/bench_submit"
    with_command_new_stub(Hive::Commands::BenchSubmit) do |calls|
      Hive::CLI.start([ "bench", "submit", "my-slug-260601-aa11", "--project", "demo" ])
      ctor = calls.grep(Hash).first
      assert_equal [ "my-slug-260601-aa11" ], ctor.fetch(:args)
      assert_equal "demo", ctor.fetch(:kwargs)[:project]
      assert_equal :call, calls.last
    end
  end

  def test_bench_unknown_subcommand_warns_and_exits_usage
    out = +""
    err = +""
    out, err = capture_io do
      assert_raises(SystemExit) { Hive::CLI.start([ "bench", "frobnicate" ]) }
    end
    assert_match(/unknown subcommand/, "#{out}#{err}")
  end
end
