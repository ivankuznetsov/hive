require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"
require "hive/agent_profiles"
require "hive/events"
require "hive/lock"

module Hive
  class Agent
    FINAL_MESSAGE_TAIL_BYTES = 64 * 1024

    attr_reader :task, :prompt, :add_dirs, :cwd, :max_budget_usd, :timeout_sec,
                :profile, :expected_output, :status_mode

    def initialize(task:, prompt:, max_budget_usd:, timeout_sec:,
                   add_dirs: [], cwd: nil, log_label: nil,
                   profile: nil, expected_output: nil, status_mode: nil)
      @task = task
      @prompt = prompt
      @add_dirs = Array(add_dirs)
      @cwd = cwd || task.folder
      @max_budget_usd = max_budget_usd
      @timeout_sec = timeout_sec
      @log_label = log_label || task.stage_name
      @profile = profile || Hive::AgentProfiles.lookup(:claude)
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
      final_message = nil
      final_message_source = nil
      plain_tail = +""
      stdin_file = prompt_stdin_file
      File.open(log_file, "a") do |log|
        log.puts "[hive] #{Time.now.utc.iso8601} spawn cwd=#{@cwd} cmd=#{cmd.inspect}"
      end
      r, w = IO.pipe
      spawn_opts = { chdir: @cwd, pgroup: true, out: w, err: w }
      spawn_opts[:in] = stdin_file if stdin_file
      pid = Process.spawn(*cmd, **spawn_opts)
      w.close
      pgid = begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end

      Hive::Lock.update_task_lock(@task.folder, "claude_pid" => pid)

      old_int = trap("INT") { kill_group(pgid) }
      old_term = trap("TERM") { kill_group(pgid) }

      reader = Thread.new do
        File.open(log_file, "a") do |log|
          r.each_line do |line|
            log.write("[stream] #{Time.now.utc.iso8601} #{line}")
            log.write("\n") unless line.end_with?("\n")
            log.flush
            if (message = extract_final_message(line))
              final_message = message
              final_message_source = :structured
            elsif !json_line?(line)
              plain_tail << line
              plain_tail = plain_tail.byteslice(-FINAL_MESSAGE_TAIL_BYTES, FINAL_MESSAGE_TAIL_BYTES) || plain_tail
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
      begin
        loop do
          remaining = deadline - Time.now
          if remaining <= 0
            timed_out = true
            kill_group(pgid)
            break
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

      plain_message = plain_tail.strip
      message = final_message || plain_message
      message_source = final_message ? final_message_source : (plain_message.empty? ? nil : :plain)

      {
        pid: pid,
        pgid: pgid,
        exit_code: exit_code,
        timed_out: timed_out,
        log_file: log_file,
        final_message: message,
        final_message_source: message_source,
        status: nil
      }
    ensure
      if stdin_file
        stdin_file.close
        stdin_file.unlink
      end
    end

    # Build the argv for the configured profile.
    #
    # Order is fixed:
    #   bin, headless_flag, permission_skip_flag (if any),
    #   --add-dir <dir> repeated for each add_dir (if profile supports),
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
      cmd << @profile.headless_flag if @profile.headless_flag
      cmd << @profile.permission_skip_flag if @profile.permission_skip_flag
      if @profile.add_dir_flag
        @add_dirs.each do |d|
          cmd << @profile.add_dir_flag << d
        end
      end
      if @profile.budget_flag && @max_budget_usd
        cmd << @profile.budget_flag << @max_budget_usd.to_s
      end
      cmd.concat(@profile.output_format_flags)
      cmd << (prompt_via_stdin? ? "-" : @prompt)
      cmd
    end

    def prompt_via_stdin?
      @profile.name == :codex
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

    def sleep_grace_then_kill(pgid, pid)
      grace_deadline = Time.now + 3
      until Time.now >= grace_deadline
        return if Process.wait(pid, Process::WNOHANG)

        sleep 0.2
      end
      begin
        Process.kill("KILL", -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
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

    def extract_final_message(line)
      data = JSON.parse(line)
      return nil unless data.is_a?(Hash)

      case data["type"]
      when "result"
        text_value(data["result"])
      when "item.completed"
        item = data["item"]
        return nil unless item.is_a?(Hash)
        return nil unless %w[agent_message message].include?(item["type"])

        text_value(item["text"]) || text_value(item["message"]) || text_from_content(item["content"])
      when "agent_message"
        text_value(data["text"]) || text_value(data["message"]) || text_from_content(data["content"])
      when "assistant"
        message = data["message"]
        return nil unless message.is_a?(Hash)

        text_value(message["text"]) || text_from_content(message["content"])
      else
        nil
      end
    rescue JSON::ParserError
      nil
    end

    def text_from_content(content)
      return text_value(content) if content.is_a?(String)
      return nil unless content.is_a?(Array)

      text = content.filter_map do |item|
        next unless item.is_a?(Hash)

        text_value(item["text"]) if %w[text output_text].include?(item["type"])
      end.join("\n\n")
      text.empty? ? nil : text
    end

    def text_value(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def json_line?(line)
      JSON.parse(line)
      true
    rescue JSON::ParserError
      false
    end

    def log_path
      ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      File.join(@task.log_dir, "#{@log_label}-#{ts}.log")
    end

    def ensure_log_dir
      FileUtils.mkdir_p(@task.log_dir)
    end

    def emit_agent_event(event_type, message:)
      Hive::Events.emit(
        task_folder: @task.folder,
        slug: event_slug,
        stage: event_stage,
        agent: event_agent_label,
        event_type: event_type,
        message: message
      )
    end

    def event_agent_label
      [ @profile.name, @log_label ].compact.map(&:to_s).reject(&:empty?).join(" ")
    end

    # @task is a Hive::Task on stage-runner-owned spawns (4-execute,
    # brainstorm, plan, open-pr) but a Hive::Reviewers::SyntheticTask
    # on 6-review sub-spawns (reviewers, triage, ci-fix, browser-test).
    # SyntheticTask is a Struct that intentionally omits `slug` /
    # `stage_index` and stores the full "6-review" label in `stage_name`.
    # The respond_to? fallback covers both shapes from one call site.
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
      "cwd=#{@cwd} timeout_sec=#{@timeout_sec} max_budget_usd=#{@max_budget_usd}"
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
