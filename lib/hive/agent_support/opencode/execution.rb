require "securerandom"
require "tmpdir"

module Hive
  module AgentSupport
    module OpenCode
      module Execution
        RUN_CAPTURE_BYTES = AgentCliRuntime::OpenCode::ResultParser::MAX_RUN_BYTES + 1
        EXPORT_CAPTURE_BYTES = AgentCliRuntime::OpenCode::ResultParser::MAX_EXPORT_BYTES + 1
        INSPECTION_TIMEOUT_SECONDS = 60
        INSPECTION_JSON_ATTEMPTS = 3
        INSPECTION_RETRY_DELAY_SECONDS = 0.5
        CAPTURE_DRAIN_SECONDS = 30

        def run_supported
          prepared = prepare_invocation
          validate_prepared_skills!(prepared)
          command = prepared.invocation.argv
          log_file = log_path
          write_spawn_log(log_file, prepared, command)
          run = capture_process(
            argv: command,
            environment: child_environment(prepared),
            stdin_data: prepared.invocation.stdin_data,
            stdout_limit: RUN_CAPTURE_BYTES,
            stderr_limit: self.class::FINAL_MESSAGE_TAIL_BYTES,
            record_spawn: true,
            forward_signals: true,
            drain_timeout: CAPTURE_DRAIN_SECONDS
          )
          write_capture_log(log_file, run.stdout, run.stderr)
          inspection_output, inspection_diagnostic = inspect_run(prepared, run)
          captured = Hive::AgentRuntime::CapturedResult.new(
            stdout: run.stdout,
            stderr: run.stderr,
            termination: run.termination,
            inspection_output:
          )
          outcome = Hive::AgentRuntime.normalize(
            @profile, captured, requested_route: prepared.requested_route
          )
          result = result_hash(
            prepared, run, outcome, inspection_diagnostic, log_file
          )
        ensure
          cleanup_preparation(prepared, result)
        end

        private

        def prepare_invocation
          validate_launch_channels!
          model, effort = route_and_effort
          configuration = @profile.support_configuration
          request = AgentCliRuntime::Request.new(
            profile: @profile.runtime_profile,
            prompt: @prompt,
            permission_mode: @permission_mode,
            model:,
            effort:,
            executable: isolated_executable(
              @runtime_policy&.executable || @profile.bin
            ),
            command_prefix: @runtime_policy&.command_prefix || []
          )
          root = @invocation_root || File.join(
            Dir.tmpdir, "hive-opencode-#{Process.pid}-#{SecureRandom.hex(12)}"
          )
          preparation = Hive::AgentRuntime::OpenCodePreparationRequest.new(
            request:,
            working_directory: @cwd,
            invocation_root: root,
            configuration_path: configuration.configuration_path,
            configuration: configuration.configuration,
            credential_environment_keys: configuration.credential_environment_keys,
            credential_file: configuration.credential_file,
            permission_policy: @permission_policy,
            additional_read_roots: @additional_read_roots,
            additional_write_roots: @additional_write_roots,
            edit_patterns: @edit_patterns,
            bash_patterns: @bash_patterns,
            plugins: configuration.plugins,
            pure: configuration.pure
          )
          Hive::AgentRuntime.prepare!(preparation, env: preparation_environment)
        end

        def validate_prepared_skills!(prepared)
          invocations = @prompt.scan(
            %r{/(?:[A-Za-z0-9_.-]+:)?ce-[a-z0-9-]+}
          ).uniq
          environment = prepared.environment_for(env: preparation_environment)
          invocations.each do |invocation|
            resolution = Hive::AgentSupport::OpenCode::Skills.resolve(
              invocation,
              project_root: @cwd,
              environment:,
              configuration_path: prepared.configuration_path
            )
            next if resolution.status == :present

            raise Hive::AgentError,
                  "OpenCode prepared skill readiness failed for #{invocation}: " \
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
                  "OpenCode tool access must come from its typed permission overlay"
          end
          declared = (
            @additional_read_roots + @additional_write_roots + [ @cwd ]
          ).map { |path| File.expand_path(path) }
          omitted = @add_dirs.reject do |path|
            declared.include?(File.expand_path(path))
          end
          return if omitted.empty?

          raise Hive::ConfigError,
                "OpenCode additional directories require explicit read/write roots"
        end

        def route_and_effort
          model = @routing_arguments&.model || @launch_arguments&.model ||
            identity_argument("--model")
          effort = @routing_arguments&.effort ||
            @launch_arguments&.effective_effort || identity_argument("--variant")
          [ model, effort ]
        end

        def identity_argument(flag)
          index = @identity_arguments.rindex(flag)
          @identity_arguments[index + 1] if index && index < @identity_arguments.length - 1
        end

        def preparation_environment
          base_environment.tap do |environment|
            @profile.support_configuration.credential_environment_keys.each do |key|
              value = @launch_environment.key?(key) ? @launch_environment[key] : ENV[key]
              environment[key] = value unless value.to_s.empty?
            end
          end
        end

        def child_environment(prepared)
          prepared.environment_for(env: preparation_environment)
            .merge(base_environment).freeze
        end

        def base_environment
          %w[HOME LANG LC_ALL LOGNAME PATH SHELL SSL_CERT_DIR SSL_CERT_FILE USER]
            .each_with_object({}) do |key, environment|
              value = @launch_environment.key?(key) ? @launch_environment[key] : ENV[key]
              environment[key] = value.to_s unless value.to_s.empty?
            end
        end

        def inspect_run(prepared, run)
          return [ nil, nil ] unless run.termination.success?

          parsed = Hive::AgentRuntime.parse_run(@profile, stdout: run.stdout)
          inspection = Hive::AgentRuntime.prepare_inspection(prepared, parsed)
          INSPECTION_JSON_ATTEMPTS.times do |attempt|
            captured = capture_process_files(
              argv: inspection.argv,
              environment: inspection.environment_for(env: preparation_environment)
                .merge(base_environment),
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
              "#{EXPORT_CAPTURE_BYTES - 1} bytes"
          elsif captured.stderr.empty?
            "OpenCode sanitized export inspection failed"
          else
            captured.stderr
          end
          AgentCliRuntime::Redactor.diagnostic(message)
        end

        def result_hash(prepared, run, outcome, inspection_diagnostic, log_file)
          termination = run.termination
          provider_error = provider_error(run.stdout)
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
            status: nil,
            invocation_root: prepared.invocation_root
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

        def provider_error(stdout)
          stdout.each_line do |line|
            event = parse_json_line(line)
            next unless event

            error = Hive::AgentRuntime.extract_provider_error(@profile, event)
            return error if error
          end
          nil
        end

        def write_spawn_log(log_file, prepared, command)
          open_private_log(log_file) do |log|
            log.puts "[hive] #{Time.now.utc.iso8601} spawn " \
                     "cwd=#{Hive::SecretPatterns.redact(@cwd)} " \
                     "profile=opencode executable=#{File.basename(prepared.executable)} " \
                     "argc=#{command.length}#{launch_identity_log_fields}"
          end
        end

        def write_capture_log(log_file, stdout, stderr)
          open_private_log(log_file) do |log|
            stdout.each_line do |line|
              event = parse_json_line(line)
              type = event.is_a?(Hash) ? event.fetch("type", "unknown") : "malformed"
              log.puts "[opencode event omitted type=#{type}]"
            end
            stderr.each_line do |line|
              log.write("[stderr] #{Time.now.utc.iso8601} #{Hive::SecretPatterns.redact(line)}")
              log.write("\n") unless line.end_with?("\n")
            end
          end
        end

        def cleanup_preparation(prepared, result)
          return unless prepared

          prepared.cleanup!
          result[:cleanup_completed] = true if result
        rescue StandardError => error
          diagnostic = AgentCliRuntime::Redactor.diagnostic(error)
          if result
            result[:cleanup_completed] = false
            result[:cleanup_error] = diagnostic
          end
          warn "[hive] OpenCode cleanup failed: #{diagnostic}"
        end
      end
    end
  end
end
