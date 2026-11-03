require "test_helper"
require "json_schemer"
require "hive/commands/doctor"
require "hive/commands/doctor/agent_cli_check"

class DoctorAgentCliTest < Minitest::Test
  include HiveTestHelper

  Context = Hive::UserService::ExecutionEnvironment::Context

  def binary(root, version: nil, name: "codex")
    path = File.join(root, "bin", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\necho codex 0.156.1\n")
    File.chmod(0o777, path)
    if version
      File.write(File.join(root, "package.json"), JSON.generate(
        name: "@openai/codex", version: version, bin: { codex: "bin/#{name}" }
      ))
    end
    path
  end

  def service(label, path, currency: :stopped, reasons: [], installation: :installed)
    Context.new(label: label, environment: { "HOME" => File.dirname(path), "PATH" => File.dirname(path) },
                cwd: File.dirname(path), cwd_provenance: :inherited, installation: installation,
                reasons: reasons, sources: [], running_currency: currency)
  end

  def check(root, shell, contexts: [], **options)
    Hive::Commands::Doctor::AgentCliCheck.new(
      config: {}, project_root: root,
      environment: { "HOME" => root, "PATH" => File.dirname(shell) },
      service_contexts: contexts, **options
    )
  end

  def row(rows, environment, regime = "plain", profile = "codex")
    rows.find { |item| item[:agent] == profile && item[:skill] == environment && item[:regime] == regime }
  end

  def test_every_registered_profile_and_regime_include_stopped_services_and_older_version
    with_tmp_dir do |root|
      shell = binary(File.join(root, "shell"), version: "0.156.1")
      daemon = binary(File.join(root, "daemon"), version: "0.153.4")
      babysitter = binary(File.join(root, "baby"), version: "0.156.1")
      bot = binary(File.join(root, "bot"), version: "0.156.0")
      web = binary(File.join(root, "web"), version: "0.156.2")
      rows = check(root, shell, contexts: [ service("daemon", daemon), service("babysitter", babysitter),
        service("bot", bot), service("web", web) ]).rows

      assert_equal Hive::AgentProfiles.registered_names.size * 15, rows.length
      entry = row(rows, "daemon")
      assert_equal "warning", entry[:status]
      assert_equal "agent_cli", entry[:stage]
      assert_equal "agent_cli/codex", entry[:label]
      assert_equal "codex", entry[:configured_skill]
      assert_equal "0.153.4", entry.dig(:identity, :version)
      assert_equal "different", entry.dig(:comparison, :launch_path)
      assert_equal "older", entry.dig(:comparison, :version)
      assert_includes entry[:message], "daemon version is older than shell"
      assert_includes entry[:message], daemon
      assert_includes entry[:message], "cwd_inherited"
      assert_equal "prepared_binding_unavailable", row(rows, "daemon", "managed").dig(:identity, :reason)
      assert_equal bot, row(rows, "bot").dig(:identity, :launch_path)
      assert_equal "older", row(rows, "bot").dig(:comparison, :version)
      assert_equal web, row(rows, "web").dig(:identity, :launch_path)
      assert_equal "newer", row(rows, "web").dig(:comparison, :version)
    end
  end

  def test_filesystem_version_only_gap_is_uninspected_and_complete_match_is_present
    with_tmp_dir do |root|
      shell = binary(root)
      rows = check(root, shell).rows
      assert_includes row(rows, "shell")[:message], "version-uninspected"
      assert_includes row(rows, "shell")[:message], "--probe-agent-versions"
      assert_equal "uninspected", row(rows, "shell").dig(:comparison, :state)
      File.write(File.join(root, "package.json"), JSON.generate(
        name: "@openai/codex", version: "0.156.1", bin: { codex: "bin/codex" }
      ))
      rows = check(root, shell, contexts: [ service("daemon", shell) ]).rows
      assert_equal "present", row(rows, "daemon")[:status]
      assert_equal "dependency", row(rows, "daemon")[:kind]
      assert_equal "match", row(rows, "daemon").dig(:comparison, :state)
    end
  end

  def test_absent_service_omitted_but_indeterminate_and_stale_contexts_remain_and_never_probe
    with_tmp_dir do |root|
      shell = binary(root, version: "0.156.1")
      contexts = [ service("absent", shell, installation: :absent),
                   service("unreadable", shell, installation: :indeterminate,
                           reasons: [ { code: "source_unreadable", path: root, line: 2 } ]),
                   service("daemon", shell, currency: :stale) ]
      calls = []
      runner = ->(**args) { calls << args; [ "codex 0.156.1", "", true ] }
      rows = check(root, shell, contexts: contexts, probe: true, runner: runner).rows
      refute rows.any? { |item| item[:skill] == "absent" }
      assert_equal "warning", row(rows, "unreadable")[:status]
      assert_includes row(rows, "unreadable")[:message], "source_unreadable"
      assert_includes row(rows, "daemon")[:remediation], "restart"
      assert_includes row(rows, "daemon")[:message], "stale"
      assert calls.all? { |args| args.fetch(:cwd) == root }
      assert_equal 2, calls.length
    end
  end

  def test_probe_uses_exact_context_and_shared_budget_and_preserves_filesystem_rows
    with_tmp_dir do |root|
      shell = binary(File.join(root, "shell"), version: "0.156.1+build.1")
      daemon = binary(File.join(root, "daemon"), version: "0.153.4")
      time = 0
      budget = Hive::AgentCliIdentity::ProbeBudget.new(clock: -> { time })
      calls = []
      runner = lambda do |**args|
        calls << args
        time += 30
        [ "codex 0.156.1+build.1", "", true ]
      end
      rows = check(root, shell, contexts: [ service("daemon", daemon) ], probe: true,
                   budget: budget, runner: runner).rows
      assert_equal 2, calls.length
      assert calls.all? { |args| args[:timeout] <= 30 && args[:cwd] == root }
      assert_equal "live_probe", row(rows, "shell").dig(:identity, :version_source)
      assert_equal "0.153.4", row(rows, "daemon").dig(:identity, :version)
      assert_equal "probe_budget_exhausted", row(rows, "daemon").dig(:identity, :version_reason)
      assert_includes row(rows, "daemon")[:message], "probe_budget_exhausted"
      assert_equal "older", row(rows, "daemon").dig(:comparison, :version)
    end
  end

  def test_mixed_probe_failures_are_typed_and_do_not_suppress_other_profiles
    with_tmp_dir do |root|
      shell = binary(root)
      binary(root, name: "claude")
      calls = []
      runner = lambda do |**args|
        calls << args
        if File.basename(args[:executable]) == "claude"
          "probe_timeout"
        else
          [ "codex 0.156.1", "sk-abcdefghijklmnopqrstuvwx", true ]
        end
      end
      rows = check(root, shell, probe: true, runner: runner).rows
      assert_equal "probe_timeout", row(rows, "shell", "plain", "claude").dig(:identity, :version_reason)
      assert_equal "0.156.1", row(rows, "shell").dig(:identity, :version)
      assert_equal "executable_unavailable", row(rows, "shell", "plain", "pi").dig(:identity, :reason)
      refute_includes JSON.generate(rows), "sk-abcdefghijklmnopqrstuvwx"
      assert_equal 4, calls.length
    end
  end

  def test_regime_divergence_and_opaque_targets_are_never_clean_matches
    with_tmp_dir do |root|
      shim = binary(File.join(root, "shims"))
      File.write(shim, "#!/bin/sh\nexec mise x -- codex\n")
      real = binary(File.join(root, "real"), version: "0.156.1")
      contexts = [ service("daemon", shim) ]
      environment = { "HOME" => root, "PATH" => [ File.dirname(shim), File.dirname(real) ].join(":") }
      rows = Hive::Commands::Doctor::AgentCliCheck.new(
        config: {}, project_root: root, environment: environment, service_contexts: contexts
      ).rows
      assert_equal shim, row(rows, "shell").dig(:identity, :launch_path)
      assert_equal real, row(rows, "shell", "isolated").dig(:identity, :launch_path)
      assert_equal true, row(rows, "shell").dig(:comparison, :regime_divergence)
      assert_includes row(rows, "shell")[:message], "selection differs"
      assert_equal "incomplete", row(rows, "daemon").dig(:comparison, :state)
      assert_nil row(rows, "daemon").dig(:identity, :effective_target)
    end
  end

  def test_configured_overrides_custom_profiles_and_executable_alias_guard
    with_tmp_dir do |root|
      path = binary(root, version: "0.156.1")
      aliased = File.join(root, "qmd")
      File.link(path, aliased)
      profile = Hive::AgentProfile.new(name: :custom, bin_default: path, headless_flag: "-p",
                                      version_flag: "--version", skill_syntax_format: "/%s")
      originals = Hive::AgentProfiles.instance_variable_get(:@profiles).dup
      Hive::AgentProfiles.register(:custom, profile)
      checker = Hive::Commands::Doctor::AgentCliCheck.new(
        config: { "agents" => { "codex" => { "bin" => "./bin/codex", "env_override" => "MY_CLI" } } },
        project_root: root, environment: { "HOME" => root, "PATH" => "", "MY_CLI" => path },
        service_contexts: []
      )
      rows = checker.rows
      assert_equal (originals.length + 1) * 3, rows.length
      assert row(rows, "shell", "plain", "custom")
      assert_equal path, row(rows, "shell").dig(:identity, :launch_path)
      assert_equal path, row(rows, "shell").fetch(:configured_skill)
      assert checker.agent_executable?(aliased)
      refute checker.agent_executable?("/nonexistent")
      refute checker.agent_executable?(nil)
      refute checker.agent_executable?(binary(File.join(root, "other"), name: "qmd"))
    ensure
      Hive::AgentProfiles.instance_variable_set(:@profiles, originals) if originals
    end
  end

  def test_doctor_schema_redaction_and_human_paths_with_healthy_control_plane
    with_tmp_global_config do |state_home|
      with_tmp_dir do |root|
        path = binary(root, version: "0.156.1")
        secret = "sk-abcdefghijklmnopqrstuvwx"
        FileUtils.mkdir_p(File.dirname(Hive::Paths.runtime_control_plane_path))
        File.write(Hive::Paths.runtime_control_plane_path, "placeholder")
        inspector = Struct.new(:inspect).new([])
        status = { "phase" => "active", "database" => { "status" => "ok" } }
        options = { config: {}, project_root: root, inspector: inspector,
                    environment: { "HOME" => root, "PATH" => File.dirname(path) },
                    service_contexts: [ service("daemon", path, currency: :unknown,
                                              reasons: [ { code: "unknown", path: "#{root}/#{secret}", line: 3 } ]) ] }
        with_replaced_singleton_method(Hive::RuntimeControlPlane::Installation, :status, ->(**) { status }) do
          out = StringIO.new
          assert_equal 0, Hive::Commands::Doctor.new(**options, output: out, json: true).call
          payload = JSON.parse(out.string)
          schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-doctor"))))
          assert_empty schema.validate(payload).to_a
          assert payload.fetch("checks").any? { |entry| entry["kind"] == "runtime_control_plane" && entry["status"] == "ok" }
          refute_includes out.string, secret
          assert_includes out.string, "[REDACTED:openai_api_key]"
          human = StringIO.new
          Hive::Commands::Doctor.new(**options, output: human).call
          assert_includes human.string, path
          assert_includes human.string, "0.156.1"
          assert_includes human.string, "shell plain (child_path)"
          refute_includes human.string, secret
        end
      end
    end
  end

  def test_invalid_profile_overlay_still_returns_config_exit_with_redacted_error
    secret = "sk-abcdefghijklmnopqrstuvwx"
    [ true, false ].each do |json|
      output = StringIO.new
      command = Hive::Commands::Doctor.new(
        config: { "agents" => { "codex" => { secret => "bad" } } }, project_root: nil,
        environment: {}, service_contexts: [], inspector: Struct.new(:inspect).new([]), output: output, json: json
      )
      assert_equal 78, command.call
      refute_includes output.string, secret
      assert_includes output.string, "[REDACTED:openai_api_key]"
    end
  end

  def test_qmd_alias_to_registered_agent_is_skipped_in_process
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, ".llm-wiki"))
      path = binary(root)
      output = StringIO.new
      command = Hive::Commands::Doctor.new(
        config: { "agents" => { "codex" => { "bin" => path } } }, project_root: root,
        environment: { "HOME" => root, "PATH" => "", "HIVE_QMD_BIN" => path },
        service_contexts: [], inspector: Struct.new(:inspect).new([]), output: output
      )
      with_replaced_singleton_method(Open3, :capture3, ->(*) { flunk "agent executable was launched as qmd" }) do
        assert_equal 0, command.call
      end
      assert_includes output.string, "registered agent executable; version probe skipped"
    end
  end

  def test_prerelease_versions_compare_numerically_and_build_metadata_does_not_create_drift
    with_tmp_dir do |root|
      shell = binary(File.join(root, "shell"), version: "0.156.1-rc.10")
      old = binary(File.join(root, "old"), version: "0.156.1-rc.2")
      release = binary(File.join(root, "release"), version: "0.156.1+release")
      rows = check(root, shell, contexts: [ service("daemon", old), service("babysitter", release) ]).rows
      assert_equal "older", row(rows, "daemon").dig(:comparison, :version)
      assert_equal "newer", row(rows, "babysitter").dig(:comparison, :version)
    end
  end

  def test_installed_systemd_and_launchd_evidence_flows_into_complete_doctor_comparisons
    %i[linux macos].each do |platform|
      with_tmp_dir do |root|
        shell = binary(File.join(root, "shell"), version: "0.156.1")
        daemon = binary(File.join(root, "daemon"), version: "0.153.4")
        babysitter = binary(File.join(root, "babysitter"), version: "0.156.1")
        bot = binary(File.join(root, "bot"), version: "0.156.0")
        web = binary(File.join(root, "web"), version: "0.156.2")
        secret = "sk-abcdefghijklmnopqrstuvwx"
        definitions = { "daemon" => daemon, "babysitter" => babysitter, "bot" => bot, "web" => web }.to_h do |label, executable|
          path = File.join(root, "#{label}.#{platform == :linux ? 'service' : 'plist'}")
          content = if platform == :linux
            "[Service]\nEnvironment=PATH=#{File.dirname(executable)} SECRET=#{secret}\nExecStart=/fixture/hive\n"
          else
            <<~PLIST
              <plist><dict><key>EnvironmentVariables</key><dict>
              <key>PATH</key><string>#{File.dirname(executable)}</string>
              <key>SECRET</key><string>#{secret}</string></dict>
              <key>ProgramArguments</key><array><string>/fixture/hive</string></array></dict></plist>
            PLIST
          end
          File.write(path, content)
          [ label, Hive::UserService::Definition.new(platform: platform, service_name: "hive-#{label}",
                                                    target_path: path, content: nil) ]
        end
        status = lambda do |definition|
          Hive::UserService::Status.new(
            platform: platform, unit_path: definition.target_path, content_state: :matching,
            file_identity: nil, manager_availability: :available, enabled: false, running: false,
            load_state: "loaded", fragment_path: definition.target_path, need_daemon_reload: false
          )
        end
        contexts = Hive::UserService::ExecutionEnvironment.new(
          project_root: root, profiles: [ Hive::AgentProfiles.lookup(:codex) ], home: root,
          platform: platform, definitions: definitions, status_reader: status, systemd_roots: [ root ]
        ).call
        assert contexts.all?(&:complete?), contexts.map(&:reasons).inspect
        output = StringIO.new
        doctor = Hive::Commands::Doctor.new(
          config: {}, project_root: root, environment: { "HOME" => root, "PATH" => File.dirname(shell) },
          service_contexts: contexts, inspector: Struct.new(:inspect).new([]), output: output, json: true
        )
        assert_equal 0, doctor.call
        payload = JSON.parse(output.string)
        entry = payload.fetch("checks").find do |item|
          item["agent"] == "codex" && item["skill"] == "daemon" && item["regime"] == "plain"
        end
        assert_equal "0.153.4", entry.dig("identity", "version")
        assert_equal "older", entry.dig("comparison", "version")
        assert payload.fetch("checks").any? { |item| item["skill"] == "babysitter" }
        %w[bot web].each do |label|
          service_entry = payload.fetch("checks").find do |item|
            item["agent"] == "codex" && item["skill"] == label && item["regime"] == "plain"
          end
          assert_equal({ "bot" => bot, "web" => web }.fetch(label), service_entry.dig("identity", "launch_path"))
          assert_equal "stopped", service_entry.dig("execution_context", "running_currency")
          assert_includes service_entry.fetch("message"), "declared configuration"
        end
        refute_includes output.string, secret
      end
    end
  end
end
