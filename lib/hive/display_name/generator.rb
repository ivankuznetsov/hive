require "erb"
require "fileutils"
require "tempfile"
require "time"
require "hive/agent/message_extractor"
require "hive/config"
require "hive/display_name/sanitizer"
require "hive/git_ops"
require "hive/stages/base"
require "hive/task"
require "hive/task_meta"

module Hive
  module DisplayName
    class Generator
      TAIL_BYTES = 64 * 1024
      DEFAULT_TIMEOUT_SEC = 60

      def initialize(task, cfg: nil, commit: true)
        @task = task
        @cfg = cfg || Hive::Config.load(task.project_root)
        @commit = commit
      end

      def call
        name = generate_name
        return nil unless name
        # The agent runs detached for ~60s; in the folder-as-agent pipeline the
        # task may be `mv`'d to the next stage in that window. Bail if the
        # original folder no longer exists so `update_display_name` (which
        # mkdir_p's the path) can't resurrect a stale, idea.md-less stub.
        return nil unless File.directory?(@task.folder)

        Hive::TaskMeta.update_display_name(@task.folder, name)
        commit_name if @commit
        name
      rescue StandardError
        nil
      end

      private

      def generate_name
        profile = Hive::Stages::Base.stage_profile(@cfg, "execute")
        @provider_router = Hive::Stages::Base.provider_router
        @routing_decision = Hive::Stages::Base.route_attempt(
          @task,
          cfg: @cfg,
          routing: nil,
          routing_label: "execute",
          routing_checkpoint: "display-name",
          profile: profile,
          model: nil,
          effort: nil,
          provider_key: nil,
          router: @provider_router
        )
        return nil if @routing_decision.wait?

        profile = @routing_decision.profile
        result = run_agent(profile)
        return nil unless result[:exit_code]&.zero?

        Hive::DisplayName::Sanitizer.sanitize(result[:final_message])
      end

      def run_agent(profile)
        prompt = render_prompt
        cmd = build_cmd(profile, prompt)
        log_path = File.join(@task.log_dir, "display-name-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.log")
        FileUtils.mkdir_p(File.dirname(log_path))

        r, w = IO.pipe
        stdin_file = prompt_stdin_file(profile, prompt)
        spawn_opts = { chdir: @task.project_root, pgroup: true, out: w, err: w }
        spawn_opts[:in] = stdin_file if stdin_file
        if @routing_decision
          check = @provider_router.dispatch_valid?(@routing_decision)
          unless check.valid
            raise Hive::UnavailableError, "provider route invalid before display-name spawn: #{check.reason}"
          end
        end
        pid = Process.spawn(*cmd, **spawn_opts)
        w.close
        pgid = process_group(pid)
        final_message = nil
        plain_tail = +""
        reader = Thread.new do
          File.open(log_path, "a") do |log|
            r.each_line do |line|
              log.write(line)
              log.write("\n") unless line.end_with?("\n")
              if (message = Hive::Agent::MessageExtractor.extract(line))
                final_message = message
              elsif Hive::Agent::MessageExtractor.parse_json_line(line).nil?
                plain_tail << line
                plain_tail = plain_tail.byteslice(-TAIL_BYTES, TAIL_BYTES) || plain_tail
              end
            end
          end
        ensure
          r.close unless r.closed?
        end
        reader.report_on_exception = false

        status = if @routing_decision
          @provider_router.lease_store.with_heartbeat(@routing_decision.lease) do
            wait_with_timeout(pid, pgid)
          end
        else
          wait_with_timeout(pid, pgid)
        end
        reader.join(2)
        reader.kill if reader.alive?

        result = {
          exit_code: exit_code(status),
          final_message: final_message || plain_tail.strip
        }
        signal = profile.normalize_error(
          evidence: result[:final_message],
          exit_code: result[:exit_code],
          timed_out: false,
          model: @routing_decision&.model,
          provider: @routing_decision&.provider || profile.name,
          evidence_ref: "#{log_path}#tail",
          success: result[:exit_code]&.zero?
        )
        @provider_router&.record_outcome(
          decision: @routing_decision,
          success: result[:exit_code]&.zero?,
          signal: signal,
          checkpoint: "display-name"
        )
        result
      rescue StandardError => e
        if e.is_a?(Hive::UnavailableError) && e.message.include?("provider route invalid before")
          @provider_router&.cancel(@routing_decision)
          raise
        end
        signal = profile&.normalize_error(
          evidence: e.message,
          exit_code: 1,
          timed_out: false,
          model: @routing_decision&.model,
          provider: @routing_decision&.provider || profile&.name,
          evidence_ref: "display-name:#{e.class}",
          success: false
        )
        @provider_router&.record_outcome(
          decision: @routing_decision,
          success: false,
          signal: signal,
          checkpoint: "display-name"
        )
        raise
      ensure
        stdin_file&.close
        stdin_file&.unlink
        w&.close unless w&.closed?
        r&.close unless r&.closed?
      end

      def build_cmd(profile, prompt)
        cmd = [ profile.bin ]
        cmd << profile.headless_flag if profile.headless_flag
        cmd.concat(profile.permission_flags(Hive::Config.claude_permission_mode(@cfg)))
        cmd.concat(profile.output_format_flags)
        cmd << (prompt_via_stdin?(profile) ? "-" : prompt)
        cmd
      end

      def prompt_via_stdin?(profile)
        profile.name == :codex
      end

      def prompt_stdin_file(profile, prompt)
        return nil unless prompt_via_stdin?(profile)

        file = Tempfile.new([ "hive-display-name-prompt-", ".txt" ])
        file.write(prompt)
        file.rewind
        file
      end

      def wait_with_timeout(pid, pgid)
        deadline = Time.now + timeout_sec
        loop do
          status = Process.wait2(pid, Process::WNOHANG)
          return status.last if status

          if Time.now >= deadline
            kill_group(pgid, "TERM")
            sleep 0.2
            kill_group(pgid, "KILL")
            return Process.wait2(pid).last
          end
          sleep 0.1
        end
      rescue Errno::ECHILD
        nil
      end

      def timeout_sec
        Integer(@cfg.fetch("display_name_timeout_sec", DEFAULT_TIMEOUT_SEC))
      rescue ArgumentError, TypeError
        DEFAULT_TIMEOUT_SEC
      end

      def process_group(pid)
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end

      def kill_group(pgid, signal)
        Process.kill(signal, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def exit_code(status)
        return nil unless status
        return status.exitstatus if status.exited?
        return -status.termsig if status.signaled?

        nil
      end

      def render_prompt
        template = File.read(File.expand_path("../../../templates/display_name_prompt.md.erb", __dir__))
        ERB.new(template, trim_mode: "-").result(binding)
      end

      def original_text
        File.exist?(@task.state_file) ? File.read(@task.state_file) : @task.slug
      rescue StandardError
        @task.slug
      end

      def commit_name
        Hive::GitOps.new(@task.project_root).hive_commit(
          stage_name: "#{@task.stage_index}-#{@task.stage_name}",
          slug: @task.slug,
          action: "named"
        )
      rescue Hive::GitError
        nil
      end
    end
  end
end
