require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "time"
require "tmpdir"
require "hive/agent_runtime"
require "hive/agent_profiles"
require "hive/agent_profiles/error_normalizers"
require "hive/agent_limit"
require "hive/agent/message_extractor"
require "hive/artifact_firewall"
require "hive/events"
require "hive/lock"
require "hive/permission_scope"
require "hive/secret_patterns"

module Hive
  class Agent
    FINAL_MESSAGE_TAIL_BYTES = 64 * 1024
    TERMINATION_GRACE_SECONDS = 3
    COMPLETION_EVENT_GRACE_SECONDS = 3
    OPENCODE_INSPECTION_TIMEOUT_SECONDS = 10
    OPENCODE_CAPTURE_BYTES =
      AgentCliRuntime::OpenCode::ResultParser::MAX_RUN_BYTES + 1
    TOKEN_LIMIT_REASON = "token_limit".freeze
    TURN_LIMIT_REASON = "turn_limit".freeze
    MODEL_OUTPUT_LIMIT_REASON = "model_output_limit".freeze

    # Converts provider JSONL usage events into one monotonic in-flight count.
    # Claude reports input/cache at message_start and cumulative output for the
    # current turn at message_delta; treating each event as an independent row
    # would double count output. Other profiles are conservatively accumulated
    # until they emit a terminal run-total event.
    class StreamTokenMeter
      TERMINAL_TYPES = %w[result turn.completed response.completed run.completed task.completed].freeze

      attr_reader :total

      def initialize(profile_name)
        @profile_name = profile_name.to_sym
        @total = 0
        @usage = { input: 0, output: 0, cached: 0, model: nil }
        @completed_claude = { input: 0, output: 0, cached: 0 }
        @claude_turn = nil
      end

      def observe(event, usage)
        return @total unless usage.is_a?(Hash)

        @usage[:model] = usage[:model] unless usage[:model].to_s.empty?
        if terminal?(event)
          replace_with_run_total(usage)
        elsif claude_stream?(event)
          observe_claude_stream(event, usage)
        else
          add_usage(usage)
        end
        @total
      end

      def terminal?(event)
        event.is_a?(Hash) && TERMINAL_TYPES.include?(event["type"].to_s)
      end

      def usage
        @usage.dup
      end

      private

      def claude_stream?(event)
        @profile_name == :claude && event["type"] == "stream_event"
      end

      def observe_claude_stream(event, usage)
        kind = event.dig("event", "type").to_s
        if kind == "message_start"
          finish_claude_turn
          @claude_turn = usage_counts(usage)
        else
          @claude_turn ||= { input: 0, output: 0, cached: 0 }
          counts = usage_counts(usage)
          @claude_turn[:input] = [ @claude_turn[:input], counts[:input] ].max
          @claude_turn[:output] = [ @claude_turn[:output], counts[:output] ].max
          @claude_turn[:cached] = [ @claude_turn[:cached], counts[:cached] ].max
        end
        refresh_claude_total
      end

      def finish_claude_turn
        return unless @claude_turn

        %i[input output cached].each do |key|
          @completed_claude[key] += @claude_turn[key]
        end
      end

      def refresh_claude_total
        counts = @completed_claude.dup
        if @claude_turn
          %i[input output cached].each { |key| counts[key] += @claude_turn[key] }
        end
        @usage.merge!(counts)
        @total = counts.values_at(:input, :output).sum
      end

      def add_usage(usage)
        counts = usage_counts(usage)
        %i[input output cached].each { |key| @usage[key] += counts[key] }
        @total = @usage.values_at(:input, :output).sum
      end

      def replace_with_run_total(usage)
        counts = usage_counts(usage)
        terminal_total = counts.values_at(:input, :output).sum
        return if terminal_total < @total

        @usage.merge!(counts)
        @total = terminal_total
      end

      def usage_counts(usage)
        {
          input: [ usage[:input].to_i, 0 ].max,
          output: [ usage[:output].to_i, 0 ].max,
          cached: [ usage[:cached].to_i, 0 ].max
        }
      end
    end

    # Screenote's base URL reaches the agent as prompt/MCP-config context,
    # not as a child-environment input. nil unsets the var for the child so
    # an operator's exported HIVE_SCREENOTE_BASE_URL can't become a
    # redundant, unvalidated second source that overrides hive's chosen
    # base_url. Mirrors the tmux path's blanking in
    # Hive::ClaudeLauncher.build_runner and the wrapper's `unset`.
    SCRUBBED_CHILD_ENV = {
      "HIVE_SCREENOTE_BASE_URL" => nil
    }.freeze
    ISOLATED_CHILD_ENV_KEYS = %w[
      HOME PATH LANG LC_ALL LC_CTYPE TMPDIR TZ SSL_CERT_FILE SSL_CERT_DIR
      XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
      DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS TERM COLORTERM
    ].freeze

    attr_reader :task, :prompt, :add_dirs, :cwd, :max_budget_usd, :max_tokens, :max_turns, :timeout_sec,
                :profile, :expected_output, :status_mode, :permission_mode,
                :runtime_policy, :child_environment, :observable_result

    def initialize(task:, prompt:, max_budget_usd:, timeout_sec:,
                   add_dirs: [], cwd: nil, log_label: nil,
                   profile: nil, expected_output: nil, status_mode: nil,
                   permission_mode: nil, permission_arguments: nil, allowed_tools: nil,
                   disallowed_tools: nil, cli_flags: [], max_tokens: nil,
                   max_turns: nil, identity_arguments: [], runtime_policy: nil,
                   launch_arguments: nil, routing_arguments: nil,
                   launch_environment: {}, provider_route: nil, log_stream: true,
                   opencode_invocation_root: nil,
                   opencode_permission_policy: nil,
                   additional_read_roots: [], additional_write_roots: [],
                   opencode_edit_patterns: [],
                   isolate_environment: false)
      @task = task
      @prompt = prompt
      @add_dirs = Array(add_dirs)
      @cwd = cwd || task.folder
      @max_budget_usd = max_budget_usd
      @max_tokens = normalize_max_tokens(max_tokens)
      @max_turns = normalize_max_turns(max_turns)
      @timeout_sec = timeout_sec
      @log_label = log_label || task.stage_name
      @log_stream = log_stream
      @profile = profile || Hive::AgentProfiles.lookup(:claude)
      @provider_route = provider_route
      @launch_environment = (launch_environment || {}).dup.freeze
      @opencode_invocation_root = opencode_invocation_root&.to_s
      @opencode_permission_policy = opencode_permission_policy
      @additional_read_roots = Array(additional_read_roots).map(&:to_s).freeze
      @additional_write_roots = Array(additional_write_roots).map(&:to_s).freeze
      @opencode_edit_patterns = Array(opencode_edit_patterns).map(&:to_s).freeze
      @runtime_policy = runtime_policy
      if runtime_policy && permission_arguments
        raise ArgumentError, "permission_arguments cannot be combined with runtime_policy"
      end
      @permission_arguments = permission_arguments && Array(permission_arguments).map do |argument|
        argument.to_s.dup.freeze
      end.freeze
      @isolate_environment = isolate_environment == true
      @expected_output = expected_output
      # Per-spawn override of the profile's default detection mode. The
      # same CLI (e.g., claude) serves multiple roles — 4-execute uses
      # :state_file_marker (agent writes terminal marker to task.md);
      # the 6-review reviewer adapter uses :output_file_exists (agent
      # writes a structured findings file). Passing nil falls back to
      # the profile's default. Validation lives in AgentProfile's enum.
      if status_mode && !Hive::AgentProfile::STATUS_DETECTION_MODES.include?(status_mode)
        raise ArgumentError,
              "unknown status_mode: #{status_mode.inspect}; valid: #{Hive::AgentProfile::STATUS_DETECTION_MODES.inspect}"
      end
      @status_mode = status_mode
      if @runtime_policy
        @permission_mode = @runtime_policy.permission_mode
        @allowed_tools = @runtime_policy.allowed_tools
        @disallowed_tools = @runtime_policy.disallowed_tools
        @add_dirs = @runtime_policy.agent_add_dirs
        @cli_flags = Array(cli_flags)
        @runtime_cli_flags = @runtime_policy.cli_flags
        @child_environment = @runtime_policy.environment.merge(SCRUBBED_CHILD_ENV)
      else
        @permission_mode = permission_mode
        @allowed_tools = allowed_tools
        @disallowed_tools = disallowed_tools
        @cli_flags = Array(cli_flags)
        @runtime_cli_flags = []
        @child_environment = if @isolate_environment
          ISOLATED_CHILD_ENV_KEYS.each_with_object({}) do |key, environment|
            value = ENV[key]
            environment[key] = value if value && !value.empty?
          end.merge(SCRUBBED_CHILD_ENV)
        else
          SCRUBBED_CHILD_ENV
        end
      end
      @child_environment = @child_environment
        .merge(@launch_environment)
        .merge(@profile.subscription_environment)
        .freeze
      @launch_arguments = normalize_launch_arguments(launch_arguments)
      supplied_identity_arguments =
        Hive::ImplementationIdentity.validate_native_arguments(identity_arguments)
      if @launch_arguments
        unless supplied_identity_arguments.empty? ||
               supplied_identity_arguments == @launch_arguments.native_arguments
          raise ArgumentError,
                "launch_arguments and identity_arguments describe different native argv"
        end
        supplied_identity_arguments = @launch_arguments.native_arguments
      end
      if routing_arguments && (@launch_arguments || !supplied_identity_arguments.empty?)
        raise ArgumentError,
              "routing_arguments cannot be combined with legacy identity or launch arguments"
      end
      @identity_arguments = supplied_identity_arguments.freeze
      @routing_arguments =
        routing_arguments && @profile.validate_routing_arguments!(routing_arguments)
    end

    # Effective mode for this spawn — explicit kwarg wins, falls back to
    # the profile's default.
    def effective_status_mode
      @status_mode || @profile.status_detection_mode
    end

    # Backward-compat class methods. Resolve to the claude profile so legacy
    # call sites (Hive::Agent.bin, Hive::Agent.check_version!) keep working.
    #
    # Caveat (correctness finding #11): these methods bypass per-spawn
    # profile selection and ALWAYS resolve to the claude profile —
    # misleading on a project running codex/pi. Pass an explicit
    # profile: kwarg into Hive::Stages::Base.spawn_agent or call
    # `Hive::AgentProfiles.lookup(:codex).bin` / `.check_version!`
    # directly when the agent isn't claude. The methods are retained
    # as smoke-test / fixture conveniences only.
    def self.bin
      maybe_warn_legacy_class_method(:bin)
      Hive::AgentProfiles.lookup(:claude).bin
    end

    def self.check_version!
      maybe_warn_legacy_class_method(:check_version!)
      Hive::AgentProfiles.lookup(:claude).check_version!
    end

    # Emit a one-shot deprecation warning the first time either legacy
    # class method is called from outside the test suite. Suppress in
    # tests so the existing assertion suite (which exercises the
    # backward-compat shim by design) doesn't churn captured stderr.
    @legacy_warned = {}
    def self.maybe_warn_legacy_class_method(name)
      return if ENV["HIVE_TEST"] == "1"
      return if defined?(Minitest)
      return if @legacy_warned[name]

      @legacy_warned[name] = true
      warn "Hive::Agent.#{name} is claude-specific and ignores AgentProfile " \
           "selection; pass profile: explicitly or use AgentProfiles.lookup(:<name>).#{name}"
    end

    def run!
      ensure_log_dir
      emit_agent_event(:agent_start, message: agent_start_message)
      result = nil
      # Marker writes on task.state_file are gated by the profile's
      # status_detection_mode. Only the :state_file_marker mode (today's
      # claude path for 4-execute / brainstorm / plan / pr) writes
      # :agent_working pre-spawn — the agent itself overwrites it with
      # the terminal marker on exit. The other two modes do NOT write
      # the task marker because the orchestrator owns it (e.g., the
      # 6-review runner sets REVIEW_WORKING phase=reviewers and that
      # must persist across each per-reviewer spawn).
      if effective_status_mode == :state_file_marker
        Hive::Markers.set(@task.state_file, :agent_working,
                          pid: Process.pid,
                          started: Time.now.utc.iso8601)
      end
      result = spawn_and_wait
      handle_exit(result)
      @observable_result = Hive::AgentRuntime.observe(@profile, result)
      result
    ensure
      emit_agent_event(:agent_end, message: agent_end_message(result, $!))
    end

    def spawn_and_wait
      return spawn_opencode_and_wait if opencode?

      cmd = build_cmd
      log_file = log_path
      structured_output_protocol = @profile.structured_output_protocol
      messages = Hive::Agent::MessageExtractor::Accumulator.new(
        max_bytes: FINAL_MESSAGE_TAIL_BYTES,
        structured_output_protocol: structured_output_protocol,
        require_terminal_structured_output: @runtime_policy&.host_outputs? == true
      )
      limit_text = nil
      structured_failure = nil
      last_usage = nil
      token_meter = StreamTokenMeter.new(@profile.name)
      resource_exhaustion = nil
      provider_signal = nil
      provider_error = nil
      termination_deadline = nil
      completion_event_deadline = nil
      completed_turns = 0
      output_completed = false
      write_tool_in_current_turn = false
      write_turn_completed = false
      stdin_file = prompt_stdin_file
      open_private_log(log_file) do |log|
        # Never serialize argv: for positional-prompt profiles it contains the
        # complete task prompt, and even stdin profiles may carry sensitive
        # identity/config arguments. Operational metadata is enough to debug
        # which runner launched.
        log.puts "[hive] #{Time.now.utc.iso8601} spawn " \
                 "cwd=#{Hive::SecretPatterns.redact(@cwd)} " \
                 "profile=#{@profile.name} executable=#{File.basename(cmd.first.to_s)} argc=#{cmd.length}" \
                 "#{launch_identity_log_fields}"
      end
      r, w = IO.pipe
      spawn_opts = { chdir: @cwd, pgroup: true, out: w, err: w }
      spawn_opts[:unsetenv_others] = true if @runtime_policy || @isolate_environment
      spawn_opts[:in] = stdin_file if stdin_file
      pid = Process.spawn(@child_environment, *cmd, **spawn_opts)
      w.close
      pgid = begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end

      Hive::Lock.update_task_lock(
        @task.folder,
        "claude_pid" => pid,
        "claude_pid_start_time" => Hive::Lock.process_start_time(pid)
      )

      old_int = install_chained_signal_trap("INT") { kill_group(pgid) }
      old_term = install_chained_signal_trap("TERM") { kill_group(pgid) }

      reader = Thread.new do
        open_private_log(log_file) do |log|
          r.each_line do |line|
            # IO#each_line is the boundary buffer: provider writes can split a
            # credential across arbitrary stdout/stderr chunks, but both
            # streams share this pipe and are assembled before any bytes reach
            # the durable log. Structured message events are different: one
            # logical message can span multiple newline-delimited JSON events,
            # so per-line regex redaction cannot safely retain their payloads.
            json = parse_json_line(line)
            provider_signal ||= Hive::AgentProfiles::ErrorNormalizers.normalize(
              adapter: @profile.name,
              event: json,
              route: @provider_route
            ) if @provider_route
            sensitive_payload = Hive::Agent::MessageExtractor.sensitive_payload?(
              json,
              raw_line: line,
              structured_output_protocol: structured_output_protocol
            )
            message = messages.observe(json, raw_line: line)
            if structured_failure.nil? && @profile.name == :claude
              structured_failure = Hive::Agent::MessageExtractor.extract_failure(json)
            end
            if @log_stream
              safe_line = if message || sensitive_payload
                event_type = json.is_a?(Hash) ? json.fetch("type", "unknown") : "end"
                "[structured message omitted type=#{event_type}]\n"
              else
                Hive::SecretPatterns.redact(line)
              end
              log.write("[stream] #{Time.now.utc.iso8601} #{safe_line}")
              log.write("\n") unless safe_line.end_with?("\n")
              log.flush
            end
            # Capture a usage/credit-limit signal straight from the raw stream.
            # Some CLIs (notably codex) report "you've hit your usage limit" as a
            # structured {"type":"error",...} / turn.failed JSON event that
            # MessageExtractor does not surface as a final message — so without
            # scanning the raw line the limit text never reaches handle_exit and
            # the run is misreported as a generic failure (exit_code=1).
            # Ask the profile first: it owns its CLI's shape. pi keeps the
            # envelope type ("message_start") and moves a refused turn into
            # stopReason/errorMessage, so the type-based scan below never sees
            # it — the run then reads as a clean exit 0 that produced nothing,
            # and a quota wall gets misreported as invalid agent output.
            event_provider_error = if provider_error.nil? && !sensitive_payload
              Hive::AgentRuntime.extract_provider_error(@profile, json)
            end
            provider_error ||= event_provider_error
            if limit_text.nil? && !sensitive_payload
              if event_provider_error && provider_limit_status?(event_provider_error)
                limit_text = event_provider_error[:message].to_s.strip
              elsif provider_limit_candidate?(json) && Hive::AgentLimit.limit_reached?(line)
                detail = json && (json["message"] || (json["error"].is_a?(Hash) ? json["error"]["message"] : nil))
                limit_text = (detail || line).to_s.strip
              end
            end
            turn_started = claude_turn_started?(json)
            if turn_started
              if completion_event_deadline && termination_deadline.nil?
                termination_deadline = begin_termination(pgid)
                completion_event_deadline = nil
              end
              write_tool_in_current_turn = false
              write_turn_completed = false
            end
            write_tool_in_current_turn = true if claude_write_tool_event?(json)

            usage = json && Hive::AgentRuntime.extract_usage(@profile, json)
            if usage
              last_usage = usage
              observed_tokens = token_meter.observe(json, usage)
              if @max_tokens && observed_tokens >= @max_tokens && resource_exhaustion.nil?
                resource_exhaustion = {
                  reason: TOKEN_LIMIT_REASON,
                  limit: @max_tokens,
                  observed: observed_tokens
                }
              end
            end
            if event_provider_error&.dig(:kind) == :model_output_limit && resource_exhaustion.nil?
              resource_exhaustion = {
                reason: MODEL_OUTPUT_LIMIT_REASON,
                observed: usage&.dig(:output)
              }.compact
            end
            turn_completed = claude_turn_completed?(json)
            if turn_completed
              completed_turns += 1
              write_turn_completed = true if write_tool_in_current_turn
              if @max_turns && completed_turns >= @max_turns && resource_exhaustion.nil?
                resource_exhaustion = {
                  reason: TURN_LIMIT_REASON,
                  limit: @max_turns,
                  observed: completed_turns
                }
              end
            end

            output_completed ||= output_completed_event?(json)
            terminal_usage = json && token_meter.terminal?(json)
            if output_completed && (write_turn_completed || terminal_usage)
              unless terminal_usage
                termination_deadline ||= begin_termination(pgid)
              end
              completion_event_deadline = nil
            elsif output_completed
              completion_event_deadline ||= Time.now + COMPLETION_EVENT_GRACE_SECONDS
            elsif resource_exhaustion && termination_deadline.nil?
              if write_turn_completed
                # Claude can report the turn delta either before or after it
                # executes the Write tool. Let that already-generated local
                # tool call finish, but never permit another model turn.
                completion_event_deadline ||= Time.now + COMPLETION_EVENT_GRACE_SECONDS
              elsif !terminal_usage
                termination_deadline = begin_termination(pgid)
              end
            end
          end
        end
      ensure
        r.close unless r.closed?
      end
      # Surface reader-thread crashes (ENOSPC on log, encoding errors, etc.)
      # instead of letting them die silently — a dead reader can stall the
      # child once the pipe buffer fills.
      reader.report_on_exception = true

      timed_out = false
      deadline = Time.now + @timeout_sec
      status = nil
      termination_force_killed = false
      begin
        loop do
          remaining = deadline - Time.now
          if remaining <= 0
            timed_out = true
            kill_group(pgid)
            break
          end
          if completion_event_deadline && termination_deadline.nil? && Time.now >= completion_event_deadline
            termination_deadline = begin_termination(pgid)
            completion_event_deadline = nil
          end
          if termination_deadline && !termination_force_killed && Time.now >= termination_deadline
            force_kill_group(pgid)
            termination_force_killed = true
          end
          # Capture status atomically into a local; avoids races on $? / $CHILD_STATUS
          # being clobbered by other Process.wait calls (e.g. from the reader thread).
          captured = Process.wait2(pid, Process::WNOHANG)
          if captured
            status = captured.last
            break
          end
          sleep [ remaining, 0.2 ].min
        end
      ensure
        trap("INT", old_int || "DEFAULT")
        trap("TERM", old_term || "DEFAULT")
      end

      if timed_out
        sleep_grace_then_kill(pgid, pid)
        status = begin
          Process.wait2(pid).last
        rescue StandardError
          nil
        end
      end
      reader.join(2)
      reader.kill if reader.alive?

      exit_code = if status.nil?
                    nil
      elsif status.exited?
                    status.exitstatus
      elsif status.signaled?
                    -status.termsig
      end

      message = messages.value
      failure_details = structured_failure && {
        provider: @profile.name.to_s,
        subtype: structured_failure[:subtype],
        configured_cap_usd: @max_budget_usd,
        observed_cost_usd: structured_failure[:observed_cost_usd],
        diagnostic: structured_failure[:diagnostic],
        remedy: structured_failure[:remedy]
      }.compact

      reported_usage = if resource_exhaustion || output_completed
        metered_usage = token_meter.usage
        last_usage ? last_usage.merge(
          input: metered_usage[:input],
          output: metered_usage[:output],
          model: metered_usage[:model] || last_usage[:model]
        ) : metered_usage
      else
        last_usage
      end
      result = {
        pid: pid,
        pgid: pgid,
        exit_code: exit_code,
        timed_out: timed_out,
        log_file: log_file,
        final_message: message,
        final_message_source: messages.source,
        final_message_truncated: messages.truncated?,
        limit_text: limit_text,
        usage: reported_usage,
        model: reported_usage&.dig(:model),
        resource_exhaustion: resource_exhaustion,
        output_completed: output_completed,
        provider_signal: provider_signal,
        provider_error: provider_error,
        status: nil
      }
      if structured_failure
        result[:failure_origin] = structured_failure.fetch(:origin)
        result[:failure_details] = failure_details
      end
      result
    ensure
      if stdin_file
        stdin_file.close
        stdin_file.unlink
      end
    end

    def spawn_opencode_and_wait
      prepared = nil
      result = nil
      prepared = prepare_opencode_invocation
      validate_prepared_opencode_skills!(prepared)
      cmd = prepared.invocation.argv
      log_file = log_path
      write_opencode_spawn_log(log_file, prepared, cmd)

      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      stdout_capture = { data: +"", truncated: false }
      stderr_capture = { data: +"", truncated: false }
      stdout_thread = capture_bounded_stream(
        stdout_reader, stdout_capture, OPENCODE_CAPTURE_BYTES
      )
      stderr_thread = capture_bounded_stream(
        stderr_reader, stderr_capture, FINAL_MESSAGE_TAIL_BYTES
      )
      child_env = opencode_child_environment(prepared)
      pid = Process.spawn(
        child_env, *cmd, chdir: @cwd, pgroup: true,
        out: stdout_writer, err: stderr_writer, unsetenv_others: true
      )
      stdout_writer.close
      stderr_writer.close
      pgid = begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end
      Hive::Lock.update_task_lock(
        @task.folder,
        "claude_pid" => pid,
        "claude_pid_start_time" => Hive::Lock.process_start_time(pid)
      )

      cancellation = { cancelled: false }
      cancellation_handler = ->(*) { cancel_opencode!(cancellation, pgid) }
      old_int = install_chained_signal_trap("INT", &cancellation_handler)
      old_term = install_chained_signal_trap("TERM", &cancellation_handler)
      begin
        timed_out, status = wait_for_opencode_process(pid, pgid)
      ensure
        trap("INT", old_int || "DEFAULT")
        trap("TERM", old_term || "DEFAULT")
      end
      finish_capture_thread(stdout_thread, stdout_reader)
      finish_capture_thread(stderr_thread, stderr_reader)
      write_opencode_capture_log(
        log_file, stdout_capture.fetch(:data), stderr_capture.fetch(:data)
      )

      termination = AgentRuntime::TerminationEvidence.new(
        exit_code: process_exit_code(status),
        timed_out: timed_out,
        cancelled: cancellation.fetch(:cancelled),
        signal: process_signal(status)
      )
      inspection_output = nil
      inspection_diagnostic = nil
      if termination.success?
        begin
          parsed = AgentRuntime.parse_run(
            @profile, stdout: stdout_capture.fetch(:data)
          )
          inspection = AgentRuntime.prepare_inspection(prepared, parsed)
          inspection_result = capture_opencode_inspection(inspection)
          if inspection_result.fetch(:success)
            inspection_output = inspection_result.fetch(:stdout)
          else
            inspection_diagnostic = inspection_result.fetch(:diagnostic)
          end
        rescue AgentCliRuntime::MalformedOutput => e
          inspection_diagnostic = AgentCliRuntime::Redactor.diagnostic(e)
        end
      end
      captured = AgentRuntime::CapturedResult.new(
        stdout: stdout_capture.fetch(:data),
        stderr: stderr_capture.fetch(:data),
        termination: termination,
        inspection_output: inspection_output
      )
      outcome = AgentRuntime.normalize(
        @profile, captured, requested_route: prepared.requested_route
      )
      usage = opencode_usage(outcome)
      result = {
        pid: pid,
        pgid: pgid,
        exit_code: termination.exit_code,
        timed_out: termination.timed_out,
        cancelled: termination.cancelled,
        log_file: log_file,
        final_message: outcome.final_message,
        final_message_source: :opencode_terminal_message,
        final_message_truncated: outcome.final_message_truncated,
        limit_text: nil,
        usage: usage,
        model: outcome.identity.actual&.to_s,
        requested_opencode_route: outcome.identity.requested.to_s,
        actual_opencode_route: outcome.identity.actual&.to_s,
        route_resolution_status: outcome.identity.resolution_status,
        normalized_outcome_kind: outcome.kind,
        normalized_outcome: outcome,
        inspection_diagnostic: inspection_diagnostic,
        unknown_event_summaries: outcome.unknown_events,
        resource_exhaustion: nil,
        output_completed: outcome.completed?,
        provider_signal: nil,
        status: nil,
        invocation_root: prepared.invocation_root
      }
      result
    ensure
      close_opencode_ios(
        stdout_writer, stderr_writer, stdout_reader, stderr_reader
      )
      [ stdout_thread, stderr_thread ].each do |thread|
        thread.kill if thread&.alive?
      end
      if prepared
        begin
          prepared.cleanup!
          result[:cleanup_completed] = true if result
        rescue StandardError => e
          diagnostic = AgentCliRuntime::Redactor.diagnostic(e)
          if result
            result[:cleanup_completed] = false
            result[:cleanup_error] = diagnostic
          end
          warn "[hive] OpenCode cleanup failed: #{diagnostic}"
        end
      end
    end

    def prepare_opencode_invocation
      validate_opencode_launch_channels!
      model, effort = opencode_route_and_effort
      request = AgentCliRuntime::Request.new(
        profile: @profile.runtime_profile,
        prompt: @prompt,
        permission_mode: @permission_mode,
        model: model,
        effort: effort,
        executable: @runtime_policy&.executable || @profile.bin,
        command_prefix: @runtime_policy&.command_prefix || []
      )
      root = @opencode_invocation_root || File.join(
        Dir.tmpdir,
        "hive-opencode-#{Process.pid}-#{SecureRandom.hex(12)}"
      )
      preparation = AgentRuntime::OpenCodePreparationRequest.new(
        request: request,
        working_directory: @cwd,
        invocation_root: root,
        configuration_path: @profile.opencode_configuration_path,
        configuration: @profile.opencode_configuration,
        credential_environment_keys:
          @profile.opencode_credential_environment_keys,
        credential_file: @profile.opencode_credential_file,
        permission_policy: @opencode_permission_policy,
        additional_read_roots: @additional_read_roots,
        additional_write_roots: @additional_write_roots,
        edit_patterns: @opencode_edit_patterns,
        plugins: @profile.opencode_plugins,
        pure: @profile.opencode_pure
      )
      AgentRuntime.prepare!(preparation, env: opencode_preparation_environment)
    end

    def validate_prepared_opencode_skills!(prepared)
      invocations = @prompt.scan(%r{/(?:[A-Za-z0-9_.-]+:)?ce-[a-z0-9-]+}).uniq
      invocations.each do |invocation|
        resolution = Hive::SkillCheck::OpenCode.resolve(
          invocation,
          project_root: @cwd,
          environment: prepared.environment_for(env: opencode_preparation_environment),
          configuration_path: prepared.configuration_path
        )
        next if resolution.status == :present

        raise Hive::AgentError,
              "OpenCode prepared skill readiness failed for #{invocation}: #{resolution.message}"
      end
    end

    def validate_opencode_launch_channels!
      unless @cli_flags.empty? && @runtime_cli_flags.empty?
        raise Hive::ConfigError,
              "OpenCode does not accept opaque CLI arguments through Hive"
      end
      if @allowed_tools || @disallowed_tools
        raise Hive::ConfigError,
              "OpenCode tool access must come from its typed permission overlay"
      end
      declared = (@additional_read_roots + @additional_write_roots + [ @cwd ])
        .map { |path| File.expand_path(path) }
      omitted = @add_dirs.reject do |path|
        declared.include?(File.expand_path(path))
      end
      return if omitted.empty?

      raise Hive::ConfigError,
            "OpenCode additional directories require explicit read/write roots"
    end

    def opencode_route_and_effort
      model = @routing_arguments&.model || @launch_arguments&.model ||
        opencode_identity_argument("--model")
      effort = @routing_arguments&.effort || @launch_arguments&.effective_effort ||
        opencode_identity_argument("--variant")
      [ model, effort ]
    end

    def opencode_identity_argument(flag)
      index = @identity_arguments.rindex(flag)
      return nil unless index && index < @identity_arguments.length - 1

      @identity_arguments[index + 1]
    end

    def opencode_preparation_environment
      base = selected_base_environment
      @profile.opencode_credential_environment_keys.each do |key|
        value = selected_credential_value(key)
        base[key] = value unless value.to_s.empty?
      end
      base
    end

    def opencode_child_environment(prepared)
      prepared.environment_for(env: opencode_preparation_environment)
        .merge(selected_base_environment)
        .freeze
    end

    def selected_base_environment
      %w[
        HOME LANG LC_ALL LOGNAME PATH SHELL SSL_CERT_DIR SSL_CERT_FILE
        USER
      ].each_with_object({}) do |key, selected|
        value = @launch_environment.key?(key) ?
          @launch_environment[key] : ENV[key]
        selected[key] = value.to_s unless value.to_s.empty?
      end
    end

    def selected_credential_value(key)
      return @launch_environment[key] if @launch_environment.key?(key)

      ENV[key]
    end

    def capture_bounded_stream(io, capture, max_bytes)
      Thread.new do
        Thread.current.report_on_exception = false
        loop do
          chunk = io.readpartial(16 * 1024)
          remaining = max_bytes - capture.fetch(:data).bytesize
          if remaining.positive?
            capture.fetch(:data) << chunk.byteslice(0, remaining)
          end
          capture[:truncated] = true if chunk.bytesize > remaining
        end
      rescue EOFError, IOError
        nil
      ensure
        io.close unless io.closed?
      end
    end

    def finish_capture_thread(thread, io)
      return unless thread

      thread.join(2)
      return unless thread.alive?

      io.close unless io.closed?
      thread.join(0.2)
      thread.kill if thread.alive?
    rescue IOError
      thread.kill if thread&.alive?
    end

    def cancel_opencode!(state, pgid)
      state[:cancelled] = true
      kill_group(pgid)
    end

    def close_opencode_ios(*ios)
      ios.each do |io|
        io.close if io && !io.closed?
      rescue IOError
        nil
      end
    end

    def wait_for_opencode_process(pid, pgid)
      deadline = Time.now + @timeout_sec
      loop do
        remaining = deadline - Time.now
        if remaining <= 0
          kill_group(pgid)
          sleep_grace_then_kill(pgid, pid)
          status = begin
            Process.wait2(pid).last
          rescue StandardError
            nil
          end
          return [ true, status ]
        end
        captured = Process.wait2(pid, Process::WNOHANG)
        return [ false, captured.last ] if captured

        sleep [ remaining, 0.1 ].min
      end
    end

    def capture_opencode_inspection(inspection)
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      stdout_capture = { data: +"", truncated: false }
      stderr_capture = { data: +"", truncated: false }
      stdout_thread = capture_bounded_stream(
        stdout_reader, stdout_capture,
        AgentCliRuntime::OpenCode::ResultParser::MAX_EXPORT_BYTES + 1
      )
      stderr_thread = capture_bounded_stream(
        stderr_reader, stderr_capture, FINAL_MESSAGE_TAIL_BYTES
      )
      pid = Process.spawn(
        inspection.environment_for(env: opencode_preparation_environment)
          .merge(selected_base_environment),
        *inspection.argv,
        chdir: @cwd, pgroup: true, out: stdout_writer, err: stderr_writer,
        unsetenv_others: true
      )
      stdout_writer.close
      stderr_writer.close
      pgid = begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end
      deadline = Time.now + OPENCODE_INSPECTION_TIMEOUT_SECONDS
      status = nil
      until status
        captured = Process.wait2(pid, Process::WNOHANG)
        status = captured.last if captured
        break if status
        if Time.now >= deadline
          kill_group(pgid)
          sleep_grace_then_kill(pgid, pid)
          status = begin
            Process.wait2(pid).last
          rescue Errno::ECHILD
            nil
          end
          break
        end
        sleep 0.05
      end
      finish_capture_thread(stdout_thread, stdout_reader)
      finish_capture_thread(stderr_thread, stderr_reader)
      success = status&.success? == true && !stdout_capture.fetch(:truncated)
      diagnostic = unless success
        AgentCliRuntime::Redactor.diagnostic(
          stderr_capture.fetch(:data).empty? ?
            "OpenCode sanitized export inspection failed" :
            stderr_capture.fetch(:data)
        )
      end
      {
        success: success,
        stdout: stdout_capture.fetch(:data),
        diagnostic: diagnostic
      }
    ensure
      close_opencode_ios(
        stdout_writer, stderr_writer, stdout_reader, stderr_reader
      )
      [ stdout_thread, stderr_thread ].each do |thread|
        thread.kill if thread&.alive?
      end
    end

    def process_exit_code(status)
      return nil unless status
      return status.exitstatus if status.exited?
      return -status.termsig if status.signaled?

      nil
    end

    def process_signal(status)
      return nil unless status&.signaled?

      Signal.signame(status.termsig) || status.termsig.to_s
    rescue ArgumentError
      status.termsig.to_s
    end

    def opencode_usage(outcome)
      usage = outcome.usage
      return nil unless usage

      {
        input: usage.input,
        output: usage.output,
        cached: usage.cached,
        cache_read: usage.cache_read,
        cache_write: usage.cache_write,
        reasoning: usage.reasoning,
        input_includes_cache_read: usage.input_includes_cache_read,
        input_includes_cache_write: usage.input_includes_cache_write,
        output_includes_reasoning: usage.output_includes_reasoning,
        provider_reported_cost: usage.provider_reported_cost,
        cost: usage.provider_reported_cost,
        model: outcome.identity.actual&.to_s
      }.freeze
    end

    def write_opencode_spawn_log(log_file, prepared, cmd)
      open_private_log(log_file) do |log|
        log.puts "[hive] #{Time.now.utc.iso8601} spawn " \
                 "cwd=#{Hive::SecretPatterns.redact(@cwd)} " \
                 "profile=opencode executable=#{File.basename(prepared.executable)} " \
                 "argc=#{cmd.length}#{launch_identity_log_fields}"
      end
    end

    def write_opencode_capture_log(log_file, stdout, stderr)
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

    def opencode?
      @profile.name == :opencode
    end

    # Compile the provider-neutral request through AgentRuntime.
    #
    # Order is fixed:
    #   bin, headless_flag, permission flags (if any),
    #   --add-dir <dir> repeated for each add_dir (if profile supports),
    #   profile-declared tool scope flags (if supplied),
    #   budget_flag <amount> (if profile supports),
    #   typed implementation identity arguments,
    #   legacy raw arguments (only when the profile explicitly supports them),
    #   output_format_flags...,
    #   prompt
    #
    # The claude profile reproduces today's hardcoded argv exactly (verified
    # by test/unit/agent_test.rb#test_args_include_dangerous_flag_and_add_dir
    # and #test_argv_includes_verbose_when_stream_json which still pass after
    # the refactor — the claude profile's flag set IS today's flag set).
    def build_cmd
      command = compiled_invocation.argv.dup
      command[0] = isolated_executable(command.fetch(0)) if @isolate_environment
      command
    end

    # Resolve a bare agent command before `unsetenv_others` removes the shell
    # activation state that some local tool-manager launchers require. Prefer
    # the configured PATH entry, but when that entry is only a mise/asdf/rbenv
    # trampoline select the next distinct executable of the same name. The
    # child receives the concrete path, never opaque tool-manager session
    # blobs that could encode project environment values.
    def isolated_executable(value)
      name = value.to_s
      return name if name.include?(File::SEPARATOR)

      candidates = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
        candidate = File.join(directory, name)
        candidate if File.file?(candidate) && File.executable?(candidate)
      end
      first = candidates.first
      return name unless first
      return first unless tool_manager_launcher?(first)

      first_identity = File.realpath(first)
      alternatives = candidates.select do |candidate|
        File.realpath(candidate) != first_identity && !tool_manager_launcher?(candidate)
      rescue SystemCallError
        false
      end
      managed_segment = [ "mise", "installs", name ].join(File::SEPARATOR)
      alternatives.find { |candidate| candidate.include?(managed_segment) } ||
        alternatives.first || first
    rescue SystemCallError
      name
    end

    def tool_manager_launcher?(path)
      source = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        file.read(4096)
      end
      source.start_with?("#!") &&
        source.match?(/\b(?:mise|asdf|rbenv)\b/)
    rescue SystemCallError
      false
    end

    def prompt_via_stdin?
      !compiled_invocation.stdin_data.nil?
    end

    def prompt_stdin_file
      return nil unless prompt_via_stdin?

      file = Tempfile.new([ "hive-agent-prompt-", ".txt" ])
      file.write(compiled_invocation.stdin_data)
      file.rewind
      file
    end

    def compiled_invocation
      @compiled_invocation ||= Hive::AgentRuntime.compile(
        Hive::AgentRuntime::Request.new(
          profile: @profile,
          prompt: @prompt,
          permission_mode: @permission_mode,
          permission_arguments: @permission_arguments || @runtime_policy&.permission_flags,
          add_dirs: @add_dirs,
          allowed_tools: @allowed_tools,
          disallowed_tools: @disallowed_tools,
          max_budget_usd: @max_budget_usd,
          identity_arguments: @identity_arguments,
          routing_arguments: @routing_arguments,
          raw_cli_arguments: @cli_flags,
          trusted_cli_arguments: @runtime_cli_flags,
          executable: @runtime_policy&.executable,
          command_prefix: @runtime_policy&.command_prefix
        )
      )
    end

    def kill_group(pgid)
      Process.kill("TERM", -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def force_kill_group(pgid)
      Process.kill("KILL", -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def begin_termination(pgid)
      kill_group(pgid)
      Time.now + TERMINATION_GRACE_SECONDS
    end

    def sleep_grace_then_kill(pgid, pid)
      grace_deadline = Time.now + 3
      until Time.now >= grace_deadline
        return if Process.wait(pid, Process::WNOHANG)

        sleep 0.2
      end
      force_kill_group(pgid)
    rescue Errno::ECHILD
      nil
    end

    # Determine result[:status] from exit_code + profile.status_detection_mode.
    #
    # - :state_file_marker  — read marker from task.state_file (today's
    #   claude behavior; the agent writes its terminal marker itself).
    # - :exit_code_only     — exit 0 = :ok, anything else = :error. Used by
    #   CI-fix style spawns where success is "the underlying command worked."
    # - :output_file_exists — exit 0 AND expected_output present + non-empty
    #   = :ok. Used by reviewer/triage spawns where a structured artifact
    #   is the success criterion.
    def handle_exit(result)
      if result[:provider_signal]
        if effective_status_mode == :state_file_marker
          Hive::Markers.set(
            @task.state_file,
            :error,
            reason: "provider_route_failed",
            provider_account_id: @provider_route.fetch("provider_account_id"),
            route_id: @provider_route.fetch("route_id")
          )
        end
        result[:status] = :error
        result[:error_reason] = "provider_route_failed"
        result[:error_message] = "admitted provider route failed"
        return
      end

      # A provider CLI may emit a transient failed-turn event, retry it
      # internally, and still finish successfully. Current controller-owned
      # completion evidence wins over that earlier stream diagnostic.
      if recovered_provider_error?(result)
        result[:status] = if effective_status_mode == :state_file_marker
          Hive::Markers.current(@task.state_file).name
        else
          :ok
        end
        return
      end

      if result[:output_completed] && completed_output_file?
        result[:status] = :ok
        return
      end

      # Claude can finish the required state artifact and only then emit a
      # trailing max-budget diagnostic while unwinding. The current terminal
      # marker plus non-empty artifact is stronger completion evidence than
      # that trailing event; Brainstorm applies its stricter format/current-run
      # validation above this generic boundary.
      if result[:failure_origin] == "budget_exhausted" && completed_state_file_artifact?
        result[:status] = Hive::Markers.current(@task.state_file).name
        return
      end

      if result[:failure_origin] == "budget_exhausted"
        handle_budget_exhaustion(result)
        return
      end

      if result[:resource_exhaustion]
        handle_resource_exhaustion(result)
        return
      end

      if (limit_text = detected_limit_text(result))
        # Preserve the raw multiline signal even when classification fell back
        # to final_message. Outer execute/review stages use it to retain an
        # adjacent provider reset date instead of the formatted one-line error.
        result[:limit_text] = limit_text
        limit_message = Hive::AgentLimit.error_message(limit_text, agent: @profile.name)
        result[:error_reason] = "limits_reached"
        result[:retry_at] = Hive::AgentLimit.retry_after(text: limit_text)
        if effective_status_mode == :state_file_marker
          Hive::Markers.set(@task.state_file, :error,
                            reason: "limits_reached",
                            message: limit_message,
                            retry_after: result[:retry_at])
        end
        result[:status] = :error
        result[:error_message] = limit_message
        return
      end

      if result[:provider_error]
        handle_provider_error(result)
        return
      end

      if result[:timed_out]
        # Only the :state_file_marker mode writes :error to task.state_file
        # on timeout. The other modes leave the orchestrator-owned marker
        # in place (e.g., REVIEW_WORKING phase=reviewers stays so the
        # 6-review runner can decide whether to retry, escalate, or
        # convert to REVIEW_ERROR).
        if effective_status_mode == :state_file_marker
          Hive::Markers.set(@task.state_file, :error,
                            reason: "timeout",
                            timeout_sec: @timeout_sec)
        end
        result[:status] = :timeout
        return
      end

      normalized = result[:normalized_outcome]
      if normalized && !normalized.completed?
        if effective_status_mode == :state_file_marker
          Hive::Markers.set(
            @task.state_file,
            :error,
            reason: normalized.kind.to_s,
            message: normalized.diagnostic.to_s.byteslice(0, 200)
          )
        end
        result[:status] = :error
        result[:error_reason] = normalized.kind.to_s
        result[:error_message] = normalized.diagnostic
        return
      end

      case effective_status_mode
      when :state_file_marker
        handle_exit_state_file_marker(result)
      when :exit_code_only
        handle_exit_exit_code_only(result)
      when :output_file_exists
        handle_exit_output_file_exists(result)
      end
    end

    private

    def normalize_max_tokens(value)
      return nil if value.nil?

      amount = Integer(value)
      raise ArgumentError, "max_tokens must be a positive integer" unless amount.positive?

      amount
    rescue ArgumentError, TypeError
      raise ArgumentError, "max_tokens must be a positive integer"
    end

    def normalize_max_turns(value)
      return nil if value.nil?

      amount = Integer(value)
      raise ArgumentError, "max_turns must be a positive integer" unless amount.positive?

      amount
    rescue ArgumentError, TypeError
      raise ArgumentError, "max_turns must be a positive integer"
    end

    def claude_turn_completed?(event)
      @profile.name == :claude &&
        event.is_a?(Hash) &&
        event["type"] == "stream_event" &&
        event.dig("event", "type") == "message_delta"
    end

    def claude_turn_started?(event)
      @profile.name == :claude &&
        event.is_a?(Hash) &&
        event["type"] == "stream_event" &&
        event.dig("event", "type") == "message_start"
    end

    def claude_write_tool_event?(event)
      return false unless @profile.name == :claude && event.is_a?(Hash)

      block = event.dig("event", "content_block")
      return true if block.is_a?(Hash) && block["type"] == "tool_use" && block["name"] == "Write"

      message = event["message"]
      content = message.is_a?(Hash) ? message["content"] : nil
      Array(content).any? do |item|
        item.is_a?(Hash) && item["type"] == "tool_use" && item["name"] == "Write"
      end
    end

    def output_completed_event?(event)
      (@max_turns || @max_tokens) &&
        @profile.name == :claude && event.is_a?(Hash) && completed_output_file?
    end

    def handle_resource_exhaustion(result)
      detail = result.fetch(:resource_exhaustion)
      if completed_output_file?
        result[:status] = :ok
        return
      end

      reason = detail.fetch(:reason)
      case reason
      when MODEL_OUTPUT_LIMIT_REASON
        observed = detail[:observed]
        count = observed ? " after #{observed} output tokens" : ""
        message = "agent response reached the model's maximum output tokens#{count}; " \
                  "raise the model maxTokens setting or lower reasoning effort"
      when TOKEN_LIMIT_REASON, TURN_LIMIT_REASON
        resource = reason == TURN_LIMIT_REASON ? "turn" : "token"
        message = "agent reached in-flight #{resource} limit " \
                  "(observed #{detail.fetch(:observed)}, limit #{detail.fetch(:limit)})"
      else
        raise Hive::AgentError, "unknown resource exhaustion reason #{reason.inspect}"
      end
      if effective_status_mode == :state_file_marker
        Hive::Markers.set(@task.state_file, :error, **resource_exhaustion_marker_attrs(detail))
      end
      result[:status] = :error
      result[:error_reason] = reason
      result[:error_message] = message
    end

    def handle_budget_exhaustion(result)
      detail = result[:failure_details].is_a?(Hash) ? result[:failure_details] : {}
      observed = detail[:observed_cost_usd]
      configured = detail[:configured_cap_usd]
      diagnostic = detail[:diagnostic].to_s
      amounts = []
      amounts << "observed $#{observed}" unless observed.nil?
      amounts << "configured $#{configured}" unless configured.nil?
      message = "agent exhausted its per-run budget"
      message = "#{message} (#{amounts.join(', ')})" unless amounts.empty?
      message = "#{message}: #{diagnostic}" unless diagnostic.empty?
      message = "#{message}; raise this stage's max_budget_usd"

      if effective_status_mode == :state_file_marker
        attrs = {
          reason: "budget_exhausted",
          provider: detail[:provider] || @profile.name,
          subtype: detail[:subtype] || "error_max_budget_usd",
          max_budget_usd: configured,
          observed_cost_usd: observed,
          remedy: detail[:remedy] || "raise_stage_budget",
          message: message.byteslice(0, 200).to_s.scrub
        }.compact
        Hive::Markers.set(@task.state_file, :error, **attrs)
      end
      result[:status] = :error
      result[:error_message] = message
    end

    def resource_exhaustion_marker_attrs(detail)
      case detail.fetch(:reason)
      when TOKEN_LIMIT_REASON
        {
          reason: TOKEN_LIMIT_REASON,
          observed_tokens: detail.fetch(:observed),
          max_tokens: detail.fetch(:limit)
        }
      when TURN_LIMIT_REASON
        {
          reason: TURN_LIMIT_REASON,
          observed_turns: detail.fetch(:observed),
          max_turns: detail.fetch(:limit)
        }
      when MODEL_OUTPUT_LIMIT_REASON
        {
          reason: MODEL_OUTPUT_LIMIT_REASON,
          observed_output_tokens: detail[:observed],
          remedy: "raise_model_max_tokens_or_lower_reasoning_effort"
        }.compact
      else
        raise Hive::AgentError,
              "unknown resource exhaustion reason #{detail.fetch(:reason).inspect}"
      end
    end

    def completed_output_file?
      effective_status_mode == :output_file_exists &&
        expected_output_report&.valid?
    end

    def completed_state_file_artifact?
      return false unless effective_status_mode == :state_file_marker
      return false unless File.file?(@task.state_file) && File.size(@task.state_file).positive?

      marker = Hive::Markers.current(@task.state_file)
      marker.name == :waiting || Hive::Markers::TERMINAL_MARKER_NAMES.include?(marker.name)
    rescue SystemCallError
      false
    end

    def detected_limit_text(result)
      provider_error = result[:provider_error]
      if provider_error && provider_limit_kind?(provider_error[:kind])
        return provider_error[:message].to_s
      end

      return nil if result[:exit_code] == 0 && !result[:timed_out]

      # Prefer the limit text captured directly from the raw stream
      # (result[:limit_text]); it catches CLIs like codex that emit the
      # limit notice as a structured event the final-message extractor
      # drops. Fall back to scanning final_message for older paths.
      limit = result[:limit_text].to_s
      limit = result[:final_message].to_s unless Hive::AgentLimit.limit_reached?(limit)
      return nil unless Hive::AgentLimit.limit_reached?(limit)

      limit
    end

    def recovered_provider_error?(result)
      return false unless result[:provider_error] && result[:exit_code] == 0

      case effective_status_mode
      when :state_file_marker then completed_state_file_artifact?
      when :output_file_exists then completed_output_file?
      else false
      end
    end

    # Some CLIs report a failed provider turn in their structured event stream
    # but still exit zero. The profile extractor is the typed boundary that
    # distinguishes that failure from innocent model text. Keep trusted route
    # health separate: this fails only the current agent result and lets the
    # owning stage decide its ordinary retry policy.
    def handle_provider_error(result)
      error = result.fetch(:provider_error)
      message = error[:message].to_s
      message = "provider reported a failed turn" if message.empty?
      if effective_status_mode == :state_file_marker
        Hive::Markers.set(
          @task.state_file,
          :error,
          {
            reason: "provider_error",
            provider: error[:provider],
            status_code: error[:status_code],
            message: message
          }.compact
        )
      end
      result[:status] = :error
      result[:error_reason] = "provider_error"
      result[:error_message] = message
    end

    def handle_exit_state_file_marker(result)
      if result[:exit_code].nil? || result[:exit_code].zero?
        # exit_code 0 = success; trust the marker the agent wrote.
        # exit_code nil = capture failed but child returned without timeout —
        # if no marker was written, that's a corrupted state, not silent OK.
        marker = Hive::Markers.current(@task.state_file)
        if marker.name == :none && result[:exit_code].nil?
          Hive::Markers.set(@task.state_file, :error, reason: "no_marker_no_exit_code")
          result[:status] = :error
        elsif marker.name == :agent_working
          Hive::Markers.set(
            @task.state_file,
            :error,
            reason: "agent_exited_without_terminal_marker",
            observed_marker: marker.name,
            provider: @profile.name
          )
          result[:status] = :error
        else
          result[:status] = marker.name
        end
      else
        Hive::Markers.set(@task.state_file, :error,
                          reason: "exit_code",
                          exit_code: result[:exit_code])
        result[:status] = :error
      end
    end

    # The :exit_code_only and :output_file_exists modes deliberately do
    # NOT write to task.state_file. The orchestrator owns the marker for
    # these flows (6-review's runner aggregates per-reviewer results and
    # writes a single REVIEW_* marker at the end of the phase). Writing
    # :error here would clobber the in-progress REVIEW_WORKING marker.
    # Caller reads result[:status] (:ok | :error) and result[:error_message]
    # to decide what to do.

    def handle_exit_exit_code_only(result)
      if result[:exit_code] == 0
        result[:status] = :ok
      else
        result[:status] = :error
        result[:error_message] = "exit_code=#{result[:exit_code]}"
      end
    end

    def handle_exit_output_file_exists(result)
      if result[:exit_code] != 0
        result[:status] = :error
        result[:error_message] = "exit_code=#{result[:exit_code]}"
        return
      end

      path = @expected_output
      if path.nil? || path.to_s.empty?
        result[:status] = :error
        result[:error_message] = "profile #{@profile.name} uses :output_file_exists but no expected_output was provided"
        return
      end

      unless expected_output_report&.valid?
        result[:status] = :error
        result[:error_message] = "expected output file missing or empty: #{path}"
        return
      end

      result[:status] = :ok
    end

    def expected_output_report
      manifest = expected_output_manifest
      return nil unless manifest

      Hive::ArtifactFirewall.validate_required_outputs(manifest)
    rescue Hive::ArtifactFirewall::Error
      nil
    end

    def expected_output_manifest
      return nil if @expected_output.nil? || @expected_output.to_s.empty?

      @expected_output_manifest ||= begin
        path = File.expand_path(@expected_output.to_s)
        root = File.dirname(path)
        Hive::ArtifactFirewall::Manifest.new(
          root: root,
          protected_anchors: {},
          permitted_writable_roots: [ root ],
          required_outputs: { File.basename(path) => path }
        )
      end
    end

    def parse_json_line(line)
      Hive::Agent::MessageExtractor.parse_json_line(line)
    end

    def install_chained_signal_trap(signal, &handler)
      previous = nil
      previous = trap(signal) do |number|
        handler.call(number)
        call_previous_signal_handler(previous, number)
      end
      previous
    end

    def call_previous_signal_handler(handler, signal)
      return unless handler.respond_to?(:call)

      handler.arity.zero? ? handler.call : handler.call(signal)
    end

    def provider_limit_status?(provider_error)
      provider_limit_kind?(provider_error[:kind])
    end

    def provider_limit_kind?(kind) = %i[provider_limit rate_limited].include?(kind&.to_sym)

    def provider_limit_candidate?(event)
      return true unless event.is_a?(Hash)

      case event["type"]
      when "error", "turn.failed", "rate_limit_event"
        true
      when "result"
        event["is_error"] == true || event["subtype"].to_s.start_with?("error")
      else
        false
      end
    end

    def log_path
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      File.join(@task.log_dir, "#{@log_label}-#{ts}.log")
    end

    def ensure_log_dir
      FileUtils.mkdir_p(@task.log_dir)
    end

    def open_private_log(path)
      flags = File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW
      File.open(path, flags, 0o600) do |log|
        File.chmod(0o600, path)
        yield log
      end
    end

    def emit_agent_event(event_type, message:)
      Hive::Events.emit(
        task_folder: @task.folder,
        slug: event_slug,
        stage: event_stage,
        agent: event_agent_label,
        event_type: event_type,
        message: Hive::SecretPatterns.redact(message)
      )
    end

    def event_agent_label
      [ @profile.name, @log_label ].compact.map(&:to_s).reject(&:empty?).join(" ")
    end

    # @task is a Hive::Task on stage-runner-owned spawns (4-execute,
    # brainstorm, plan, open-pr) but a Hive::Reviewers::SyntheticTask
    # on 6-review sub-spawns (reviewers, triage, ci-fix, browser-test).
    # SyntheticTask is a live Struct that intentionally omits `slug` /
    # `stage_index` and stores the full "6-review" label in `stage_name` # not-a-stage-ref: documents the SyntheticTask stage_name label, not a routing literal
    # unchanged (no coercion — synthetic_task.rb annotates the same fact as
    # coding-scoped). The respond_to? fallback covers both shapes from one
    # call site.
    def event_slug
      @task.respond_to?(:slug) ? @task.slug : File.basename(@task.folder)
    end

    def event_stage
      if @task.respond_to?(:stage_index) && @task.respond_to?(:stage_name) && @task.stage_index
        "#{@task.stage_index}-#{@task.stage_name}"
      else
        @task.respond_to?(:stage_name) && !@task.stage_name.to_s.empty? ?
          @task.stage_name.to_s :
          File.basename(File.dirname(@task.folder))
      end
    end

    def agent_start_message
      # Full @cwd path per the plan U3 contract: basename collapses the
      # worktree-vs-task-folder distinction (e.g. worktree-feat-x vs
      # feat-x-260424-aaaa) and loses that signal in the event log.
      "cwd=#{@cwd} timeout_sec=#{@timeout_sec} max_budget_usd=#{@max_budget_usd} " \
        "max_tokens=#{@max_tokens} max_turns=#{@max_turns}#{launch_identity_log_fields}"
    end

    def agent_end_message(result, exception)
      if exception
        return "status=exception exit_code=#{result&.dig(:exit_code)} pid=#{result&.dig(:pid)} " \
               "error=#{exception.class}: #{exception.message}"
      end

      "status=#{result&.dig(:status)} exit_code=#{result&.dig(:exit_code)} pid=#{result&.dig(:pid)}"
    end

    def normalize_launch_arguments(value)
      return nil if value.nil?
      return value if value.is_a?(Hive::ImplementationIdentity::LaunchArguments)

      raise ArgumentError, "launch_arguments must be a Hive::ImplementationIdentity::LaunchArguments"
    end

    def launch_identity_log_fields
      return "" unless @launch_arguments

      model = Hive::SecretPatterns.redact(@launch_arguments.model)
      requested_effort = @launch_arguments.requested_effort || "none"
      effective_effort = @launch_arguments.effective_effort || "provider-default"
      " model=#{model} requested_effort=#{requested_effort} " \
        "effective_effort=#{effective_effort} model_pinned=#{@launch_arguments.model_pinned} " \
        "effort_supported=#{@launch_arguments.effort_supported}"
    end
  end
end
