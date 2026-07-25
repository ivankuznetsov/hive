require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"
require "hive/agent_profiles"
require "hive/agent_limit"
require "hive/agent/message_extractor"
require "hive/events"
require "hive/lock"
require "hive/permission_scope"
require "hive/secret_patterns"

module Hive
  class Agent
    FINAL_MESSAGE_TAIL_BYTES = 64 * 1024
    TERMINATION_GRACE_SECONDS = 3
    COMPLETION_EVENT_GRACE_SECONDS = 3

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

    attr_reader :task, :prompt, :add_dirs, :cwd, :max_budget_usd, :max_tokens, :max_turns, :timeout_sec,
                :profile, :expected_output, :status_mode, :permission_mode,
                :runtime_policy, :child_environment

    def initialize(task:, prompt:, max_budget_usd:, timeout_sec:,
                   add_dirs: [], cwd: nil, log_label: nil,
                   profile: nil, expected_output: nil, status_mode: nil,
                   permission_mode: nil, allowed_tools: nil,
                   disallowed_tools: nil, cli_flags: [], max_tokens: nil,
                   max_turns: nil, identity_arguments: [], runtime_policy: nil,
                   log_stream: true)
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
      @runtime_policy = runtime_policy
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
        @add_dirs = @runtime_policy.directories
        @cli_flags = Array(cli_flags) + @runtime_policy.cli_flags
        @child_environment = @runtime_policy.environment.merge(SCRUBBED_CHILD_ENV)
      else
        @permission_mode = permission_mode
        @allowed_tools = allowed_tools
        @disallowed_tools = disallowed_tools
        @cli_flags = Array(cli_flags)
        @child_environment = SCRUBBED_CHILD_ENV
      end
      @identity_arguments = Hive::ImplementationIdentity.validate_native_arguments(identity_arguments).freeze
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
      result
    ensure
      emit_agent_event(:agent_end, message: agent_end_message(result, $!))
    end

    def spawn_and_wait
      cmd = build_cmd
      log_file = log_path
      messages = Hive::Agent::MessageExtractor::Accumulator.new(max_bytes: FINAL_MESSAGE_TAIL_BYTES)
      limit_text = nil
      structured_failure = nil
      last_usage = nil
      token_meter = StreamTokenMeter.new(@profile.name)
      resource_exhaustion = nil
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
                 "profile=#{@profile.name} executable=#{File.basename(cmd.first.to_s)} argc=#{cmd.length}"
      end
      r, w = IO.pipe
      spawn_opts = { chdir: @cwd, pgroup: true, out: w, err: w }
      spawn_opts[:unsetenv_others] = true if @runtime_policy
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

      old_int = trap("INT") { kill_group(pgid) }
      old_term = trap("TERM") { kill_group(pgid) }

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
            message = messages.observe(json, raw_line: line)
            if structured_failure.nil? && @profile.name == :claude
              structured_failure = Hive::Agent::MessageExtractor.extract_failure(json)
            end
            if @log_stream
              safe_line = if message
                "[structured message omitted type=#{json.fetch('type', 'unknown')}]\n"
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
            if limit_text.nil? && Hive::AgentLimit.limit_reached?(line)
              detail = json && (json["message"] || (json["error"].is_a?(Hash) ? json["error"]["message"] : nil))
              limit_text = (detail || line).to_s.strip
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

            usage = json && @profile.extract_usage_event(json)
            if usage
              last_usage = usage
              observed_tokens = token_meter.observe(json, usage)
              if @max_tokens && observed_tokens >= @max_tokens && resource_exhaustion.nil?
                resource_exhaustion = {
                  reason: "token_limit",
                  limit: @max_tokens,
                  observed: observed_tokens
                }
              end
            end
            turn_completed = claude_turn_completed?(json)
            if turn_completed
              completed_turns += 1
              write_turn_completed = true if write_tool_in_current_turn
              if @max_turns && completed_turns >= @max_turns && resource_exhaustion.nil?
                resource_exhaustion = {
                  reason: "turn_limit",
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

      reported_usage = resource_exhaustion || output_completed ? token_meter.usage : last_usage
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

    # Build the argv for the configured profile.
    #
    # Order is fixed:
    #   bin, headless_flag, permission flags (if any),
    #   --add-dir <dir> repeated for each add_dir (if profile supports),
    #   Claude-only tool scope flags (if supplied),
    #   budget_flag <amount> (if profile supports),
    #   output_format_flags...,
    #   extra_flags...,
    #   prompt
    #
    # The claude profile reproduces today's hardcoded argv exactly (verified
    # by test/unit/agent_test.rb#test_args_include_dangerous_flag_and_add_dir
    # and #test_argv_includes_verbose_when_stream_json which still pass after
    # the refactor — the claude profile's flag set IS today's flag set).
    def build_cmd
      cmd = [ @profile.bin ]
      if @profile.headless_flag
        cmd << @profile.headless_flag
        # Some CLIs' headless flag TAKES the prompt as its value (grok's
        # -p/--single) rather than reading a trailing positional — the prompt
        # must sit adjacent to the flag, before any other flags.
        cmd << @prompt if @profile.prompt_style == :headless_flag_value
      end
      cmd.concat(permission_flags)
      if @profile.add_dir_flag
        @add_dirs.each do |d|
          cmd << @profile.add_dir_flag << d
        end
      end
      if @profile.name == :claude
        if (allowed = Hive::PermissionScope.tool_csv(@allowed_tools))
          cmd << "--allowedTools" << allowed
        end
        if (disallowed = Hive::PermissionScope.tool_csv(@disallowed_tools))
          cmd << "--disallowedTools" << disallowed
        end
      end
      if @profile.budget_flag && @max_budget_usd
        cmd << @profile.budget_flag << @max_budget_usd.to_s
      end
      # Typed profile-native identity argv is provider-safe and always
      # arrives as discrete Process.spawn arguments. The raw cli_flags path
      # remains Claude-only for backward compatibility with callers that
      # need unrelated Claude flags (MCP, legacy capability adapters).
      cmd.concat(@identity_arguments)
      if @cli_flags.any? && @profile.name != :claude
        raise ArgumentError, "cli_flags are claude-specific; got #{@cli_flags.inspect} for #{@profile.name}"
      end
      cmd.concat(@cli_flags)
      cmd.concat(@profile.output_format_flags)
      cmd << (@profile.prompt_style == :stdin ? "-" : @prompt) unless @profile.prompt_style == :headless_flag_value
      cmd
    end

    def permission_flags
      @profile.permission_flags(@permission_mode)
    end

    def prompt_via_stdin?
      @profile.prompt_style == :stdin
    end

    def prompt_stdin_file
      return nil unless prompt_via_stdin?

      file = Tempfile.new([ "hive-agent-prompt-", ".txt" ])
      file.write(@prompt)
      file.rewind
      file
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
        if effective_status_mode == :state_file_marker
          Hive::Markers.set(@task.state_file, :error,
                            reason: "limits_reached",
                            message: limit_message,
                            retry_after: Hive::AgentLimit.retry_after(text: limit_text))
        end
        result[:status] = :error
        result[:error_message] = limit_message
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

      resource = detail.fetch(:reason) == "turn_limit" ? "turn" : "token"
      message = "agent reached in-flight #{resource} limit " \
                "(observed #{detail.fetch(:observed)}, limit #{detail.fetch(:limit)})"
      if effective_status_mode == :state_file_marker
        Hive::Markers.set(@task.state_file, :error, **resource_exhaustion_marker_attrs(detail))
      end
      result[:status] = :error
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
      if detail.fetch(:reason) == "token_limit"
        {
          reason: "token_limit",
          observed_tokens: detail.fetch(:observed),
          max_tokens: detail.fetch(:limit)
        }
      else
        {
          reason: "turn_limit",
          observed_turns: detail.fetch(:observed),
          max_turns: detail.fetch(:limit)
        }
      end
    end

    def completed_output_file?
      effective_status_mode == :output_file_exists &&
        !@expected_output.to_s.empty? &&
        File.exist?(@expected_output) &&
        File.size(@expected_output).positive?
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

    def handle_exit_state_file_marker(result)
      if result[:exit_code].nil? || result[:exit_code].zero?
        # exit_code 0 = success; trust the marker the agent wrote.
        # exit_code nil = capture failed but child returned without timeout —
        # if no marker was written, that's a corrupted state, not silent OK.
        marker = Hive::Markers.current(@task.state_file)
        if marker.name == :none && result[:exit_code].nil?
          Hive::Markers.set(@task.state_file, :error, reason: "no_marker_no_exit_code")
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

      unless File.exist?(path) && File.size(path) > 0
        result[:status] = :error
        result[:error_message] = "expected output file missing or empty: #{path}"
        return
      end

      result[:status] = :ok
    end

    def extract_final_message(data)
      Hive::Agent::MessageExtractor.extract(data)
    end

    def parse_json_line(line)
      Hive::Agent::MessageExtractor.parse_json_line(line)
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
        "max_tokens=#{@max_tokens} max_turns=#{@max_turns}"
    end

    def agent_end_message(result, exception)
      if exception
        return "status=exception exit_code=#{result&.dig(:exit_code)} pid=#{result&.dig(:pid)} " \
               "error=#{exception.class}: #{exception.message}"
      end

      "status=#{result&.dig(:status)} exit_code=#{result&.dig(:exit_code)} pid=#{result&.dig(:pid)}"
    end
  end
end
