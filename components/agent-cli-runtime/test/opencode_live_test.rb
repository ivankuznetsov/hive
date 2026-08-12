require_relative "test_helper"
require "timeout"

class AgentCliRuntimeOpenCodeLiveTest < Minitest::Test
  LIVE_FLAG = "AGENT_CLI_RUNTIME_OPENCODE_LIVE"
  ROUTE_KEY = "AGENT_CLI_RUNTIME_OPENCODE_LIVE_ROUTE"
  CONFIG_KEY = "AGENT_CLI_RUNTIME_OPENCODE_LIVE_CONFIG"
  CREDENTIAL_KEY = "AGENT_CLI_RUNTIME_OPENCODE_LIVE_CREDENTIAL_ENV"
  VARIANT_KEY = "AGENT_CLI_RUNTIME_OPENCODE_LIVE_VARIANT"

  def test_explicit_named_route_performs_one_atomic_confined_edit
    skip "set #{LIVE_FLAG}=1 to opt into the authenticated OpenCode smoke" unless
      ENV[LIVE_FLAG] == "1"

    route = required_live_value(ROUTE_KEY)
    config_path = File.expand_path(required_live_value(CONFIG_KEY))
    credential_key = required_live_value(CREDENTIAL_KEY)
    skip "selected OpenCode live credential #{credential_key} is not configured" if
      ENV[credential_key].to_s.empty?
    live_env = ENV.to_h.merge(
      "AGENT_CLI_RUNTIME_OPENCODE_BIN" => installed_binary!
    )

    Dir.mktmpdir("agent-cli-runtime-opencode-live") do |dir|
      work = File.join(dir, "work")
      outside = File.join(dir, "outside")
      root = File.join(dir, "invocation")
      proof = File.join(work, "opencode-live-proof.txt")
      forbidden = File.join(outside, "opencode-live-forbidden.txt")
      FileUtils.mkdir_p([ work, outside ])

      prepared = AgentCliRuntime.prepare!(
        AgentCliRuntime::OpenCodePreparationRequest.new(
          request: AgentCliRuntime::Request.new(
            profile: :opencode,
            prompt: "Create opencode-live-proof.txt in the working directory " \
                    "with exactly the text opencode-live-ok. Do not access " \
                    "or modify anything outside the working directory.",
            permission_mode: "workspace-write",
            model: route,
            effort: optional_live_value(VARIANT_KEY)
          ),
          working_directory: work,
          invocation_root: root,
          configuration_path: config_path,
          credential_environment_keys: [ credential_key ],
          additional_write_roots: [ work ]
        ),
        env: live_env
      )

      permission = JSON.parse(File.read(prepared.configuration_path))
                       .fetch("permission")
      assert_equal "deny", permission.dig("edit", "*")
      assert_equal "allow", permission.dig("edit", "#{work}/**")
      assert_equal "deny", permission.fetch("bash")
      assert_equal "deny", permission.dig("external_directory", "*")
      refute permission.dig("edit").key?(outside)
      refute permission.dig("edit").key?("#{outside}/**")

      run = capture_process(
        child_environment(prepared.environment_for(env: live_env), live_env),
        prepared.invocation.argv,
        stdin_data: prepared.invocation.stdin_data, chdir: work,
        timeout_sec: 300
      )
      inspection_output = nil
      if run.fetch(:termination).success?
        parsed = AgentCliRuntime.parse_run(:opencode, stdout: run.fetch(:stdout))
        inspection = AgentCliRuntime.prepare_inspection(prepared, parsed)
        inspected = capture_process(
          child_environment(inspection.environment_for(env: live_env), live_env),
          inspection.argv,
          stdin_data: inspection.stdin_data, chdir: work, timeout_sec: 30
        )
        inspection_output = inspected.fetch(:stdout) if
          inspected.fetch(:termination).success?
      end

      outcome = AgentCliRuntime.normalize(
        :opencode,
        AgentCliRuntime::CapturedResult.new(
          stdout: run.fetch(:stdout),
          stderr: run.fetch(:stderr),
          termination: run.fetch(:termination),
          inspection_output: inspection_output
        ),
        requested_route: prepared.requested_route
      )

      assert_equal :completed, outcome.kind, outcome.diagnostic
      assert_equal route, outcome.identity.requested.to_s
      assert_equal route, outcome.identity.actual.to_s
      assert_equal :matched, outcome.identity.resolution_status
      assert_equal "opencode-live-ok", File.read(proof).strip
      refute File.exist?(forbidden)
    ensure
      prepared&.cleanup!
      refute File.exist?(root), "live smoke must clean its invocation root"
    end
  end

  private

  def required_live_value(key)
    value = ENV[key].to_s.strip
    skip "#{key} is required for the opted-in OpenCode live smoke" if value.empty?
    value
  end

  def optional_live_value(key)
    value = ENV[key].to_s.strip
    value.empty? ? nil : value
  end

  def installed_binary!
    executable = AgentCliRuntime::Profiles.fetch(:opencode).bin(env: ENV)
    if executable.include?(File::SEPARATOR)
      path = File.expand_path(executable)
      return path if File.file?(path) && File.executable?(path)
    else
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        candidate = File.join(directory, executable)
        return File.realpath(candidate) if
          File.file?(candidate) && File.executable?(candidate)
      end
    end
    flunk "the opted-in OpenCode live smoke requires an installed executable"
  end

  def child_environment(overrides, source)
    base = %w[
      HOME LANG LC_ALL LOGNAME PATH SHELL SSL_CERT_DIR SSL_CERT_FILE USER
    ].each_with_object({}) do |key, selected|
      value = source[key]
      selected[key] = value.to_s unless value.to_s.empty?
    end
    base.merge(overrides)
  end

  def capture_process(environment, argv, stdin_data:, chdir:, timeout_sec:)
    stdout = +""
    stderr = +""
    status = nil
    timed_out = false

    Open3.popen3(
      environment, *argv, chdir: chdir, pgroup: true, unsetenv_others: true
    ) do |stdin, out, err, wait_thread|
      stdin.write(stdin_data) if stdin_data
      stdin.close
      stdout_reader = Thread.new { out.read }
      stderr_reader = Thread.new { err.read }
      begin
        status = Timeout.timeout(timeout_sec) { wait_thread.value }
      rescue Timeout::Error
        timed_out = true
        terminate_process_group(wait_thread.pid)
        status = wait_thread.value
      ensure
        stdout = stdout_reader.value
        stderr = stderr_reader.value
      end
    end

    signal = if status&.signaled?
      Signal.signame(status.termsig) || status.termsig.to_s
    end
    {
      stdout: stdout,
      stderr: stderr,
      termination: AgentCliRuntime::TerminationEvidence.new(
        exit_code: status&.exited? ? status.exitstatus : nil,
        timed_out: timed_out,
        signal: signal
      )
    }
  end

  def terminate_process_group(pid)
    Process.kill("TERM", -pid)
    Timeout.timeout(3) do
      sleep 0.05 while process_alive?(pid)
    end
  rescue Timeout::Error
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
