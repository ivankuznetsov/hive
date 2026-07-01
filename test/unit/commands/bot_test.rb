require "test_helper"
require "hive/commands/bot"

class HiveCommandsBotTest < Minitest::Test
  include HiveTestHelper

  FakeSupervisor = Struct.new(:calls) do
    def run_forever
      calls << :run_forever
    end
  end

  FakeInstaller = Struct.new(:target_path, :envelope_platform, :messages, keyword_init: true)

  FakeLockFile = Struct.new(:calls) do
    def flock(_mode)
      true
    end

    def rewind
      calls << :rewind
    end

    def truncate(_length)
      calls << :truncate
    end

    def write(_payload)
      calls << :write
    end

    def flush
      calls << :flush
    end

    def close
      calls << :close
      raise IOError, "close failed"
    end
  end

  def setup
    @home = Dir.mktmpdir("hive-bot-command")
  end

  def teardown
    FileUtils.rm_rf(@home) if @home
  end

  def bot(subcommand, **kwargs)
    Hive::Commands::Bot.new(subcommand, **{ hive_home: @home }.merge(kwargs))
  end

  def configured_bot(subcommand, config: bot_config, **kwargs)
    command = bot(subcommand, **kwargs)
    command.define_singleton_method(:bot_config) { config }
    command
  end

  def bot_config(**overrides)
    {
      "pid_file" => File.join(@home, ".bot.pid"),
      "log_file" => File.join(@home, "logs", "bot.log"),
      "shutdown_grace_sec" => 0,
      "chat_id_allowlist" => [ 12345 ]
    }.merge(overrides.transform_keys(&:to_s))
  end

  def write_pid_payload(command, pid: 4242, started_at: Time.now.utc.iso8601)
    FileUtils.mkdir_p(File.dirname(command.pid_file))
    File.write(command.pid_file, { "pid" => pid, "started_at" => started_at }.to_yaml)
  end


  def test_call_routes_start_and_tail_subcommands
    routed = []

    [ [ "start", :start_bot, :start ], [ "tail", :tail_bot, :tail ] ].each do |subcommand, method_name, label|
      command = bot(subcommand)
      command.define_singleton_method(method_name) { routed << label }

      command.call
    end

    assert_equal %i[start tail], routed
  end

  def test_start_cleans_up_when_pid_payload_cleanup_fails
    command = configured_bot("start", foreground: true, dry_run: true)
    supervisor = FakeSupervisor.new([])
    command.define_singleton_method(:pid_file_payload) { raise "cannot parse pid payload" }

    with_replaced_singleton_method(Hive::Config, :telegram_bot_token!, -> { "test-token" }) do
      with_replaced_singleton_method(Hive::Bot::Supervisor, :new, ->(**_kwargs) { supervisor }) do
        command.call
      end
    end

    assert_equal [ :run_forever ], supervisor.calls
  end

  def test_start_ignores_lock_close_failures
    command = configured_bot("start", foreground: true, dry_run: true)
    supervisor = FakeSupervisor.new([])
    fake_lock_file = FakeLockFile.new([])
    original_file_open = File.method(:open)

    with_replaced_singleton_method(Hive::Config, :telegram_bot_token!, -> { "test-token" }) do
      with_replaced_singleton_method(Hive::Bot::Supervisor, :new, ->(**_kwargs) { supervisor }) do
        with_replaced_singleton_method(File, :open, lambda { |path, *args, &block|
          if path == command.pid_file && args.first == (File::RDWR | File::CREAT)
            fake_lock_file
          else
            original_file_open.call(path, *args, &block)
          end
        }) do
          command.call
        end
      end
    end

    assert_equal [ :run_forever ], supervisor.calls
    assert_includes fake_lock_file.calls, :close
  end

  def test_stop_text_when_not_running_warns_and_removes_stale_pid_file
    command = configured_bot("stop")
    write_pid_payload(command, pid: 9999)
    command.define_singleton_method(:live_pid) { nil }

    out, err = capture_io { command.call }

    assert_empty out
    assert_includes err, "hive: bot not running"
    refute File.exist?(command.pid_file)
  end

  def test_stop_escalates_to_kill_when_pid_survives_grace_period
    command = configured_bot("stop")
    write_pid_payload(command, pid: 2468)
    command.define_singleton_method(:live_pid) { 2468 }
    alive_checks = [ true, true, true, false ]
    command.define_singleton_method(:pid_alive?) { |_pid| alive_checks.shift || false }
    command.define_singleton_method(:sleep) { |_seconds| true }
    signals = []
    base = Time.utc(2026, 5, 22, 12, 0, 0)
    times = [ base, base + 1, base + 1, base + 2, base + 7 ]

    with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
      with_replaced_singleton_method(Time, :now, -> { times.shift || base + 7 }) do
        capture_io { command.call }
      end
    end

    assert_equal [ [ "TERM", 2468 ], [ "KILL", 2468 ] ], signals
    refute File.exist?(command.pid_file)
  end

  def test_stop_removes_pid_file_when_term_finds_no_process
    command = configured_bot("stop")
    write_pid_payload(command, pid: 1357)
    command.define_singleton_method(:live_pid) { 1357 }

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      capture_io { command.call }
    end

    refute File.exist?(command.pid_file)
  end

  def test_status_text_tolerates_invalid_started_at
    command = configured_bot("status")
    write_pid_payload(command, pid: 1234, started_at: "not a timestamp")
    command.define_singleton_method(:pid_alive?) { |pid| pid == 1234 }

    out, _err = capture_io { command.call }

    assert_includes out, "hive bot: running (pid 1234, uptime s)"
  end

  def test_status_json_merges_service_state_fields
    command = configured_bot("status", json: true)
    command.define_singleton_method(:live_pid) { nil }
    # Inject a fake installer so the merged service-state fields are
    # deterministic and we exercise the merge, not the host's systemd.
    state = {
      "platform" => "linux",
      "unit_path" => "/home/u/.config/systemd/user/hive-bot.service",
      "service_installed" => true,
      "service_enabled" => false
    }
    fake = Struct.new(:state) do
      def service_state = state
    end.new(state)
    require "hive/commands/bot/service_installer"
    out, _err = with_replaced_singleton_method(
      Hive::Commands::Bot::ServiceInstaller, :new, ->(**_kwargs) { fake }
    ) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_equal "hive-bot-status", doc.fetch("schema")
    assert_equal true, doc.fetch("service_installed")
    assert_equal false, doc.fetch("service_enabled")
    assert_equal "/home/u/.config/systemd/user/hive-bot.service", doc.fetch("unit_path")
    # Existing fields must survive the merge.
    assert_equal false, doc.fetch("running")
    assert doc.key?("pid_file")
    assert doc.key?("log_file")

    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    assert_empty schema.validate(doc).map { |error| error["error"] }
  end

  def test_status_json_degrades_service_fields_to_null_when_probe_raises
    # A read-only status probe must never take down the running/pid
    # reporting. If service_state raises, the three service fields degrade
    # to null (the schema marks them required-but-nullable) and the envelope
    # still emits and validates.
    command = configured_bot("status", json: true)
    command.define_singleton_method(:live_pid) { nil }
    fake = Object.new
    fake.define_singleton_method(:service_state) { raise "probe blew up" }
    require "hive/commands/bot/service_installer"
    out, _err = with_replaced_singleton_method(
      Hive::Commands::Bot::ServiceInstaller, :new, ->(**_kwargs) { fake }
    ) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_nil doc.fetch("service_installed")
    assert_nil doc.fetch("service_enabled")
    assert_nil doc.fetch("unit_path")
    assert_equal false, doc.fetch("running")

    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    assert_empty schema.validate(doc).map { |error| error["error"] },
                 "null service fields must still validate against the required-but-nullable schema"
  end

  def test_tail_missing_log_warns_and_raises
    command = configured_bot("tail")

    _out, err = capture_io do
      error = assert_raises(Hive::Error) { command.call }
      assert_equal "bot log file missing", error.message
    end

    assert_includes err, "hive: bot log file not found at #{command.log_file}"
  end

  def test_tail_streams_appended_log_until_interrupted
    command = configured_bot("tail")
    FileUtils.mkdir_p(File.dirname(command.log_file))
    File.write(command.log_file, "")
    sleeps = 0
    command.define_singleton_method(:sleep) do |_seconds|
      sleeps += 1
      if sleeps == 1
        File.open(command.log_file, "a") { |file| file.write("ready\n") }
      else
        raise Interrupt
      end
    end

    out, _err = capture_io { command.call }

    assert_equal "ready\n", out
  end

  def test_pid_alive_reports_missing_process_and_permission_denied_process
    command = configured_bot("status")
    outcomes = [ Errno::ESRCH, Errno::EPERM ]

    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid|
      outcome = outcomes.shift
      raise outcome if outcome
    }) do
      refute command.send(:pid_alive?, 1)
      assert command.send(:pid_alive?, 2)
    end
  end

  # ── install: routing, success summary, envelopes, exit codes ───────────

  # The install! block returns the raw outcome kind (or raises); stub_installer
  # wraps a returned kind in a real ServiceInstaller::Outcome so the command
  # layer exercises the actual value object, and bakes backup_path/restarted
  # onto it (these now live on the Outcome, not the installer).
  def stub_installer(messages: [], backup_path: nil, restarted: false,
                     target_path: "/tmp/hive-bot.service", envelope_platform: "linux", &install)
    require "hive/commands/service_installer/outcome"
    installer = FakeInstaller.new(
      target_path: target_path,
      envelope_platform: envelope_platform,
      messages: messages
    )
    installer.define_singleton_method(:install!) do |autostart:, force:|
      kind = install.call(autostart: autostart, force: force)
      Hive::Commands::ServiceInstaller::Outcome.new(kind, backup_path: backup_path, restarted: restarted)
    end
    installer
  end

  def run_install(command, installer)
    require "hive/commands/bot/service_installer"
    with_replaced_singleton_method(Hive::Commands::Bot::ServiceInstaller, :new, ->(**_kwargs) { installer }) do
      yield
    end
  end

  def test_install_written_text_prints_summary_and_warns_messages
    command = bot("install")
    installer = stub_installer(messages: [ "installed by fake" ]) { |autostart:, force:| :written }

    out, err = run_install(command, installer) { capture_io { command.call } }

    assert_includes err, "hive: installed by fake"
    assert_includes out, "hive bot: installed unit at /tmp/hive-bot.service"
  end

  def test_install_written_json_emits_success_envelope
    command = bot("install", json: true)
    installer = stub_installer { |autostart:, force:| :written }

    out, _err = run_install(command, installer) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_equal "hive-bot-install", doc.fetch("schema")
    assert_equal true, doc.fetch("ok")
    assert_equal "written", doc.fetch("outcome")
    assert_equal "linux", doc.fetch("platform")
    assert_equal "/tmp/hive-bot.service", doc.fetch("target_path")
    assert_equal false, doc.fetch("restarted")
  end

  def test_install_unchanged_is_idempotent_success
    command = bot("install", json: true)
    installer = stub_installer { |autostart:, force:| :unchanged }

    out, _err = run_install(command, installer) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_equal true, doc.fetch("ok")
    assert_equal "unchanged", doc.fetch("outcome")
  end

  def test_install_upgraded_json_reports_backup_and_restart
    command = bot("install", json: true, force: true)
    installer = stub_installer(backup_path: "/tmp/hive-bot.service.bak", restarted: true) do |autostart:, force:|
      :upgraded
    end

    out, _err = run_install(command, installer) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_equal "upgraded", doc.fetch("outcome")
    assert_equal "/tmp/hive-bot.service.bak", doc.fetch("backup_path")
    assert_equal true, doc.fetch("restarted")
  end

  def test_install_drifted_without_force_exits_64_and_names_force_and_bak
    command = bot("install", json: true)
    installer = stub_installer(messages: [ "changed locally" ]) { |autostart:, force:| :drifted }

    out, _err = run_install(command, installer) do
      capture_io do
        error = assert_raises(Hive::BotInstallDriftError) { command.call }
        assert_equal Hive::ExitCodes::USAGE, error.exit_code
      end
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "drifted", doc.fetch("outcome")
    assert_equal "drifted", doc.fetch("error_kind")
    assert_equal Hive::ExitCodes::USAGE, doc.fetch("exit_code")
  end

  def test_install_drifted_text_message_names_force_and_bak
    command = bot("install")
    installer = stub_installer { |autostart:, force:| :drifted }

    run_install(command, installer) do
      capture_io do
        error = assert_raises(Hive::BotInstallDriftError) { command.call }
        assert_match(/hive bot install --force/, error.message)
        assert_match(/\.bak/, error.message)
      end
    end
  end

  def test_install_failed_exits_70_with_error_envelope
    command = bot("install", json: true)
    installer = stub_installer { |autostart:, force:| :failed }

    out, _err = run_install(command, installer) do
      capture_io do
        error = assert_raises(Hive::BotInstallFailed) { command.call }
        assert_equal Hive::ExitCodes::SOFTWARE, error.exit_code
      end
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "failed", doc.fetch("outcome")
    assert_equal "BotInstallFailed", doc.fetch("error_class")
    assert_equal Hive::ExitCodes::SOFTWARE, doc.fetch("exit_code")
  end

  def test_install_unsupported_exits_0_with_warning
    command = bot("install")
    installer = stub_installer(messages: [ "bot autostart not supported on this platform" ]) do |autostart:, force:|
      :unsupported
    end

    _out, err = run_install(command, installer) { capture_io { command.call } }

    assert_includes err, "hive: bot autostart not supported on this platform"
  end

  def test_install_autostart_unavailable_exits_0_and_preserves_target_path
    command = bot("install", json: true)
    installer = stub_installer(
      target_path: "/home/u/.config/systemd/user/hive-bot.service",
      messages: [ "systemd not detected; bot unit was written but autostart was not enabled." ]
    ) { |autostart:, force:| :autostart_unavailable }

    out, _err = run_install(command, installer) { capture_io { command.call } }

    doc = JSON.parse(out)
    assert_equal true, doc.fetch("ok")
    assert_equal "unsupported", doc.fetch("outcome")
    assert_equal "/home/u/.config/systemd/user/hive-bot.service", doc.fetch("target_path"),
                 "a written-but-not-enabled unit must still report where it lives"
  end

  def test_install_json_wraps_unexpected_exceptions
    command = bot("install", json: true)
    installer = stub_installer(messages: [ "before write" ]) do |autostart:, force:|
      raise Errno::EACCES, "denied"
    end

    out, _err = run_install(command, installer) do
      capture_io { assert_raises(Hive::BotInstallFailed) { command.call } }
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "failed", doc.fetch("outcome")
    assert_equal "BotInstallFailed", doc.fetch("error_class")
    assert_match(/Errno::EACCES/, doc.fetch("message"))
    assert_equal [ "before write" ], doc.fetch("messages")
  end

  def test_install_reraises_hive_errors_without_exception_envelope
    command = bot("install", json: true)
    installer = stub_installer do |autostart:, force:|
      raise Hive::BotInstallFailed, "already wrapped"
    end

    out, _err = run_install(command, installer) do
      capture_io { assert_raises(Hive::BotInstallFailed) { command.call } }
    end

    assert_equal "", out
  end

  # Integration-style: drive the real command (only the installer stubbed)
  # and validate every emitted envelope against the published schema.
  def test_install_envelopes_validate_against_schema
    require "json_schemer"
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-install"))))

    success_cases = {
      written: "written",
      upgraded: "upgraded",
      unchanged: "unchanged",
      unsupported: "unsupported",
      autostart_unavailable: "unsupported"
    }
    success_cases.each do |result, outcome|
      command = bot("install", json: true, force: result == :upgraded)
      installer = stub_installer(
        backup_path: result == :upgraded ? "/tmp/hive-bot.service.bak" : nil,
        restarted: result == :upgraded
      ) { |autostart:, force:| result }

      out, _err = run_install(command, installer) { capture_io { command.call } }
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors, "#{result} envelope must validate against hive-bot-install.v1; got: #{errors.inspect}"
      assert_equal outcome, doc.fetch("outcome")
    end

    error_cases = { drifted: Hive::BotInstallDriftError, failed: Hive::BotInstallFailed }
    error_cases.each do |result, error_class|
      command = bot("install", json: true)
      installer = stub_installer { |autostart:, force:| result }

      out, _err = run_install(command, installer) do
        capture_io { assert_raises(error_class) { command.call } }
      end
      doc = JSON.parse(out)
      errors = schema.validate(doc).map { |e| e["error"] }
      assert_empty errors, "#{result} envelope must validate against hive-bot-install.v1; got: #{errors.inspect}"
      assert_equal result.to_s, doc.fetch("outcome")
    end
  end

  # ── install: non-JSON text summary per outcome ─────────────────────────

  def test_install_upgraded_text_summary_names_backup
    command = bot("install", force: true)
    installer = stub_installer(backup_path: "/tmp/hive-bot.service.bak-20260527") do |autostart:, force:|
      :upgraded
    end

    out, _err = run_install(command, installer) { capture_io { command.call } }

    assert_includes out, "hive bot: upgraded unit at /tmp/hive-bot.service"
    assert_includes out, "(backup: /tmp/hive-bot.service.bak-20260527)"
  end

  def test_install_unchanged_text_summary
    command = bot("install")
    installer = stub_installer { |autostart:, force:| :unchanged }

    out, _err = run_install(command, installer) { capture_io { command.call } }

    assert_includes out, "hive bot: unit already up to date at /tmp/hive-bot.service"
  end

  def test_install_autostart_unavailable_text_summary
    command = bot("install")
    installer = stub_installer(
      target_path: "/home/u/.config/systemd/user/hive-bot.service"
    ) { |autostart:, force:| :autostart_unavailable }

    out, _err = run_install(command, installer) { capture_io { command.call } }

    assert_includes out,
                    "hive bot: unit written at /home/u/.config/systemd/user/hive-bot.service; " \
                    "autostart not enabled on this host"
  end

  # ── install: safe_install_* rescue fallbacks on a hostile installer ────

  # An installer that raises a non-Hive error from install! AND whose
  # envelope_platform/target_path/messages accessors also raise. The
  # exception-envelope path must still emit valid JSON by falling back to
  # "unsupported" / nil / [] rather than crashing while reporting a crash.
  def test_install_exception_envelope_survives_hostile_installer_accessors
    command = bot("install", json: true)
    installer = stub_installer { |autostart:, force:| raise Errno::EACCES, "denied" }
    installer.define_singleton_method(:envelope_platform) { raise "boom platform" }
    installer.define_singleton_method(:target_path) { raise "boom target" }
    installer.define_singleton_method(:messages) { raise "boom messages" }

    out, _err = run_install(command, installer) do
      capture_io { assert_raises(Hive::BotInstallFailed) { command.call } }
    end

    doc = JSON.parse(out)
    assert_equal false, doc.fetch("ok")
    assert_equal "failed", doc.fetch("outcome")
    assert_equal "unsupported", doc.fetch("platform"),
                 "a raising envelope_platform must fall back to \"unsupported\""
    assert_nil doc.fetch("target_path"),
               "a raising target_path must fall back to nil"
    assert_equal [], doc.fetch("messages"),
                 "raising messages must fall back to an empty list"
  end

  # A closed stdout (broken pipe) while writing the --json usage-error
  # envelope must be swallowed, not surface a raw Errno::EPIPE: the operator
  # still gets the InvalidTaskPath usage failure, just without the JSON line
  # the dead pipe could no longer carry. Covers emit_usage_error's
  # `rescue Errno::EPIPE, JSON::GeneratorError` arm.
  def test_emit_usage_error_swallows_broken_pipe
    command = bot("status", json: true)
    command.define_singleton_method(:puts_json) { |_payload| raise Errno::EPIPE, "closed pipe" }

    assert_nil command.send(
      :emit_usage_error,
      Hive::InvalidTaskPath.new("hive bot: boom"),
      error_kind: "unknown_subcommand"
    )
  end
end
