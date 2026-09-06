module Hive
  module AgentSupport
    module OpenCode
      module Execution
        NativeLaunch = Data.define(
          :invocation, :requested_route, :environment, :executable
        )
        RUN_CAPTURE_BYTES = AgentCliRuntime::OpenCode::ResultParser::MAX_RUN_BYTES + 1
        EXPORT_CAPTURE_BYTES = AgentCliRuntime::OpenCode::ResultParser::MAX_EXPORT_BYTES + 1
        INSPECTION_TIMEOUT_SECONDS = 60
        INSPECTION_JSON_ATTEMPTS = 3
        INSPECTION_RETRY_DELAY_SECONDS = 0.5
        CAPTURE_DRAIN_SECONDS = 30

        def run_supported
          launch = prepare_native_invocation
          validate_native_skills!(launch)
          command = launch.invocation.argv
          log_file = log_path
          write_spawn_log(log_file, launch, command)
          run = capture_process(
            argv: command,
            environment: effective_native_environment(launch.environment),
            stdin_data: launch.invocation.stdin_data,
            stdout_limit: RUN_CAPTURE_BYTES,
            stderr_limit: self.class::FINAL_MESSAGE_TAIL_BYTES,
            record_spawn: true,
            forward_signals: @terminate_on_parent_signal,
            drain_timeout: CAPTURE_DRAIN_SECONDS
          )
          provider_error = write_capture_log(log_file, run.stdout, run.stderr)
          inspection_output, inspection_diagnostic = inspect_run(launch, run)
          captured = Hive::AgentRuntime::CapturedResult.new(
            stdout: run.stdout,
            stderr: run.stderr,
            termination: run.termination,
            inspection_output:
          )
          outcome = Hive::AgentRuntime.normalize(
            @profile, captured, requested_route: launch.requested_route
          )
          result = result_hash(
            run, outcome, inspection_diagnostic, log_file, provider_error
          )
        end

        private

        def prepare_native_invocation
          validate_launch_channels!
          configuration = @profile.support_configuration
          route = requested_route(configuration)
          executable = @runtime_policy&.executable || @profile.bin
          executable = isolated_executable(executable) if @isolate_environment
          invocation = Hive::AgentRuntime.compile(Hive::AgentRuntime::Request.new(
            profile: @profile,
            prompt: @prompt,
            permission_mode: @permission_mode,
            permission_arguments: [ "--auto" ],
            add_dirs: @add_dirs,
            allowed_tools: @allowed_tools,
            disallowed_tools: @disallowed_tools,
            max_budget_usd: @max_budget_usd,
            identity_arguments: @identity_arguments,
            routing_arguments: @routing_arguments,
            raw_cli_arguments: @cli_flags,
            trusted_cli_arguments: [ *@runtime_cli_flags, "--dir", @cwd ],
            executable:,
            command_prefix: effective_command_prefix
          ))
          NativeLaunch.new(
            invocation:,
            requested_route: route,
            environment: native_environment(configuration),
            executable:
          )
        end

        def validate_native_skills!(launch)
          configuration = @profile.support_configuration
          invocations = skill_invocations
          invocations.each do |invocation|
            resolution = Hive::AgentSupport::OpenCode::Skills.resolve(
              invocation,
              project_root: @cwd,
              environment: effective_native_environment(launch.environment),
              configuration_path: configuration.configuration_path,
              configuration: configuration.configuration,
              plugins: configuration.plugins
            )
            next if resolution.status == :present

            raise Hive::AgentError,
                  "OpenCode native skill readiness failed for #{invocation}: " \
                  "#{resolution.message}"
          end
        end

        def validate_launch_channels!
          unless @cli_flags.empty? && @runtime_cli_flags.empty?
            raise Hive::ConfigError,
                  "OpenCode does not accept opaque CLI arguments through Hive"
          end
          if @allowed_tools || @disallowed_tools
            raise Hive::ConfigError,
                  "OpenCode tool access must come from its native permission policy"
          end
        end

        def requested_route(configuration)
          model = @routing_arguments&.model || @launch_arguments&.model ||
            identity_argument("--model")
          model ||= configured_default_route(configuration)
          Hive::AgentRuntime::Route.parse(model)
        end

        def configured_default_route(configuration)
          inline = configuration.configuration
          return inline["model"] if inline&.key?("model")
          return unless configuration.configuration_path

          document = JSON.parse(File.binread(configuration.configuration_path))
          document["model"] if document.is_a?(Hash)
        rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
          nil
        end

        def identity_argument(flag)
          index = @identity_arguments.rindex(flag)
          @identity_arguments[index + 1] if index && index < @identity_arguments.length - 1
        end

        def native_environment(configuration)
          environment = @child_environment.dup
          configuration.credential_environment_keys.each do |key|
            value = selected_credential_value(key)
            environment[key] = value unless value.to_s.empty?
          end
          if configuration.configuration_path
            environment["OPENCODE_CONFIG"] = configuration.configuration_path
          end
          content = native_configuration_content(configuration)
          environment["OPENCODE_CONFIG_CONTENT"] = JSON.generate(content) unless content.empty?
          permission = AgentCliRuntime::OpenCode::Permissions.compile(
            permission_mode: @permission_mode,
            permission_policy: @permission_policy,
            working_directory: @cwd,
            additional_read_roots: @additional_read_roots,
            additional_write_roots: @additional_write_roots,
            edit_patterns: @edit_patterns,
            bash_patterns: @bash_patterns,
            plugins: skill_invocations.empty? ? [] : [ "native" ]
          )
          environment["OPENCODE_PERMISSION"] = JSON.generate(permission) if permission
          environment.freeze
        end

        def effective_native_environment(overrides)
          return overrides if @runtime_policy || @isolate_environment

          ENV.to_h.merge(overrides)
        end

        def native_configuration_content(configuration)
          content = if configuration.configuration
            JSON.parse(JSON.generate(configuration.configuration))
          else
            {}
          end
          content["plugin"] = configuration.plugins.dup unless configuration.plugins.empty?
          content
        end

        def skill_invocations
          @opencode_skill_invocations ||=
            @prompt.scan(%r{/(?:[A-Za-z0-9_.-]+:)?ce-[a-z0-9-]+}).uniq.freeze
        end

        def selected_credential_value(key)
          return @launch_environment[key] if @launch_environment.key?(key)

          ENV[key]
        end

        def inspect_run(launch, run)
          return [ nil, nil ] unless run.termination.success?

          parsed = Hive::AgentRuntime.parse_run(@profile, stdout: run.stdout)
          inspection = Hive::AgentRuntime::InspectionCommand.new(
            argv: [
              *effective_command_prefix,
              launch.executable, "export", parsed.session_id, "--sanitize"
            ],
            environment: launch.environment,
            credential_environment_keys: [],
            session_id: parsed.session_id,
            message_id: parsed.terminal_message_id
          )
          INSPECTION_JSON_ATTEMPTS.times do |attempt|
            captured = capture_process_files(
              argv: inspection.argv,
              environment: effective_native_environment(inspection.environment),
              file_limit: EXPORT_CAPTURE_BYTES,
              stderr_limit: self.class::FINAL_MESSAGE_TAIL_BYTES,
              timeout_sec: INSPECTION_TIMEOUT_SECONDS
            )
            unless captured.termination.success? &&
                   !captured.stdout_truncated && !captured.stderr_truncated
              return [ nil, inspection_failure(captured) ]
            end

            begin
              JSON.parse(captured.stdout)
              return [ captured.stdout, nil ]
            rescue JSON::ParserError => error
              if attempt + 1 == INSPECTION_JSON_ATTEMPTS
                message = "OpenCode sanitized export remained malformed after " \
                          "#{INSPECTION_JSON_ATTEMPTS} attempts: #{error.message}"
                return [ nil, AgentCliRuntime::Redactor.diagnostic(message) ]
              end
              sleep(INSPECTION_RETRY_DELAY_SECONDS * (attempt + 1))
            end
          end
        rescue AgentCliRuntime::MalformedOutput => error
          [ nil, AgentCliRuntime::Redactor.diagnostic(error) ]
        end

        def inspection_failure(captured)
          message = if captured.termination.timed_out
            "OpenCode sanitized export inspection timed out after " \
              "#{INSPECTION_TIMEOUT_SECONDS} seconds"
          elsif captured.stdout_truncated
            "OpenCode sanitized export inspection stdout exceeded " \
              "#{EXPORT_CAPTURE_BYTES - 1} bytes"
          elsif captured.stderr_truncated
            "OpenCode sanitized export inspection stderr exceeded " \
              "#{[ EXPORT_CAPTURE_BYTES, self.class::FINAL_MESSAGE_TAIL_BYTES ].min - 1} bytes"
          elsif captured.stderr.empty?
            "OpenCode sanitized export inspection failed"
          else
            captured.stderr
          end
          AgentCliRuntime::Redactor.diagnostic(message)
        end

        def result_hash(run, outcome, inspection_diagnostic, log_file, provider_error)
          termination = run.termination
          {
            pid: run.pid,
            pgid: run.pgid,
            exit_code: termination.exit_code,
            timed_out: termination.timed_out,
            cancelled: termination.cancelled,
            log_file:,
            final_message: outcome.final_message,
            final_message_source: :opencode_terminal_message,
            final_message_truncated: outcome.final_message_truncated,
            limit_text: provider_error && provider_limit_status?(provider_error) ?
              provider_error[:message].to_s : nil,
            usage: usage(outcome),
            model: outcome.identity.actual&.to_s,
            requested_route: outcome.identity.requested.to_s,
            actual_route: outcome.identity.actual&.to_s,
            route_resolution_status: outcome.identity.resolution_status,
            normalized_outcome_kind: outcome.kind,
            normalized_outcome: outcome,
            inspection_diagnostic:,
            unknown_event_summaries: outcome.unknown_events,
            resource_exhaustion: nil,
            output_completed: outcome.completed?,
            provider_signal: nil,
            provider_error:,
            status: nil
          }
        end

        def usage(outcome)
          value = outcome.usage or return
          {
            input: value.input, output: value.output, cached: value.cached,
            cache_read: value.cache_read, cache_write: value.cache_write,
            reasoning: value.reasoning,
            input_includes_cache_read: value.input_includes_cache_read,
            input_includes_cache_write: value.input_includes_cache_write,
            output_includes_reasoning: value.output_includes_reasoning,
            provider_reported_cost: value.provider_reported_cost,
            cost: value.provider_reported_cost,
            model: outcome.identity.actual&.to_s
          }.freeze
        end

        def write_spawn_log(log_file, launch, command)
          open_private_log(log_file) do |log|
            log.puts "[hive] #{Time.now.utc.iso8601} spawn " \
                     "cwd=#{Hive::SecretPatterns.redact(@cwd)} " \
                     "profile=opencode executable=#{File.basename(launch.executable)} " \
                     "argc=#{command.length}#{launch_identity_log_fields}"
          end
        end

        def write_capture_log(log_file, stdout, stderr)
          provider_error = nil
          open_private_log(log_file) do |log|
            stdout.each_line do |line|
              event = parse_json_line(line)
              provider_error ||= Hive::AgentRuntime.extract_provider_error(
                @profile, event
              ) if event
              type = event.is_a?(Hash) ? event.fetch("type", "unknown") : "malformed"
              log.puts "[opencode event omitted type=#{type}]"
            end
            stderr.each_line do |line|
              log.write("[stderr] #{Time.now.utc.iso8601} #{Hive::SecretPatterns.redact(line)}")
              log.write("\n") unless line.end_with?("\n")
            end
          end
          provider_error
        end
      end
    end
  end
end
