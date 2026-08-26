require "test_helper"
require "hive/agent"
require "hive/agent_profile"
require "hive/agent_support/opencode"
require "hive/invocation_process_custody"
require "hive/task"

class OpenCodeAgentLifecycleTest < Minitest::Test
  include HiveTestHelper

  ROUTE = "anthropic/claude-sonnet-4-5"

  def test_native_login_is_used_in_place_without_staging_credentials
    with_fixture do |fixture|
      home = File.join(fixture.fetch(:dir), "home")
      data_home = File.join(home, "data")
      auth_path = File.join(data_home, "opencode", "auth.json")
      FileUtils.mkdir_p(File.dirname(auth_path))
      File.write(auth_path, JSON.generate("anthropic" => { "type" => "oauth" }))
      File.chmod(0o600, auth_path)
      profile = Hive::AgentProfile.new(
        runtime_profile: AgentCliRuntime::Profiles.fetch(:opencode),
        skill_syntax_format: "/%{skill}",
        status_detection_mode: :exit_code_only,
        permission_presets: %w[read-only scoped],
        support_configuration: Hive::AgentSupport::OpenCode::Configuration.new(
          configuration_path: fixture.fetch(:configuration)
        )
      )

      result = with_env(
        "HOME" => home, "XDG_DATA_HOME" => data_home,
        "ANTHROPIC_API_KEY" => nil, "OPENAI_API_KEY" => nil
      ) do
        build_agent(
          make_task(fixture.fetch(:dir), slug: "native-auth-260825-aaaa"),
          fixture, profile:
        ).run!
      end

      assert_equal :ok, result.fetch(:status), result.inspect
      environment = JSON.parse(File.read(fixture.fetch(:environment)))
      assert_equal home, environment.fetch("HOME")
      assert_equal data_home, environment.fetch("XDG_DATA_HOME")
      assert environment.fetch("native_credential_present")
      assert environment.fetch("native_credential_supports_provider")
      assert_equal 0o600, environment.fetch("native_credential_mode")
      refute environment.fetch("selected_credential_present")
      refute environment.fetch("ambient_credential_present")
      assert File.file?(auth_path)
    end
  end

  def test_success_uses_native_state_for_run_and_export
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir))
      agent = build_agent(task, fixture)
      native_home = File.join(fixture.fetch(:dir), "native-home")
      native_config = File.join(native_home, "config")
      native_data = File.join(native_home, "data")
      native_cache = File.join(native_home, "cache")
      native_state = File.join(native_home, "state")

      result = with_env(
        "HOME" => native_home,
        "XDG_CONFIG_HOME" => native_config,
        "XDG_DATA_HOME" => native_data,
        "XDG_CACHE_HOME" => native_cache,
        "XDG_STATE_HOME" => native_state,
        "ANTHROPIC_API_KEY" => "secret-canary",
        "OPENAI_API_KEY" => "ambient-must-not-cross"
      ) { agent.run! }

      assert_equal :ok, result.fetch(:status)
      assert_equal :completed, result.fetch(:normalized_outcome_kind)
      assert_equal "Done.", result.fetch(:final_message)
      assert_equal ROUTE, result.fetch(:requested_route)
      assert_equal ROUTE, result.fetch(:actual_route)
      assert_equal 5, result.dig(:usage, :input)
      assert_equal 2, result.dig(:usage, :cache_read)
      assert_equal 0, result.dig(:usage, :cache_write)
      assert_equal 0.0, result.dig(:usage, :cost)
      assert_instance_of Hive::AgentRuntime::NormalizedOutcome,
                         agent.observable_result
      assert_equal :completed, agent.observable_result.kind

      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal 1, calls.count { |line| line.start_with?("run --auto ") }
      assert_equal 1, calls.count { |line| line.start_with?("export ses_") }
      environment = JSON.parse(File.read(fixture.fetch(:environment)))
      assert_equal native_home, environment.fetch("HOME")
      assert_equal native_config, environment.fetch("XDG_CONFIG_HOME")
      assert_equal native_data, environment.fetch("XDG_DATA_HOME")
      assert_equal native_cache, environment.fetch("XDG_CACHE_HOME")
      assert_equal native_state, environment.fetch("XDG_STATE_HOME")
      assert_nil environment.fetch("OPENCODE_DISABLE_PROJECT_CONFIG")
      assert_equal fixture.fetch(:configuration), environment.fetch("OPENCODE_CONFIG")
      assert environment.fetch("OPENCODE_PERMISSION")
      assert environment.fetch("selected_credential_present")
      refute environment.fetch("ambient_credential_present")
      refute_includes File.read(result.fetch(:log_file)), "secret-canary"
    end
  end

  def test_tool_only_terminal_step_is_a_completed_run
    with_fixture(mode: :tool_only) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "tool-only-260812-aaaa")
      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
        build_agent(task, fixture).run!
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal :completed, result.fetch(:normalized_outcome_kind)
      assert_equal "", result.fetch(:final_message)
      assert result.fetch(:output_completed)
    end
  end

  def test_sanitized_export_uses_a_regular_file_to_avoid_lost_stdout_tails
    with_fixture(mode: :inspection_requires_regular_file) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "inspection-file-260821-aaaa")
      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
        build_agent(task, fixture).run!
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal :completed, result.fetch(:normalized_outcome_kind)
      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal 1, calls.count { |line| line.start_with?("export ses_") }
    end
  end

  def test_oversized_sanitized_export_is_rejected_with_a_bounded_diagnostic
    with_fixture(mode: :oversized_export) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "inspection-oversized-260822-aaaa")
      result = with_runtime_constant(
        AgentCliRuntime::OpenCode::ResultParser, :MAX_EXPORT_BYTES, 4095
      ) do
        with_execution_constant(:EXPORT_CAPTURE_BYTES, 4096) do
          with_execution_constant(:INSPECTION_RETRY_DELAY_SECONDS, 0) do
            with_env("ANTHROPIC_API_KEY" => "secret-canary") do
              build_agent(task, fixture).run!
            end
          end
        end
      end

      assert_equal :error, result.fetch(:status)
      assert_equal :malformed_output, result.fetch(:normalized_outcome_kind)
      assert_match(/sanitized export inspection stdout exceeded 4095 bytes/,
                   result.fetch(:inspection_diagnostic))
    end
  end

  def test_implementation_sized_prompt_is_piped_without_crossing_exec_argument_limit
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "large-prompt-260812-aaaa")
      prompt = "implement the reviewed plan\n" + ("x" * 150_000)

      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
        build_agent(task, fixture, prompt:).run!
      end

      assert_equal :ok, result.fetch(:status)
      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      run = calls.find { |line| line.start_with?("run --auto ") }
      assert run
      assert_operator run.bytesize, :<, 8_192
      refute_includes run, prompt
      assert_equal prompt, File.binread(fixture.fetch(:stdin))
    end
  end

  def test_nonzero_malformed_timeout_and_inspection_failure_skip_or_bound_inspection
    {
      auth_failure: [ :authentication_failure, 0 ],
      malformed: [ :malformed_output, 0 ],
      inspection_failure: [ :malformed_output, 1 ],
      timeout: [ :timed_out, 0 ]
    }.each do |mode, (kind, export_count)|
      with_fixture(mode:) do |fixture|
        task = make_task(
          fixture.fetch(:dir), slug: "#{mode.to_s.tr('_', '-')}-260812-aaaa"
        )
        result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
          build_agent(
            task, fixture,
            timeout_sec: mode == :timeout ? 0.2 : 5
          ).run!
        end

        expected_status = mode == :timeout ? :timeout : :error
        assert_equal expected_status, result.fetch(:status), mode
        assert_equal kind, result.fetch(:normalized_outcome_kind), mode
        calls = File.readlines(fixture.fetch(:calls), chomp: true)
        assert_equal 1,
                     calls.count { |line| line.start_with?("run --auto ") }, mode
        assert_equal export_count,
                     calls.count { |line| line.start_with?("export ses_") }, mode
      end
    end
  end

  def test_structured_provider_rate_limit_writes_a_retryable_limit_marker
    with_fixture(mode: :rate_limited) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "rate-limited-260824-aaaa")
      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
        build_agent(
          task, fixture, profile_status: :state_file_marker
        ).run!
      end

      assert_equal :error, result.fetch(:status)
      assert_equal "limits_reached", result.fetch(:error_reason)
      assert_equal :rate_limited, result.dig(:provider_error, :kind)
      assert_includes result.fetch(:limit_text), "temporarily rate-limited upstream"
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "limits_reached", marker.attrs.fetch("reason")
      refute_nil marker.attrs["retry_after"]
      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal 0, calls.count { |line| line.start_with?("export ses_") }
    end
  end

  def test_malformed_sanitized_export_is_retried_before_failing_the_run
    with_fixture(mode: :inspection_malformed_once) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "inspection-retry-260821-aaaa")
      result = with_execution_constant(
        :INSPECTION_RETRY_DELAY_SECONDS, 0
      ) do
        with_env("ANTHROPIC_API_KEY" => "secret-canary") do
          build_agent(task, fixture).run!
        end
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal :completed, result.fetch(:normalized_outcome_kind)
      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal 2, calls.count { |line| line.start_with?("export ses_") }
    end

    with_fixture(mode: :inspection_malformed) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "inspection-malformed-260821-aaaa")
      result = with_execution_constant(
        :INSPECTION_RETRY_DELAY_SECONDS, 0
      ) do
        with_env("ANTHROPIC_API_KEY" => "secret-canary") do
          build_agent(task, fixture).run!
        end
      end

      assert_equal :error, result.fetch(:status)
      assert_equal :malformed_output, result.fetch(:normalized_outcome_kind)
      assert_match(/remained malformed after 3 attempts/,
                   result.fetch(:inspection_diagnostic))
      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal Hive::AgentSupport::OpenCode::Execution::INSPECTION_JSON_ATTEMPTS,
                   calls.count { |line| line.start_with?("export ses_") }
    end
  end

  def test_term_cancels_the_hive_lifecycle_without_running_inspection
    with_fixture(mode: :cancelled) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "cancelled-260812-aaaa")
      killer = Thread.new do
        Timeout.timeout(5) do
          loop do
            break if File.exist?(fixture.fetch(:calls)) &&
              File.readlines(fixture.fetch(:calls)).any? do |line|
                line.start_with?("run --auto ")
              end

            sleep 0.02
          end
        end
        sleep 0.1
        Process.kill("TERM", Process.pid)
      end

      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
        build_agent(task, fixture).run!
      end
      killer.join

      assert_equal :error, result.fetch(:status)
      assert result.fetch(:cancelled)
      assert_equal :cancelled, result.fetch(:normalized_outcome_kind)
      calls = File.readlines(fixture.fetch(:calls), chomp: true)
      assert_equal 0, calls.count { |line| line.start_with?("export ses_") }
    ensure
      killer&.kill if killer&.alive?
    end
  end

  def test_explicit_native_configuration_supplies_the_route_when_role_has_no_model_override
    with_fixture(default_route: ROUTE) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "default-route-260812-aaaa")
      agent = build_agent(task, fixture, explicit_launch: false)

      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }

      assert_equal :ok, result.fetch(:status)
      assert_equal ROUTE, result.fetch(:requested_route)
      assert_equal ROUTE, result.fetch(:actual_route)
    end
  end

  def test_identity_only_downstream_launch_preserves_the_nested_route
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "identity-route-260812-aaaa")
      agent = build_agent(task, fixture, identity_only: true)

      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }

      assert_equal :ok, result.fetch(:status)
      assert_equal ROUTE, result.fetch(:requested_route)
      run = File.readlines(fixture.fetch(:calls), chomp: true)
                .find { |line| line.start_with?("run --auto ") }
      assert_includes run, "--model #{ROUTE}"
      assert_includes run, "--variant high"
    end
  end

  def test_skill_readiness_is_rechecked_inside_the_native_environment
    with_fixture do |fixture|
      shadow = File.join(
        fixture.fetch(:work), ".opencode", "skills", "ce-plan", "SKILL.md"
      )
      FileUtils.mkdir_p(File.dirname(shadow))
      File.write(shadow, "# shadow\n")
      task = make_task(fixture.fetch(:dir), slug: "prepared-skill-260812-aaaa")
      agent = build_agent(
        task, fixture,
        prompt: "Use /ce-plan to produce the plan.",
        plugins: [ Hive::AgentSupport::OpenCode::Skills::PINNED_COMPOUND_ENGINEERING_PLUGIN ]
      )

      error = assert_raises(Hive::AgentError) do
        with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }
      end

      assert_match(/native skill readiness failed/, error.message)
      assert_match(/shadows/, error.message)
      calls = if File.exist?(fixture.fetch(:calls))
        File.readlines(fixture.fetch(:calls), chomp: true)
      else
        []
      end
      assert_equal 0, calls.count { |line| line.start_with?("run --auto ") }
    end
  end

  def test_launch_channels_reject_untyped_arguments_and_tools
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "invalid-launch-260812-aaaa")
      cases = [
        { cli_flags: [ "--raw" ] },
        { allowed_tools: [ "Read" ] }
      ]

      cases.each_with_index do |options, index|
        agent = build_agent(
          task, fixture, **options
        )
        assert_raises(Hive::ConfigError) do
          with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }
        end
      end
    end
  end

  def test_process_group_lookup_races_fall_back_to_the_spawned_pid
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "pgid-race-260812-aaaa")
      agent = build_agent(task, fixture)
      replacement = ->(_pid) { raise Errno::ESRCH }

      result = with_replaced_singleton_method(Process, :getpgid, replacement) do
        with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal result.fetch(:pid), result.fetch(:pgid)
    end
  end

  def test_process_cleanup_failure_is_returned_and_warned_during_unwind
    with_fixture do |fixture|
      custody = Object.new
      custody.define_singleton_method(:environment) { {} }
      custody.define_singleton_method(:cleanup!) do
        raise Hive::InvocationProcessCustody::CleanupError, "synthetic cleanup failure"
      end

      stderr = with_replaced_singleton_method(
        Hive::InvocationProcessCustody, :new, -> { custody }
      ) do
        capture_io do
          @result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
            build_agent(make_task(fixture.fetch(:dir)), fixture).run!
          end
        end.last
      end

      assert_equal :error, @result.fetch(:status)
      assert_equal "process_cleanup_failed", @result.fetch(:error_reason)
      assert_match(/synthetic cleanup failure/, @result.fetch(:process_cleanup_error))
      assert_match(/OpenCode process cleanup failed/, stderr)
    end
  end

  def test_native_environment_keeps_explicit_values_without_xdg_redirects
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "environment-260812-aaaa")
      agent = build_agent(
        task, fixture, launch_environment: { "LANG" => "C.explicit" }
      )
      agent.extend(Hive::AgentSupport::OpenCode::Execution)

      selected = with_env(
        "PATH" => "/host/path", "XDG_CONFIG_HOME" => nil,
        "ANTHROPIC_API_KEY" => "host-secret"
      ) do
        agent.send(
          :native_environment,
          agent.profile.support_configuration
        ).then { |environment| agent.send(:effective_native_environment, environment) }
      end
      assert_equal "C.explicit", selected.fetch("LANG")
      assert_equal "/host/path", selected.fetch("PATH")
      assert_equal "host-secret", selected.fetch("ANTHROPIC_API_KEY")
      refute selected.key?("XDG_CONFIG_HOME")
      assert_equal fixture.fetch(:configuration), selected.fetch("OPENCODE_CONFIG")
    end
  end

  def test_unreadable_native_configuration_has_no_inferred_default_route
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "missing-config-260825-aaaa")
      agent = build_agent(task, fixture)
      agent.extend(Hive::AgentSupport::OpenCode::Execution)
      configuration = Hive::AgentSupport::OpenCode::Configuration.new(
        configuration_path: File.join(fixture.fetch(:dir), "missing.json")
      )

      assert_nil agent.send(:configured_default_route, configuration)
    end
  end

  def test_inline_native_configuration_is_copied_before_launch_enrichment
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "inline-config-260825-aaaa")
      agent = build_agent(task, fixture)
      agent.extend(Hive::AgentSupport::OpenCode::Execution)
      source = {
        "model" => ROUTE,
        "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } }
      }
      configuration = Hive::AgentSupport::OpenCode::Configuration.new(
        configuration: source
      )

      content = agent.send(:native_configuration_content, configuration)

      assert_equal source, content
      refute_same source, content
      refute_same source.fetch("provider"), content.fetch("provider")
    end
  end

  def test_capture_thread_shutdown_bounds_hung_and_defensive_io_paths
    with_fixture do |fixture|
      agent = build_agent(
        make_task(fixture.fetch(:dir), slug: "capture-thread-260812-aaaa"),
        fixture
      )
      joins = []
      killed = false
      capture = { data: +"", truncated: false }
      thread = Object.new
      thread.define_singleton_method(:join) { |seconds| joins << seconds }
      thread.define_singleton_method(:alive?) { true }
      thread.define_singleton_method(:kill) { killed = true }
      io = StringIO.new

      agent.send(
        :finish_capture_thread, thread, io,
        timeout: Hive::AgentSupport::OpenCode::Execution::CAPTURE_DRAIN_SECONDS,
        capture: capture
      )

      assert_equal [
        Hive::AgentSupport::OpenCode::Execution::CAPTURE_DRAIN_SECONDS, 0.2
      ], joins
      assert_predicate io, :closed?
      assert killed
      assert capture.fetch(:truncated),
             "a forced reader shutdown must invalidate the partial capture"

      rescue_killed = false
      failing_thread = Object.new
      failing_thread.define_singleton_method(:join) { |_seconds| nil }
      failing_thread.define_singleton_method(:alive?) { true }
      failing_thread.define_singleton_method(:kill) { rescue_killed = true }
      failing_io = Object.new
      failing_io.define_singleton_method(:closed?) { false }
      failing_io.define_singleton_method(:close) { raise IOError, "synthetic" }

      agent.send(:finish_capture_thread, failing_thread, failing_io)
      assert rescue_killed

      agent.send(:close_ios, nil, failing_io)
    end
  end

  def test_inspection_timeout_reaps_the_export_and_reports_empty_stderr
    with_fixture(mode: :inspection_timeout) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "inspection-timeout-260812-aaaa")
      agent = build_agent(task, fixture)
      result = with_execution_constant(:INSPECTION_TIMEOUT_SECONDS, 0.05) do
        with_env("ANTHROPIC_API_KEY" => "secret-canary") { agent.run! }
      end

      assert_equal :error, result.fetch(:status)
      assert_match(/sanitized export inspection timed out after 0.05 seconds/,
                   result.fetch(:inspection_diagnostic))
      assert_match(/sanitized export inspection timed out after 0.05 seconds/,
                   result.fetch(:error_message))
    end

    with_fixture(mode: :inspection_empty_failure) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "inspection-empty-260812-aaaa")
      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
        build_agent(task, fixture).run!
      end
      assert_match(/sanitized export inspection failed/,
                   result.fetch(:inspection_diagnostic))
      assert_match(/sanitized export inspection failed/,
                   result.fetch(:error_message))
    end
  end

  def test_long_session_export_larger_than_the_old_four_megabyte_cap_completes
    with_fixture(mode: :large_export) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "large-export-260822-aaaa")
      result = with_env("ANTHROPIC_API_KEY" => "secret-canary") do
        build_agent(task, fixture).run!
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal :completed, result.fetch(:normalized_outcome_kind)
      assert_equal ROUTE, result.fetch(:actual_route)
    end
  end

  def test_export_inspection_caps_oversized_stdout_and_stderr
    capture_limit = 4 * 1024
    {
      oversized_export: [ "stdout", "stderr" ],
      oversized_export_stderr: [ "stderr", "stdout" ]
    }.each do |mode, (oversized_stream, bounded_stream)|
      with_fixture(mode:) do |fixture|
        task = make_task(
          fixture.fetch(:dir), slug: "#{mode.to_s.tr('_', '-')}-260824-aaaa"
        )
        result = with_execution_constant(
          :EXPORT_CAPTURE_BYTES, capture_limit
        ) do
          with_env("ANTHROPIC_API_KEY" => "secret-canary") do
            build_agent(task, fixture).run!
          end
        end

        assert_equal :error, result.fetch(:status), mode
        sizes = JSON.parse(File.read(fixture.fetch(:capture_sizes)))
        assert_equal capture_limit, sizes.fetch(oversized_stream), mode
        assert_operator sizes.fetch(bounded_stream), :<, capture_limit, mode
        assert_match(/#{oversized_stream} exceeded #{capture_limit - 1} bytes/,
                     result.fetch(:inspection_diagnostic), mode)
      end
    end
  end

  def test_process_status_fallbacks_and_marker_failure_diagnostic
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "status-fallback-260812-aaaa")
      agent = build_agent(
        task, fixture, profile_status: :state_file_marker
      )
      neutral = Object.new
      neutral.define_singleton_method(:exited?) { false }
      neutral.define_singleton_method(:signaled?) { false }
      assert_nil agent.send(:process_exit_code, neutral)

      signaled = Object.new
      signaled.define_singleton_method(:signaled?) { true }
      signaled.define_singleton_method(:termsig) { 15 }
      signal = with_replaced_singleton_method(
        Signal, :signame, ->(_value) { raise ArgumentError, "unknown signal" }
      ) { agent.send(:process_signal, signaled) }
      assert_equal "15", signal

      termination = Hive::AgentRuntime::TerminationEvidence.new(exit_code: 1)
      route = Hive::AgentRuntime::Route.parse(ROUTE)
      outcome = Hive::AgentRuntime::NormalizedOutcome.new(
        provider: :opencode, launcher_identity: "opencode-cli/v1",
        kind: :configuration_failure, termination: termination,
        identity: Hive::AgentRuntime::RouteIdentity.new(
          requested: route, actual: nil, resolution_status: :unobserved
        ),
        diagnostic: "invalid selected configuration"
      )
      result = {
        provider_signal: nil, output_completed: false,
        failure_origin: nil, resource_exhaustion: nil, limit_text: nil,
        timed_out: false, normalized_outcome: outcome
      }

      agent.send(:handle_exit, result)

      assert_equal :error, result.fetch(:status)
      assert_equal "configuration_failure", result.fetch(:error_reason)
      marker = Hive::Markers.current(task.state_file)
      assert_equal :error, marker.name
      assert_equal "configuration_failure", marker.attrs.fetch("reason")

      timed_out = Hive::AgentRuntime::NormalizedOutcome.new(
        provider: :opencode, launcher_identity: "opencode-cli/v1",
        kind: :timed_out, termination: termination,
        identity: Hive::AgentRuntime::RouteIdentity.new(
          requested: route, actual: nil, resolution_status: :unobserved
        ),
        diagnostic: "UnknownError: Upstream idle timeout exceeded"
      )
      timeout_result = result.merge(normalized_outcome: timed_out)

      agent.send(:handle_exit, timeout_result)

      assert_equal :timeout, timeout_result.fetch(:status)
      assert_equal "timeout", timeout_result.fetch(:error_reason)
      timeout_marker = Hive::Markers.current(task.state_file)
      assert_equal :error, timeout_marker.name
      assert_equal "timeout", timeout_marker.attrs.fetch("reason")
      assert_equal "opencode", timeout_marker.attrs.fetch("provider")
    end
  end

  def test_completed_state_artifact_beats_empty_terminal_assistant_message
    with_fixture do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "completed-file-260812-aaaa")
      File.write(task.state_file, "# Complete plan\n<!-- COMPLETE -->\n")
      agent = build_agent(
        task, fixture, profile_status: :state_file_marker
      )
      route = Hive::AgentRuntime::Route.parse(ROUTE)
      outcome = Hive::AgentRuntime::NormalizedOutcome.new(
        provider: :opencode, launcher_identity: "opencode-cli/v1",
        kind: :malformed_output,
        termination: Hive::AgentRuntime::TerminationEvidence.new(exit_code: 0),
        identity: Hive::AgentRuntime::RouteIdentity.new(
          requested: route, actual: nil, resolution_status: :unobserved
        ),
        diagnostic: "OpenCode terminal assistant message is empty"
      )
      result = {
        provider_signal: nil, provider_error: nil, output_completed: false,
        failure_origin: nil, resource_exhaustion: nil, limit_text: nil,
        timed_out: false, exit_code: 0, normalized_outcome: outcome
      }

      agent.send(:handle_exit, result)

      assert_equal :complete, result.fetch(:status)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      refute result.key?(:error_reason)
    end
  end

  def test_export_inspection_reports_stderr_truncated_below_the_export_cap
    with_fixture(mode: :oversized_export_stderr) do |fixture|
      task = make_task(fixture.fetch(:dir), slug: "stderr-cap-260825-aaaa")
      result = with_execution_constant(:EXPORT_CAPTURE_BYTES, 16 * 1024) do
        with_runtime_constant(Hive::Agent, :FINAL_MESSAGE_TAIL_BYTES, 4 * 1024) do
          with_env("ANTHROPIC_API_KEY" => "secret-canary") do
            build_agent(task, fixture).run!
          end
        end
      end

      assert_equal :error, result.fetch(:status)
      assert_match(/stderr exceeded 4095 bytes/, result.fetch(:inspection_diagnostic))
    end
  end

  private

  def make_task(dir, slug: "opencode-agent-260812-aaaa")
    folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def build_agent(task, fixture, timeout_sec: 5,
                  explicit_launch: true, identity_only: false,
                  prompt: "make the atomic edit", plugins: [],
                  profile_status: :exit_code_only, launch_environment: {},
                  profile: nil, **agent_options)
    profile ||= Hive::AgentProfile.new(
      runtime_profile: AgentCliRuntime::Profiles.fetch(:opencode),
      skill_syntax_format: "/%{skill}",
      status_detection_mode: profile_status,
      permission_presets: %w[read-only scoped],
      support_configuration: Hive::AgentSupport::OpenCode::Configuration.new(
        configuration_path: fixture.fetch(:configuration),
        credential_environment_keys: [ "ANTHROPIC_API_KEY" ],
        plugins:
      )
    )
    profile = profile.with_overrides("bin" => fixture.fetch(:bin))
    launch = if explicit_launch
      profile.identity_arguments(model: ROUTE, effort: "high")
    end
    launch_kwargs = if identity_only
      { identity_arguments: launch.native_arguments }
    else
      { launch_arguments: launch }
    end
    options = {
      additional_read_roots: [ task.folder ],
      additional_write_roots: []
    }.merge(agent_options)
    Hive::Agent.new(
      task:, prompt:, max_budget_usd: nil,
      timeout_sec:, cwd: fixture.fetch(:work), profile:,
      permission_mode: "read-only", **launch_kwargs,
      launch_environment:, **options
    )
  end

  def with_fixture(mode: :success, default_route: nil)
    with_tmp_dir do |dir|
      work = File.join(dir, "work")
      FileUtils.mkdir_p(work)
      calls = File.join(dir, "calls.log")
      stdin = File.join(dir, "stdin.log")
      environment = File.join(dir, "environment.json")
      capture_sizes = File.join(dir, "capture-sizes.json")
      configuration = File.join(dir, "selected-config.json")
      selected_config = {
        "provider" => { "anthropic" => { "npm" => "@ai-sdk/anthropic" } }
      }
      selected_config["model"] = default_route if default_route
      File.write(configuration, JSON.generate(selected_config))
      bin = File.join(dir, "opencode")
      File.write(bin, fixture_script(
        mode:, calls:, stdin:, environment:, capture_sizes:, source_root: dir
      ))
      File.chmod(0o755, bin)
      yield({
        dir:, work:, calls:, stdin:, environment:, capture_sizes:,
        configuration:, bin:
      })
    end
  end

  def fixture_script(mode:, calls:, stdin:, environment:, capture_sizes:,
                     source_root:)
    run_help = File.read(File.join(
      source_root_for_fixtures,
      "run-help.txt"
    ))
    export_help = File.read(File.join(source_root_for_fixtures, "export-help.txt"))
    run_output = File.read(File.join(
      source_root_for_fixtures,
      mode == :malformed ? "run-malformed-json.jsonl" :
        (mode == :auth_failure ? "run-auth-error.jsonl" : "run-one-step.jsonl")
    ))
    if mode == :rate_limited
      run_output = JSON.generate(
        "type" => "error",
        "sessionID" => "ses_rate_limit",
        "error" => {
          "name" => "APIError",
          "data" => {
            "message" => "[Stealth] stealth/ox-alpha is temporarily rate-limited upstream. Please retry shortly."
          }
        }
      ) + "\n"
    end
    run_output = run_output.sub('"text":"Done."', '"text":""') if mode == :tool_only
    export_output = File.read(File.join(
      source_root_for_fixtures, "session-export-matching.json"
    ))
    <<~RUBY
      #!/usr/bin/ruby --disable-gems
      require "json"
      def record_capture_sizes(path)
        File.write(path, JSON.generate({
          "stdout" => STDOUT.stat.size, "stderr" => STDERR.stat.size
        }))
      end

      File.open(#{calls.dump}, "a") { |file| file.puts(ARGV.join(" ")) }
      case ARGV
      when ["--version"]
        puts "opencode 1.18.16"
      when ["run", "--help"]
        print #{run_help.dump}
      when ["export", "--help"]
        print #{export_help.dump}
      when ["auth", "list"]
        puts "anthropic"
      when ["models", "anthropic", "--verbose"]
        puts #{ROUTE.dump}
        puts '{"variants":{"high":{}}}'
        File.unlink(__FILE__) if #{mode == :remove_after_probe}
      else
        if ARGV.first == "run"
          File.binwrite(#{stdin.dump}, STDIN.read)
          data_home = ENV["XDG_DATA_HOME"]
          data_home = File.join(ENV.fetch("HOME"), ".local", "share") if
            data_home.to_s.empty?
          credential_path = File.join(data_home, "opencode", "auth.json")
          credential = if File.file?(credential_path)
            JSON.parse(File.binread(credential_path))
          else
            {}
          end
          File.write(#{environment.dump}, JSON.generate({
            "HOME" => ENV["HOME"],
            "XDG_CONFIG_HOME" => ENV["XDG_CONFIG_HOME"],
            "XDG_DATA_HOME" => ENV["XDG_DATA_HOME"],
            "XDG_CACHE_HOME" => ENV["XDG_CACHE_HOME"],
            "XDG_STATE_HOME" => ENV["XDG_STATE_HOME"],
            "OPENCODE_DISABLE_PROJECT_CONFIG" => ENV["OPENCODE_DISABLE_PROJECT_CONFIG"],
            "OPENCODE_CONFIG" => ENV["OPENCODE_CONFIG"],
            "OPENCODE_CONFIG_CONTENT" => ENV["OPENCODE_CONFIG_CONTENT"],
            "OPENCODE_PERMISSION" => ENV["OPENCODE_PERMISSION"],
            "selected_credential_present" => !ENV["ANTHROPIC_API_KEY"].to_s.empty?,
            "ambient_credential_present" => !ENV["OPENAI_API_KEY"].to_s.empty?,
            "native_credential_present" => File.file?(credential_path),
            "native_credential_supports_provider" => credential.key?("anthropic"),
            "native_credential_mode" =>
              (File.stat(credential_path).mode & 0777 if File.file?(credential_path))
          }))
          sleep 10 if #{%i[timeout cancelled].include?(mode)}
          print #{run_output.dump}
          warn "authentication failed" if #{mode == :auth_failure}
          exit(#{%i[auth_failure rate_limited].include?(mode) ? 1 : 0})
        elsif ARGV.first == "export"
          sleep 10 if #{mode == :inspection_timeout}
          exit 1 if #{mode == :inspection_empty_failure}
          if #{mode == :inspection_failure}
            warn "export unavailable"
            exit 1
          end
          if #{mode == :inspection_requires_regular_file} &&
             !STDOUT.stat.file?
            print #{export_output.byteslice(0, export_output.bytesize / 2).dump}
            exit 0
          end
          export_calls = File.readlines(#{calls.dump}).count do |line|
            line.start_with?("export ses_")
          end
          if #{mode == :inspection_malformed} ||
             (#{mode == :inspection_malformed_once} && export_calls == 1)
            print #{export_output.byteslice(0, export_output.bytesize / 2).dump}
            exit 0
          end
          if #{mode == :large_export}
            export = JSON.parse(#{export_output.dump})
            export["bounded_test_padding"] = "x" * (5 * 1024 * 1024)
            print JSON.generate(export)
          elsif #{mode == :oversized_export}
            Signal.trap("XFSZ", "IGNORE") if Signal.list.key?("XFSZ")
            export = JSON.parse(#{export_output.dump})
            export["bounded_test_padding"] = "x" * (8 * 1024)
            begin
              print JSON.generate(export)
            rescue Errno::EFBIG
              nil
            end
            STDOUT.flush
            record_capture_sizes(#{capture_sizes.dump})
          elsif #{mode == :oversized_export_stderr}
            Signal.trap("XFSZ", "IGNORE") if Signal.list.key?("XFSZ")
            begin
              STDERR.write("x" * (8 * 1024))
            rescue Errno::EFBIG
              nil
            end
            print #{export_output.dump}
            STDOUT.flush
            STDERR.flush
            record_capture_sizes(#{capture_sizes.dump})
          else
            print #{export_output.dump}
          end
        else
          warn "unexpected argv: #{ARGV.inspect}"
          exit 64
        end
      end
    RUBY
  end

  def source_root_for_fixtures
    File.expand_path(
      "../../components/agent-cli-runtime/test/fixtures/opencode/v1.18.16",
      __dir__
    )
  end

  def with_execution_constant(name, replacement)
    with_runtime_constant(Hive::AgentSupport::OpenCode::Execution, name, replacement) do
      yield
    end
  end

  def with_runtime_constant(owner, name, replacement)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end
end
