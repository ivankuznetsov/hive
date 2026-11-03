require "test_helper"
require "hive/user_service/execution_environment"
require "hive/commands/service_installer/base"

class UserServiceExecutionEnvironmentTest < Minitest::Test
  include HiveTestHelper

  def test_stopped_services_reconstruct_independent_declared_paths_without_shell_overrides
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, <<~UNIT)
        [Service]
        Environment="PATH=%h/daemon tools:/usr/bin" CODEX_BIN=%h/old/codex SECRET=sk-abcdefghijklmnopqrstuvwxyz123456
        ExecStart=/fixture/hive daemon start
      UNIT
      write(definitions.fetch("babysitter").target_path, <<~UNIT)
        [Service]
        Environment=PATH=%h/babysitter:/usr/bin
        ExecStart=/fixture/hive babysit start
      UNIT
      with_env("CODEX_BIN" => "/shell-only/codex", "PATH" => "/shell-only") do
        contexts = reader(home, definitions: definitions).call
        assert_equal [ "daemon", "babysitter" ], contexts.map(&:label)
        assert_equal "#{home}/daemon tools:/usr/bin", contexts.first.environment.fetch("PATH")
        assert_equal "#{home}/old/codex", contexts.first.environment.fetch("CODEX_BIN")
        assert_equal "#{home}/babysitter:/usr/bin", contexts.last.environment.fetch("PATH")
        refute contexts.last.environment.key?("CODEX_BIN")
        assert contexts.all?(&:complete?)
        assert contexts.all? { |context| context.running_currency == :stopped }
        assert contexts.all? { |context| context.cwd == home && context.cwd_provenance == :inherited }
        refute_includes contexts.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
      end
    end
  end

  def test_dropins_reset_and_environment_files_follow_systemd_precedence
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      daemon = definitions.fetch("daemon")
      write(daemon.target_path, <<~UNIT)
        [Service]
        Environment=PATH=/initial CODEX_BIN=/initial/codex
        EnvironmentFile=%h/first.env
        ExecStart=/fixture/hive daemon start
      UNIT
      write(File.join(home, "first.env"), "PATH=/obsolete\n")
      write(File.join(home, "actual.env"), "PATH=\"/env file:/usr/bin\"\nCODEX_BIN=/env/codex\nAPI_KEY=sk-abcdefghijklmnopqrstuvwxyz123456\n")
      write(daemon.target_path + ".d/10-reset.conf", <<~UNIT)
        [Service]
        Environment=
        Environment=PATH=/after-reset CODEX_BIN=/dropin/codex
        EnvironmentFile=
        EnvironmentFile=-%h/missing.env %h/actual.env
        WorkingDirectory=%h/project
      UNIT
      write(daemon.target_path + ".d/20-final.conf", <<~UNIT)
        [Service]
        Environment=PATH=/last-assignment
      UNIT
      result = reader(home, definitions: definitions).call.first
      assert result.complete?, result.reasons.inspect
      assert_equal "/env file:/usr/bin", result.environment.fetch("PATH")
      assert_equal "/env/codex", result.environment.fetch("CODEX_BIN")
      assert_equal "#{home}/project", result.cwd
      assert_equal :declared, result.cwd_provenance
      assert_equal 4, result.sources.length
      refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
    end
  end

  def test_dropin_filename_shadowing_and_unset_environment
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      daemon = definitions.fetch("daemon")
      write(daemon.target_path, "[Service]\nEnvironment=PATH=/base CODEX_BIN=/old\nExecStart=/fixture/hive\n")
      lower = File.join(home, "vendor")
      write(File.join(lower, "hive-daemon.service.d/10-path.conf"), "[Service]\nEnvironment=PATH=/wrong\n")
      write(daemon.target_path + ".d/10-path.conf", "[Service]\nEnvironment=PATH=/right\nUnsetEnvironment=CODEX_BIN=/old\n")
      result = reader(home, definitions: definitions, systemd_roots: [ lower, File.dirname(daemon.target_path) ]).call.first
      assert result.complete?
      assert_equal "/right", result.environment.fetch("PATH")
      refute result.environment.key?("CODEX_BIN")
      refute result.sources.any? { |source| source[:path].start_with?(lower) }
    end
  end

  def test_required_environment_file_and_unsupported_activation_remain_incomplete
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      daemon = definitions.fetch("daemon")
      write(daemon.target_path, <<~UNIT)
        [Service]
        Environment=PATH=%q/bin CODEX_BIN=/plain
        EnvironmentFile=%h/required.env
        PassEnvironment=CODEX_BIN
        ExecStart=/bin/bash -lc 'eval activation; hive daemon start'
      UNIT
      result = reader(home, definitions: definitions).call.first
      assert result.installed?
      refute result.complete?
      refute result.probe_allowed?
      assert_includes codes(result), :unsupported_specifier
      assert_includes codes(result), :required_source_missing
      assert_includes codes(result), :inherited_environment_unresolved
      assert_includes codes(result), :opaque_service_wrapper
      assert_includes codes(result), :path_unresolved
      assert result.reasons.all? { |reason| reason[:path] && !reason.key?(:message) }
    end
  end

  def test_absent_and_unreadable_installations_are_distinct
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      FileUtils.mkdir_p(definitions.fetch("daemon").target_path)
      contexts = reader(home, definitions: definitions).call
      assert_equal :indeterminate, contexts.first.installation
      assert_includes codes(contexts.first), :source_not_regular
      assert contexts.last.absent?
    end
  end

  def test_launchd_only_uses_named_environment_dictionary_and_positional_precheck
    with_tmp_dir do |home|
      definitions = definitions_for(home, :macos)
      write(definitions.fetch("daemon").target_path, plist(<<~XML))
        <key>OtherArray</key><array><string>PATH=/wrong</string><string>CODEX_BIN=/wrong</string></array>
        <key>EnvironmentVariables</key><dict><key>PATH</key><string>/daemon:/usr/bin</string><key>HOME</key><string>/service-home</string><key>SECRET</key><string>sk-abcdefghijklmnopqrstuvwxyz123456</string></dict>
        <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>[ -x &quot;$0&quot; ] || exit 0; exec &quot;$0&quot; &quot;$@&quot;</string><string>/renamed/hv</string><string>daemon</string><string>start</string></array>
      XML
      write(definitions.fetch("babysitter").target_path, plist(<<~XML))
        <key>EnvironmentVariables</key><dict><key>PATH</key><string>/babysitter:/usr/bin</string></dict>
        <key>WorkingDirectory</key><string>/declared/project</string>
        <key>Program</key><string>/fixture/hive</string>
      XML
      contexts = reader(home, definitions: definitions).call
      assert contexts.all?(&:complete?), contexts.map(&:reasons).inspect
      assert_equal "/daemon:/usr/bin", contexts.first.environment.fetch("PATH")
      assert_equal "/service-home", contexts.first.environment.fetch("HOME")
      refute contexts.first.environment.key?("CODEX_BIN")
      assert_equal :inherited, contexts.first.cwd_provenance
      assert_equal "/declared/project", contexts.last.cwd
      assert_equal :declared, contexts.last.cwd_provenance
      refute_includes contexts.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
    end
  end

  def test_malformed_launchd_xml_never_returns_parser_text_or_secrets
    with_tmp_dir do |home|
      definitions = definitions_for(home, :macos)
      write(definitions.fetch("daemon").target_path, '<plist><dict>sk-abcdefghijklmnopqrstuvwxyz123456')
      result = reader(home, definitions: definitions).call.first
      assert result.installed?
      assert_includes codes(result), :malformed_plist
      refute result.complete?
      refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
    end
  end

  def test_launchd_program_selects_the_executable_instead_of_the_argument_zero_alias
    with_tmp_dir do |home|
      definitions = definitions_for(home, :macos)
      write(definitions.fetch("daemon").target_path, plist(<<~XML))
        <key>EnvironmentVariables</key><dict><key>PATH</key><string>/declared</string></dict>
        <key>Program</key><string>/bin/sh</string>
        <key>ProgramArguments</key><array><string>/fixture/hive</string><string>-c</string><string>opaque activation</string></array>
      XML
      result = reader(home, definitions: definitions).call.first
      assert result.installed?
      assert_includes codes(result), :opaque_service_wrapper
      refute result.complete?
      refute result.probe_allowed?
    end
  end

  def test_changed_dropins_and_environment_files_make_running_linux_evidence_stale
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      daemon = definitions.fetch("daemon")
      envfile = File.join(home, "service.env")
      dropin = daemon.target_path + ".d/10-environment.conf"
      write(daemon.target_path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      write(dropin, "[Service]\nEnvironmentFile=%h/service.env\n")
      write(envfile, "CODEX_BIN=/service/codex\n")
      started = Time.now - 120
      sources = [ daemon.target_path, dropin, envfile ]
      status_reader = ->(definition) {
        status(definition, running: true, main_pid: 123, process_start: started.iso8601(6))
      }
      [ dropin, envfile ].each do |changed|
        sources.each { |source| File.utime(started - 60, started - 60, source) }
        File.utime(started + 60, started + 60, changed)
        result = reader(home, definitions: definitions, status_reader: status_reader).call.first
        assert result.complete?, result.reasons.inspect
        assert_equal :stale, result.running_currency, changed
        refute result.probe_allowed?
      end
    end
  end

  def test_modified_sources_warn_for_both_platforms_and_stopped_units_are_declared
    [ :linux, :macos ].each do |platform|
      with_tmp_dir do |home|
        definitions = definitions_for(home, platform)
        daemon = definitions.fetch("daemon")
        content = platform == :linux ? "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n" :
          plist('<key>EnvironmentVariables</key><dict><key>PATH</key><string>/bin</string></dict><key>Program</key><string>/fixture/hive</string>')
        write(daemon.target_path, content)
        started = Time.now - 120
        File.utime(started + 60, started + 60, daemon.target_path)
        status_reader = ->(definition) do
          status(definition, running: true, main_pid: 123, process_start: started.iso8601(6))
        end
        result = reader(home, definitions: definitions, status_reader: status_reader).call.first
        assert result.complete?
        assert_equal :stale, result.running_currency
        refute result.probe_allowed?
        File.utime(started - 60, started - 60, daemon.target_path)
        result = reader(home, definitions: definitions, status_reader: status_reader).call.first
        assert_equal :current, result.running_currency
        assert result.probe_allowed?
      end
    end
  end

  def test_unknown_process_start_and_pending_reload_cannot_be_probed
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      daemon = definitions.fetch("daemon")
      write(daemon.target_path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      unknown = reader(home, definitions: definitions, status_reader: ->(definition) {
        status(definition, running: true, main_pid: 123)
      }).call.first
      assert_equal :unknown, unknown.running_currency
      refute unknown.probe_allowed?
      stale = reader(home, definitions: definitions, status_reader: ->(definition) {
        status(definition, running: true, main_pid: 123, need_daemon_reload: true)
      }).call.first
      assert_equal :stale, stale.running_currency
      refute stale.probe_allowed?
    end
  end

  def test_manager_metadata_selects_effective_fragment_and_dropins_without_lifecycle_calls
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      fragment = File.join(home, "actual.service")
      dropin = File.join(home, "actual.d/path.conf")
      write(fragment, "[Service]\nEnvironment=PATH=/first\nExecStart=/fixture/hive\n")
      write(dropin, "[Service]\nEnvironment=PATH=/effective\n")
      calls = []
      runner = ->(argv, timeout:) do
        calls << [ argv, timeout ]
        next { ok: true, output: "" } if argv.include?("show-environment")
        { ok: true, output: "FragmentPath=#{fragment}\nDropInPaths=#{dropin}\nLoadState=loaded\nNeedDaemonReload=no\nActiveState=inactive\nMainPID=0\nExecMainStartTimestampMonotonic=0\n" }
      end
      result = reader(home, definitions: definitions, status_reader: nil, manager_runner: runner).call.first
      assert_equal "/effective", result.environment.fetch("PATH")
      assert result.complete?
      assert_equal :stopped, result.running_currency
      assert calls.all? { |argv, timeout| argv[0, 2] == %w[systemctl --user] && %w[show show-environment].include?(argv[2]) && timeout <= 5 }
    end
  end

  def test_manager_unavailability_keeps_offline_evidence_and_typed_incompleteness
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/offline\nExecStart=/fixture/hive\n")
      result = reader(home, definitions: definitions, status_reader: nil, manager_runner: ->(*) {
        { ok: false, failure: :manager_timeout, output: "sk-abcdefghijklmnopqrstuvwxyz123456" }
      }).call.first
      assert result.installed?
      assert_equal "/offline", result.environment.fetch("PATH")
      assert_equal :unknown, result.running_currency
      assert_includes codes(result), :manager_timeout
      refute result.probe_allowed?
      refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
    end
  end

  def test_transitional_systemd_units_are_not_mistaken_for_stopped_services
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      %w[activating deactivating reloading].each do |active_state|
        runner = ->(argv, timeout:) do
          next { ok: true, output: "" } if argv.include?("show-environment")
          { ok: true, output: "LoadState=loaded\nNeedDaemonReload=no\nActiveState=#{active_state}\nMainPID=0\n" }
        end
        result = reader(home, definitions: definitions, status_reader: nil, manager_runner: runner).call.first
        assert result.complete?, result.reasons.inspect
        assert_equal :unknown, result.running_currency, active_state
        refute result.probe_allowed?, active_state
      end
    end
  end

  def test_manager_budget_is_shared_by_services
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      now = 100.0
      calls = []
      runner = ->(argv, timeout:) { calls << timeout; now += 10; { ok: false, failure: :manager_timeout } }
      result = reader(home, definitions: definitions, status_reader: nil, manager_runner: runner,
        monotonic: -> { now }).call
      assert_equal [ 5.0 ], calls
      assert_includes codes(result.last), :manager_budget_exhausted
    end
  end

  def test_environment_files_preserve_literal_whitespace_quotes_dollars_and_continuations
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/base\nEnvironmentFile=%h/values.env\nExecStart=/fixture/hive\n")
      write(File.join(home, "values.env"), <<~'ENVFILE')
        PATH= /two  spaces:/literal"quote":/dollar$PATH:/continued\
        /line
        CODEX_BIN='/single quoted/codex'
      ENVFILE
      result = reader(home, definitions: definitions).call.first
      assert result.complete?, result.reasons.inspect
      assert_equal '/two  spaces:/literal"quote":/dollar$PATH:/continued/line', result.environment.fetch("PATH")
      assert_equal '/single quoted/codex', result.environment.fetch("CODEX_BIN")
    end
  end

  def test_known_shell_launcher_wrapper_does_not_silently_inherit_its_path_changes
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      launcher = File.join(home, "hive-wrapper")
      write(launcher, "#!/bin/sh\nexport PATH=/different:$PATH\nexec /fixture/hive \"$@\"\n")
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/declared\nExecStart=#{launcher} daemon start\n")
      result = reader(home, definitions: definitions).call.first
      assert result.installed?
      refute result.complete?
      assert_includes codes(result), :opaque_service_wrapper
      refute result.probe_allowed?
    end
  end

  def test_packaged_launcher_exports_leave_declared_resolution_environment_complete
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      launcher = File.join(home, "hive-wrapper")
      write(launcher, <<~SH)
        #!/bin/sh
        export GEM_HOME=/packaged/gems
        export GEM_PATH=/packaged/gems
        export HIVE_INVOKED_BIN=/packaged/hive
        exec "/fixture/hive" "$@"
      SH
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/declared\nExecStart=#{launcher} daemon start\n")
      result = reader(home, definitions: definitions).call.first
      assert result.complete?, result.reasons.inspect
      assert_equal "/declared", result.environment.fetch("PATH")
      refute result.environment.key?("GEM_HOME")
      assert result.probe_allowed?
    end
  end

  def test_context_and_every_nested_public_value_are_frozen
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      contexts = reader(home, definitions: definitions).call
      assert contexts.frozen?
      assert contexts.first.frozen?
      assert contexts.first.environment.frozen?
      assert contexts.first.sources.all?(&:frozen?)
      assert contexts.last.reasons.all?(&:frozen?)
      assert_raises(FrozenError) { contexts.first.environment.fetch("PATH") << "changed" }
    end
  end

  def test_manager_environment_is_allowlisted_and_installed_overrides_win
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/declared\nExecStart=/fixture/hive\n")
      calls = []
      runner = ->(argv, timeout:) do
        calls << argv
        if argv.include?("show-environment")
          { ok: true, output: "PATH=/inherited\nCODEX_BIN=/manager/codex\nSECRET=sk-abcdefghijklmnopqrstuvwxyz123456\n" }
        else
          { ok: false, failure: :manager_unavailable }
        end
      end
      result = reader(home, definitions: definitions, status_reader: nil, manager_runner: runner).call.first
      assert_equal "/declared", result.environment.fetch("PATH")
      assert_equal "/manager/codex", result.environment.fetch("CODEX_BIN")
      refute result.environment.key?("SECRET")
      refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
      assert_equal 1, calls.count { |argv| argv.include?("show-environment") }
    end
  end

  def test_launchd_manager_environment_and_loaded_job_are_read_without_lifecycle_changes
    with_tmp_dir do |home|
      definitions = definitions_for(home, :macos)
      write(definitions.fetch("daemon").target_path, plist('<key>EnvironmentVariables</key><dict><key>PATH</key><string>/declared</string></dict><key>Program</key><string>/fixture/hive</string>'))
      calls = []
      runner = ->(argv, timeout:) do
        calls << argv
        if argv.last == "gui/#{Process.uid}"
          { ok: true, output: "environment = {\n CODEX_BIN => /manager/codex\n SECRET => sk-abcdefghijklmnopqrstuvwxyz123456\n}\n" }
        else
          { ok: true, output: "state = running\npid = 123\n" }
        end
      end
      result = reader(home, definitions: definitions, status_reader: nil, manager_runner: runner).call.first
      assert result.complete?, result.reasons.inspect
      assert_equal "/manager/codex", result.environment.fetch("CODEX_BIN")
      assert_equal :unknown, result.running_currency
      refute result.probe_allowed?
      assert calls.all? { |argv| argv[0, 2] == %w[launchctl print] }
      refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
    end
  end

  def test_agent_identity_collision_never_runs_manager_helpers_even_through_hardlinks
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      helper = File.join(home, "systemctl")
      agent = File.join(home, "agent")
      write(helper, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, helper)
      File.link(helper, agent)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=#{home} CODEX_BIN=#{agent}\nExecStart=/fixture/hive\n")
      profile = Struct.new(:env_bin_override_keys) do
        def bin(env:) = env.fetch("CODEX_BIN", "agent")
      end.new([ "CODEX_BIN" ])
      calls = []
      with_env("PATH" => home) do
        result = reader(home, definitions: definitions, profiles: [ profile ], status_reader: nil,
          manager_runner: ->(*) { calls << :launched; { ok: true, output: "" } }).call.first
        assert_empty calls
        assert_includes codes(result), :manager_agent_identity_collision
        assert_equal agent, result.environment.fetch("CODEX_BIN")
        refute result.probe_allowed?
      end
    end
  end

  def test_bounded_sources_do_not_read_fifos_or_oversized_files
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      path = definitions.fetch("daemon").target_path
      FileUtils.mkdir_p(File.dirname(path))
      File.mkfifo(path)
      result = reader(home, definitions: definitions).call.first
      assert_equal :indeterminate, result.installation
      assert_includes codes(result), :source_not_regular
      File.unlink(path)
      write(path, "x" * (Hive::UserService::ExecutionEnvironment::MAX_SOURCE_BYTES + 1))
      result = reader(home, definitions: definitions).call.first
      assert_includes codes(result), :source_too_large
    end
  end

  def test_raw_selection_inputs_are_preserved_while_diagnostic_serialization_redacts
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/bin CODEX_BIN=/#{secret}/codex\nExecStart=/fixture/hive\n")
      result = reader(home, definitions: definitions).call.first
      assert_equal "/#{secret}/codex", result.environment.fetch("CODEX_BIN")
      refute_includes result.to_h.inspect, secret
      refute_includes result.inspect, secret
    end
  end

  def test_explicit_installer_definitions_read_absence_without_creating_service_paths
    [ :linux, :macos ].each do |platform|
      with_tmp_dir do |home|
        definitions = Hive::Commands::ServiceInstaller::Base.execution_definitions(
          home: home, host_os: platform == :linux ? "linux" : "darwin"
        )
        result = Hive::UserService::ExecutionEnvironment.new(project_root: home, home: home,
          profiles: [], platform: platform, definitions: definitions,
          status_reader: ->(definition) { status(definition) }).call
        assert_equal %w[daemon babysitter bot web], result.map(&:label)
        assert result.all?(&:absent?)
        refute Dir.exist?(File.join(home, ".config"))
        refute Dir.exist?(File.join(home, "Library"))
      end
    end
  end

  def test_installer_generated_service_definitions_reconstruct_on_both_platforms
    require "hive/commands/daemon/service_installer"
    require "hive/commands/babysit/service_installer"
    require "hive/commands/bot/service_installer"
    require "hive/commands/web/service_installer"
    [ :linux, :macos ].each do |platform|
      with_tmp_dir do |root|
        home = File.join(root, "service home")
        FileUtils.mkdir_p(home)
        definitions = {
          "daemon" => Hive::Commands::Daemon::ServiceInstaller,
          "babysitter" => Hive::Commands::Babysit::ServiceInstaller,
          "bot" => Hive::Commands::Bot::ServiceInstaller,
          "web" => Hive::Commands::Web::ServiceInstaller
        }.transform_values do |installer_class|
          options = { home: home, host_os: platform == :linux ? "linux" : "darwin",
                      binary_path: File.join(home, "bin/hive"), environment: {} }
          options[:config] = { "bind" => "127.0.0.1", "port" => 3000 } if installer_class == Hive::Commands::Web::ServiceInstaller
          installer = installer_class.new(**options)
          installer.define_singleton_method(:ruby_shim_dir) { "%h/.local/share/mise/shims" }
          definition = installer.service_definition
          write(definition.target_path, definition.content)
          definition
        end
        contexts = reader(home, definitions: definitions).call
        assert contexts.all?(&:complete?), contexts.map(&:reasons).inspect
        assert contexts.all?(&:probe_allowed?)
        contexts.each do |context|
          assert_equal home, context.cwd
          expected_provenance = platform == :macos && context.label == "web" ? :declared : :inherited
          assert_equal expected_provenance, context.cwd_provenance
        end
        expected_path = platform == :linux ? "#{home}/.local/bin:#{home}/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin" :
          "#{home}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        expected_paths = [ expected_path ] * 4
        expected_paths[-1] = "#{home}/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" if platform == :macos
        assert_equal expected_paths, contexts.map { |context| context.environment.fetch("PATH") }
      end
    end
  end

  def test_stopped_bot_and_web_services_use_their_declared_environments_on_both_platforms
    [ :linux, :macos ].each do |platform|
      with_tmp_dir do |home|
        definitions = definitions_for(home, platform, names: %w[bot web])
        definitions.each do |label, definition|
          content = if platform == :linux
            "[Service]\nEnvironment=PATH=%h/#{label} CODEX_BIN=%h/#{label}/codex\nExecStart=/fixture/hive #{label}\n"
          else
            plist(<<~XML)
              <key>EnvironmentVariables</key><dict><key>PATH</key><string>#{home}/#{label}</string><key>CODEX_BIN</key><string>#{home}/#{label}/codex</string></dict>
              <key>Program</key><string>/fixture/hive</string>
            XML
          end
          write(definition.target_path, content)
        end
        with_env("PATH" => "/shell", "CODEX_BIN" => "/shell/codex") do
          results = reader(home, definitions: definitions).call
          assert_equal %w[bot web], results.map(&:label)
          results.each do |result|
            assert result.installed?
            assert result.complete?, result.reasons.inspect
            assert_equal :stopped, result.running_currency
            assert result.probe_allowed?
            assert_equal "#{home}/#{result.label}", result.environment.fetch("PATH")
            assert_equal "#{home}/#{result.label}/codex", result.environment.fetch("CODEX_BIN")
          end
        end
      end
    end
  end

  def test_bot_startup_environment_file_adds_only_unset_resolution_keys_on_both_platforms
    [ :linux, :macos ].each do |platform|
      with_tmp_dir do |home|
        definitions = definitions_for(home, platform, names: [ "bot" ])
        startup_file = File.join(home, "bot-config/.env")
        settings = { "PATH" => "/service/bin", "HIVE_HOME" => File.dirname(startup_file),
                     "XDG_CONFIG_HOME" => File.join(home, "ignored-config") }
        write_service_settings(definitions.fetch("bot"), settings)
        secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        write(startup_file, <<~ENVFILE)
          # Bot startup uses first assignment and strips outer quotes.
          HIVE_HOME=#{home}/do-not-load
          XDG_CONFIG_HOME=#{home}/also-do-not-load
          CODEX_BIN='#{home}/file codex'
          CODEX_BIN=/ignored/duplicate
          PATH=/ignored/file-path
          SECRET=#{secret}
        ENVFILE
        write(File.join(home, "do-not-load/.env"), "CODEX_BIN=/wrong/recursive-codex\n")
        result = reader(home, definitions: definitions).call.first
        assert result.complete?, result.reasons.inspect
        assert_equal "#{home}/file codex", result.environment.fetch("CODEX_BIN")
        assert_equal "/service/bin", result.environment.fetch("PATH")
        assert_equal %w[CODEX_BIN HOME PATH], result.environment.keys.sort
        assert result.sources.any? { |source| source[:path] == startup_file }
        refute_includes result.inspect, secret
        assert result.probe_allowed?
      end
    end
  end

  def test_bot_startup_file_uses_service_home_and_xdg_config_with_existing_override_precedence
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux, names: [ "bot" ])
      other_home = File.join(home, "service-home")
      xdg = File.join(home, "service-config")
      settings = { "HOME" => other_home, "PATH" => "/bin", "CODEX_BIN" => "" }
      files = [ [ {}, File.join(other_home, ".config/hive/.env") ],
                [ { "XDG_CONFIG_HOME" => xdg, "HIVE_HOME" => "" }, File.join(xdg, "hive/.env") ] ]
      files.each do |configuration, startup_file|
        write_service_settings(definitions.fetch("bot"), settings.merge(configuration))
        write(startup_file, "CODEX_BIN=/ignored/file-codex\nUNRELATED=value\n")
        with_env("HIVE_HOME" => "/shell-only", "XDG_CONFIG_HOME" => "/shell-only") do
          result = reader(home, definitions: definitions).call.first
          assert result.complete?, result.reasons.inspect
          assert_equal "", result.environment.fetch("CODEX_BIN")
          assert result.sources.any? { |source| source[:path] == startup_file }
          refute result.environment.key?("UNRELATED")
        end
      end
    end
  end

  def test_bot_startup_file_changes_make_running_evidence_stale_on_both_platforms
    [ :linux, :macos ].each do |platform|
      with_tmp_dir do |home|
        definitions = definitions_for(home, platform, names: [ "bot" ])
        definition = definitions.fetch("bot")
        write_service_settings(definition, { "PATH" => "/bin" })
        startup_file = File.join(home, ".config/hive/.env")
        write(startup_file, "CODEX_BIN=/bot/codex\n")
        started = Time.now - 120
        File.utime(started - 60, started - 60, definition.target_path)
        File.utime(started + 60, started + 60, startup_file)
        result = reader(home, definitions: definitions, status_reader: ->(service) {
          status(service, running: true, main_pid: 123, process_start: started.iso8601(6))
        }).call.first
        assert result.complete?, result.reasons.inspect
        assert_equal :stale, result.running_currency
        refute result.probe_allowed?
      end
    end
  end

  def test_bot_startup_file_locators_expand_only_the_reconstructed_service_home
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux, names: [ "bot" ])
      [ "~", "~/bot-config" ].each do |locator|
        write_service_settings(definitions.fetch("bot"), { "PATH" => "/bin", "HIVE_HOME" => locator })
        startup_file = File.join(home, locator.delete_prefix("~"), ".env")
        write(startup_file, "CODEX_BIN=/bot/codex\n")
        result = reader(home, definitions: definitions).call.first
        assert result.complete?, result.reasons.inspect
        assert_equal "/bot/codex", result.environment.fetch("CODEX_BIN")
        assert result.sources.any? { |source| source[:path] == startup_file }
      end
      [ "~another-user/bot", "bad\0path" ].each do |locator|
        write_service_settings(definitions.fetch("bot"), { "PATH" => "/bin" })
        result = reader(home, definitions: definitions, manager_environment: { "HIVE_HOME" => locator }).call.first
        assert_includes codes(result), :bot_environment_file_location_unresolved
        refute result.complete?
        refute result.probe_allowed?
      end
    end
  end

  def test_bot_startup_override_is_checked_before_running_a_manager_helper_with_agent_identity
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux, names: [ "bot" ])
      helper = File.join(home, "systemctl")
      agent = File.join(home, "codex")
      write(helper, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, helper)
      File.link(helper, agent)
      write_service_settings(definitions.fetch("bot"), { "PATH" => home })
      write(File.join(home, ".config/hive/.env"), "CODEX_BIN=#{agent}\n")
      profile = Struct.new(:env_bin_override_keys) do
        def bin(env:) = env.fetch("CODEX_BIN", "unconfigured-agent")
      end.new([ "CODEX_BIN" ])
      with_env("PATH" => home) do
        result = reader(home, definitions: definitions, profiles: [ profile ], status_reader: nil,
          manager_runner: ->(*) { flunk "manager helper has the bot's agent executable identity" }).call.first
        assert_includes codes(result), :manager_agent_identity_collision
        assert_equal agent, result.environment.fetch("CODEX_BIN")
        refute result.probe_allowed?
      end
    end
  end

  def test_unsupported_platform_and_broken_status_are_indeterminate
    with_tmp_dir do |home|
      definition = Hive::UserService::Definition.new(platform: :unsupported, service_name: "hive-daemon", target_path: nil, content: nil)
      result = Hive::UserService::ExecutionEnvironment.new(project_root: home, home: home,
        profiles: [], platform: :freebsd, definitions: { "daemon" => definition },
        manager_runner: ->(*) { flunk "unsupported platform queried manager" }).call.first
      assert_equal :indeterminate, result.installation
      assert_includes codes(result), :unsupported_platform
      definitions = definitions_for(home, :linux)
      result = reader(home, definitions: definitions, status_reader: ->(*) { raise IOError }).call.first
      assert_includes codes(result), :service_evidence_unavailable
    end
  end

  def test_invalid_utf8_and_unreadable_sources_are_indeterminate_without_raw_errors
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      path = definitions.fetch("daemon").target_path
      write(path, "\xff".b)
      assert_includes codes(reader(home, definitions: definitions).call.first), :source_encoding_invalid
      original = File.method(:open)
      replacement = ->(candidate, *args, **kwargs, &block) do
        raise Errno::EACCES, "sk-abcdefghijklmnopqrstuvwxyz123456" if candidate == path
        original.call(candidate, *args, **kwargs, &block)
      end
      with_replaced_singleton_method(File, :open, replacement) do
        result = reader(home, definitions: definitions).call.first
        assert_equal :indeterminate, result.installation
        assert_includes codes(result), :source_unreadable
        refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
      end
    end
  end

  def test_systemd_unsupported_and_malformed_directives_have_source_line_provenance
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      path = definitions.fetch("daemon").target_path
      cases = {
        "Environment=PATH\n" => :invalid_environment_assignment,
        "Environment=PATH='unterminated\n" => :malformed_quoted_value,
        "WorkingDirectory=relative\n" => :working_directory_unresolved,
        "RootDirectory=/different-root\n" => :unsupported_service_directive,
        "EnvironmentFile=relative.env\n" => :environment_file_unresolved,
        "MissingEquals\n" => :malformed_service_directive,
        "Environment=PATH=/base \\\n" => :malformed_service_directive
      }
      cases.each do |directive, expected|
        write(path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n#{directive}")
        result = reader(home, definitions: definitions).call.first
        assert_includes codes(result), expected, directive.inspect
        assert result.reasons.any? { |reason| reason[:code] == expected && reason[:line] == 4 }
      end
      write(path, "[Service]\nEnvironment=PATH=/literal%%/bin \\\n CODEX_BIN=/continued/codex\n")
      result = reader(home, definitions: definitions).call.first
      assert_equal "/literal%/bin", result.environment.fetch("PATH")
      assert_equal "/continued/codex", result.environment.fetch("CODEX_BIN")
      assert_includes codes(result), :service_launcher_unresolved
    end
  end

  def test_unclosed_environment_file_quote_is_unknown_and_does_not_expose_content
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/bin\nEnvironmentFile=%h/bad.env\nExecStart=/fixture/hive\n")
      write(File.join(home, "bad.env"), "CODEX_BIN='sk-abcdefghijklmnopqrstuvwxyz123456\n")
      result = reader(home, definitions: definitions).call.first
      assert_includes codes(result), :malformed_environment_file
      refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
    end
  end

  def test_invalid_named_plist_fields_are_unknown_independently_of_other_arrays
    with_tmp_dir do |home|
      definitions = definitions_for(home, :macos)
      path = definitions.fetch("daemon").target_path
      cases = {
        '<key>EnvironmentVariables</key><array/>' => :malformed_plist_environment,
        '<key>EnvironmentVariables</key><dict><key>PATH</key><integer>12</integer></dict>' => :malformed_plist_environment,
        '<key>WorkingDirectory</key><integer>12</integer>' => :working_directory_unresolved,
        '<key>Program</key><integer>12</integer><key>ProgramArguments</key><array><string>/fixture/hive</string></array>' => :service_launcher_unresolved,
        '<key>ProgramArguments</key><array><integer>12</integer></array>' => :service_launcher_unresolved,
        '<key>OnlyKey</key>' => :malformed_plist,
        '<string>WrongKey</string><string>value</string>' => :malformed_plist
      }
      cases.each do |body, expected|
        write(path, plist(body))
        assert_includes codes(reader(home, definitions: definitions).call.first), expected
      end
    end
  end

  def test_numeric_process_start_uses_monotonic_clock_and_invalid_start_stays_unknown
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      path = definitions.fetch("daemon").target_path
      write(path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      File.utime(Time.now - 60, Time.now - 60, path)
      [ [ "100000000", :stale ], [ "nonsense", :unknown ], [ "0", :unknown ] ].each do |started, expected|
        result = reader(home, definitions: definitions, monotonic: -> { 200.0 },
          status_reader: ->(definition) { status(definition, running: true, main_pid: 123, process_start: started) }).call.first
        assert_equal expected, result.running_currency
      end
    end
  end

  def test_explicit_manager_environment_and_offline_vendor_fragment_are_used
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      vendor = File.join(home, "vendor")
      write(File.join(vendor, "hive-daemon.service"), "[Service]\nEnvironment=\nEnvironment=PATH=/declared\nExecStart=/fixture/hive\n")
      result = reader(home, definitions: definitions, status_reader: ->(definition) {
        status(definition, fragment_path: nil)
      }, systemd_roots: [ vendor ], manager_environment: { "CODEX_BIN" => "/manager/codex", "SECRET" => "secret" },
        excluded_executables: [ File.join(home, "missing") ]).call.first
      assert result.installed?
      assert_equal "/manager/codex", result.environment.fetch("CODEX_BIN")
      refute result.environment.key?("SECRET")
    end
  end

  def test_invalid_manager_outputs_and_query_failures_are_typed
    with_tmp_dir do |home|
      [ :linux, :macos ].each do |platform|
        definitions = definitions_for(home, platform)
        body = platform == :linux ? "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n" :
          plist('<key>EnvironmentVariables</key><dict><key>PATH</key><string>/bin</string></dict><key>Program</key><string>/fixture/hive</string>')
        write(definitions.fetch("daemon").target_path, body)
        outputs = platform == :linux ? [ "PATH=one two", "FragmentPath=\nNeedDaemonReload=invalid\nDropInPaths='unclosed" ] :
          [ "missing environment block", "environment = {\n CODEX_BIN => \"opaque\"\n}\n" ]
        outputs.each do |output|
          result = reader(home, definitions: definitions, status_reader: nil,
            manager_runner: ->(*) { { ok: true, output: output } }).call.first
          refute result.probe_allowed?
        end
        result = reader(home, definitions: definitions, status_reader: nil,
          manager_runner: ->(*) { raise IOError, "sk-abcdefghijklmnopqrstuvwxyz123456" }).call.first
        assert_includes codes(result), :manager_unavailable
        refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
      end
    end
  end

  def test_production_manager_capture_is_bounded_and_cleans_up_its_process_group
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      helper = File.join(home, "systemctl")
      write(helper, <<~RUBY_HELPER)
        #!#{RbConfig.ruby}
        if ARGV.include?("show-environment")
          puts "PATH=/bin"
        else
          puts "LoadState=loaded\\nNeedDaemonReload=no\\nActiveState=inactive\\nMainPID=0\\nFragmentPath=\\nDropInPaths=\\n"
        end
      RUBY_HELPER
      File.chmod(0o755, helper)
      with_env("PATH" => home) do
        result = reader(home, definitions: definitions, status_reader: nil).call.first
        assert result.complete?, result.reasons.inspect
        assert_equal :stopped, result.running_currency
        write(helper, "#!#{RbConfig.ruby}\nSTDOUT.sync = true\nputs 'PATH=/bin'\nsleep 100\n")
        result = reader(home, definitions: definitions, status_reader: nil,
          monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 50 }).call.first
        assert_includes codes(result), :manager_timeout
        refute result.probe_allowed?
      end
    end
  end

  def test_unreadable_hive_launcher_keeps_declared_agent_path_with_typed_limitation
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      launcher = File.join(home, "hive-wrapper")
      write(launcher, "#!/bin/sh\nexec /fixture/hive \"$@\"\n")
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/declared\nExecStart=#{launcher} daemon start\n")
      original = File.method(:read)
      replacement = ->(path, *args, **kwargs, &block) do
        raise Errno::EACCES, "sk-abcdefghijklmnopqrstuvwxyz123456" if path == launcher
        original.call(path, *args, **kwargs, &block)
      end
      with_replaced_singleton_method(File, :read, replacement) do
        result = reader(home, definitions: definitions).call.first
        assert result.installed?
        assert_equal "/declared", result.environment.fetch("PATH")
        assert_includes codes(result), :service_launcher_unreadable
        refute_includes result.inspect, "sk-abcdefghijklmnopqrstuvwxyz123456"
        refute result.probe_allowed?
      end
    end
  end

  def test_manager_output_limit_marks_reconstruction_incomplete
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      helper = File.join(home, "systemctl")
      write(helper, "#!#{RbConfig.ruby}\nSTDOUT.sync = true\nloop { STDOUT.write('x' * 4096) }\n")
      File.chmod(0o755, helper)
      with_env("PATH" => home) do
        result = reader(home, definitions: definitions, status_reader: nil,
          monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 5 }).call.first
        assert_includes codes(result), :manager_output_limit
        refute result.probe_allowed?
      end
    end
  end

  def test_manager_output_written_at_process_exit_is_not_lost
    with_tmp_dir do |home|
      definitions = definitions_for(home, :linux)
      write(definitions.fetch("daemon").target_path, "[Service]\nEnvironment=PATH=/bin\nExecStart=/fixture/hive\n")
      helper = File.join(home, "systemctl")
      write(helper, "#!#{RbConfig.ruby}\nif ARGV.include?('show-environment')\nputs 'CODEX_BIN=/manager/codex'\nelse\nputs 'LoadState=loaded\\nActiveState=inactive\\nMainPID=0'\nend\n")
      File.chmod(0o755, helper)
      original_pipe = IO.method(:pipe)
      pipe = ->(*) do
        input, output = original_pipe.call
        read = input.method(:read_nonblock)
        first = true
        input.define_singleton_method(:read_nonblock) do |*args, **kwargs|
          if first
            first = false
            :wait_readable
          else
            read.call(*args, **kwargs)
          end
        end
        [ input, output ]
      end
      wait = Process.method(:wait2)
      with_env("PATH" => home) do
        with_replaced_singleton_method(IO, :pipe, pipe) do
          with_replaced_singleton_method(Process, :wait2, ->(pid, *) { wait.call(pid) }) do
            result = reader(home, definitions: definitions, status_reader: nil).call.first
            assert_equal "/manager/codex", result.environment["CODEX_BIN"]
          end
        end
      end
    end
  end

  def plist(content)
    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>#{content}</dict></plist>"
  end

  def codes(context)
    context.reasons.map { |reason| reason.fetch(:code) }
  end

  private

  def definitions_for(home, platform, names: %w[daemon babysitter])
    names.to_h do |name|
      path = if platform == :linux
        File.join(home, ".config/systemd/user/hive-#{name}.service")
      else
        File.join(home, "Library/LaunchAgents/local.hive-#{name}.plist")
      end
      [ name, Hive::UserService::Definition.new(
        platform: platform, service_name: "hive-#{name}", target_path: path, content: nil
      ) ]
    end
  end

  def reader(home, definitions:, **options)
    Hive::UserService::ExecutionEnvironment.new(
      project_root: home, home: home, profiles: [ Struct.new(:env_bin_override_keys).new([ "CODEX_BIN" ]) ],
      platform: definitions.values.first.platform, definitions: definitions,
      systemd_roots: [ File.join(home, ".config/systemd/user") ],
      status_reader: ->(definition) { status(definition) }, **options
    )
  end

  def status(definition, **options)
    Hive::UserService::Status.new(
      platform: definition.platform, unit_path: definition.target_path,
      content_state: File.exist?(definition.target_path) ? :matching : :absent,
      file_identity: nil, manager_availability: :available, enabled: false, running: false,
      load_state: "loaded", fragment_path: definition.target_path, need_daemon_reload: false,
      **options
    )
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def write_service_settings(definition, settings)
    if definition.platform == :linux
      assignments = settings.map { |name, value| Shellwords.escape("#{name}=#{value}") }.join(" ")
      write(definition.target_path, "[Service]\nEnvironment=#{assignments}\nExecStart=/fixture/hive bot start --foreground\n")
    else
      require "cgi"
      entries = settings.map { |name, value| "<key>#{name}</key><string>#{CGI.escapeHTML(value)}</string>" }.join
      write(definition.target_path, plist("<key>EnvironmentVariables</key><dict>#{entries}</dict><key>Program</key><string>/fixture/hive</string>"))
    end
  end
end
