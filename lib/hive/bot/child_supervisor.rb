require "fileutils"
require "json"
require "time"
require "tmpdir"

module Hive
  module Bot
    class ChildSupervisor
      ChildExit = Data.define(:pid, :exit_code, :project, :slug, :command_argv,
                              :chat_id, :update_id, :started_at, :finished_at,
                              :log_path, :json_envelope)

      ENVELOPE_TAIL_BYTES = 64 * 1024

      def initialize(logger:, hive_bin: ENV.fetch("HIVE_BIN", "hive"), log_dir_for_task: nil, dry_run: false)
        @logger = logger
        @hive_bin = hive_bin
        @log_dir_for_task = log_dir_for_task
        @dry_run = dry_run
        @running = {}
        @completed = {}
        @mutex = Mutex.new
      end

      def dispatch(command_argv:, cwd:, chat_id:, update_id:, project: nil, slug: nil)
        argv = normalize_hive_bin(Array(command_argv))
        slug ||= derive_slug(argv)
        project ||= File.basename(cwd.to_s)

        if @dry_run
          pid = next_dry_pid
          @mutex.synchronize do
            @running[pid] = entry(project: project, slug: slug, command_argv: argv,
                                  chat_id: chat_id, update_id: update_id,
                                  started_at: Time.now, log_path: nil, dry_run: true)
          end
          @logger.event(:dispatched_command, pid: pid, project: project, slug: slug,
                                             command: argv.join(" "), dry_run: true,
                                             update_id: update_id)
          return pid
        end

        log_path = log_path_for(cwd: cwd, project: project, slug: slug)
        FileUtils.mkdir_p(File.dirname(log_path))
        log_io = File.open(log_path, "w")
        log_io.puts("[hive-bot] #{Time.now.utc.iso8601} spawn argv=#{argv.inspect}")
        log_io.flush

        pid = Process.spawn(*argv, chdir: cwd, pgroup: true, out: log_io, err: log_io)
        log_io.close
        @mutex.synchronize do
          @running[pid] = entry(project: project, slug: slug, command_argv: argv,
                                chat_id: chat_id, update_id: update_id,
                                started_at: Time.now, log_path: log_path, dry_run: false)
        end
        @logger.event(:dispatched_command, pid: pid, project: project, slug: slug,
                                           command: argv.join(" "), dry_run: false,
                                           update_id: update_id)
        pid
      end

      def reap_all(now: Time.now)
        completed = []
        tracked_pids = @mutex.synchronize { @running.keys.dup }
        tracked_pids.each do |pid|
          begin
            reaped_pid, status = Process.wait2(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            entry = @mutex.synchronize { @running.delete(pid) }
            completed << remember_exit(build_exit(pid, nil, entry, now)) if entry
            next
          end
          next if reaped_pid.nil?

          entry = @mutex.synchronize { @running.delete(reaped_pid) }
          next unless entry

          completed << remember_exit(build_exit(reaped_pid, status.exitstatus, entry, now))
        end
        completed
      end

      def reap_dry_run(now: Time.now)
        dry_entries = @mutex.synchronize do
          @running.select { |_pid, entry| entry[:dry_run] }
        end
        exits = dry_entries.map { |pid, entry| build_exit(pid, 0, entry, now) }
        @mutex.synchronize { exits.each { |exit| @running.delete(exit.pid) } }
        exits
      end

      def terminate_all(grace_sec: 60)
        return if @mutex.synchronize { @running.empty? }

        collect_pgids.each { |pgid| safe_kill(:TERM, -pgid) }
        deadline = Time.now + grace_sec
        until @mutex.synchronize { @running.empty? } || Time.now >= deadline
          reap_all
          sleep 0.1
        end
        remaining_pids = @mutex.synchronize { @running.keys.dup }
        remaining_pids.each do |pid|
          pgid = Process.getpgid(pid)
          safe_kill(:KILL, -pgid)
        rescue Errno::ESRCH
          nil
        end
        sleep 0.1
        reap_all
        stale_pids = @mutex.synchronize { @running.keys.dup }
        gone_pids = stale_pids.select do |pid|
          Process.kill(0, pid)
          false
        rescue Errno::ESRCH
          true
        rescue Errno::EPERM
          false
        end
        @mutex.synchronize { gone_pids.each { |pid| @running.delete(pid) } }
      end

      def in_flight_count
        @mutex.synchronize { @running.size }
      end

      def in_flight_pids
        @mutex.synchronize { @running.keys.dup }
      end

      def completed_exit(pid)
        @mutex.synchronize { @completed[pid] }
      end

      private

      def remember_exit(child)
        @mutex.synchronize { @completed[child.pid] = child }
        child
      end

      def entry(project:, slug:, command_argv:, chat_id:, update_id:, started_at:, log_path:, dry_run:)
        {
          project: project,
          slug: slug,
          command_argv: command_argv,
          chat_id: chat_id,
          update_id: update_id,
          started_at: started_at,
          log_path: log_path,
          dry_run: dry_run
        }
      end

      def build_exit(pid, exit_code, entry, now)
        envelope = parse_envelope(entry[:log_path])
        @logger.event(:command_completed, pid: pid, exit_code: exit_code,
                                           project: entry[:project], slug: entry[:slug],
                                           update_id: entry[:update_id],
                                           envelope_ok: envelope&.dig("ok"),
                                           error_kind: envelope&.dig("error_kind"))
        ChildExit.new(
          pid: pid,
          exit_code: exit_code,
          project: entry[:project],
          slug: entry[:slug],
          command_argv: entry[:command_argv],
          chat_id: entry[:chat_id],
          update_id: entry[:update_id],
          started_at: entry[:started_at],
          finished_at: now,
          log_path: entry[:log_path],
          json_envelope: envelope
        )
      end

      def normalize_hive_bin(argv)
        return argv unless argv.first == "hive"

        [ @hive_bin, *argv.drop(1) ]
      end

      SLUG_BEARING_VERBS = %w[
        new run plan develop review pr archive approve brainstorm markers
        accept-finding reject-finding
      ].freeze

      def derive_slug(argv)
        idx = argv.index { |part| !part.to_s.start_with?("-") && part != @hive_bin && part != "hive" }
        return "unknown" unless idx

        verb = argv[idx].to_s
        return nil unless SLUG_BEARING_VERBS.include?(verb)

        candidate = argv[idx + 1]
        return nil if candidate.nil? || candidate.start_with?("-")

        candidate
      end

      def log_path_for(cwd:, project:, slug:)
        return @log_dir_for_task.call(project, slug) if @log_dir_for_task

        hive_state = File.join(cwd, ".hive-state")
        base = if Dir.exist?(hive_state)
                 File.join(hive_state, "logs", slug.to_s)
        else
                 File.join(Dir.tmpdir, "hive-bot-logs", project.to_s, slug.to_s)
        end
        ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        File.join(base, "bot-dispatch-#{ts}-#{Process.pid}.log")
      end

      def parse_envelope(log_path)
        return nil if log_path.nil? || !File.exist?(log_path)

        tail = read_tail(log_path, ENVELOPE_TAIL_BYTES)
        if tail.to_s.empty?
          @logger.event(:envelope_parse_failure, log_path: log_path, reason: "empty_tail")
          return nil
        end

        candidate_lines = tail.lines.reverse_each.select { |line| line.strip.start_with?("{") }
        if candidate_lines.empty?
          @logger.event(:envelope_parse_failure, log_path: log_path, reason: "no_json_candidate")
          return nil
        end

        candidate_lines.each do |line|
          return JSON.parse(line.strip)
        rescue JSON::ParserError
          next
        end

        @logger.event(:envelope_parse_failure, log_path: log_path, reason: "malformed_json")
        nil
      end

      def read_tail(path, max_bytes)
        File.open(path, "rb") do |f|
          size = f.size
          start = [ size - max_bytes, 0 ].max
          f.seek(start)
          chunk = f.read
          chunk = chunk.split("\n", 2)[1].to_s if start.positive?
          chunk
        end
      rescue Errno::ENOENT
        nil
      rescue Errno::EACCES, IOError => e
        @logger.event(:envelope_parse_failure, log_path: path,
                                                reason: "read_tail_failed",
                                                error_class: e.class.name,
                                                message: e.message)
        nil
      end

      def collect_pgids
        pids = @mutex.synchronize { @running.keys.dup }
        pids.filter_map do |pid|
          Process.getpgid(pid)
        rescue Errno::ESRCH
          nil
        end.uniq
      end

      def safe_kill(signal, target)
        Process.kill(signal, target)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def next_dry_pid
        @next_dry_pid ||= 0
        @next_dry_pid -= 1
      end
    end
  end
end
