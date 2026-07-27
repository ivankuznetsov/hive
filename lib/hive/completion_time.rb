require "open3"
require "time"
require "hive/git_ops"

module Hive
  # Resolves the immutable first-completion clock used by archive visibility.
  # A durable metadata value is authoritative; legacy discovery prefers the
  # first Git event that made the resolved terminal stage archived, then falls
  # back to the task state-file and folder mtimes.
  module CompletionTime
    TERMINAL_MARKER = /<!--\s*(?:COMPLETE|EXECUTE_COMPLETE|REVIEW_COMPLETE)\b/.freeze
    MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }.freeze
    class DeadlineExceeded < StandardError; end

    CommandResult = Data.define(:out, :err, :status)

    class CommandRunner
      def capture(argv, deadline:, monotonic_clock:)
        remaining = deadline - monotonic_clock.call
        raise DeadlineExceeded, "completion history deadline exceeded" unless remaining.positive?

        stdin, stdout, stderr, waiter = Open3.popen3(*argv, pgroup: true)
        stdin.close
        readers = [ Thread.new { stdout.read }, Thread.new { stderr.read } ]
        unless waiter.join(remaining)
          terminate(waiter)
          raise DeadlineExceeded, "completion history deadline exceeded"
        end

        readers.each do |reader|
          remaining = deadline - monotonic_clock.call
          unless remaining.positive? && reader.join(remaining)
            terminate(waiter)
            raise DeadlineExceeded, "completion history deadline exceeded"
          end
        end

        CommandResult.new(out: readers[0].value, err: readers[1].value, status: waiter.value)
      ensure
        [ stdin, stdout, stderr ].each do |io|
          io.close if io && !io.closed?
        rescue IOError
          nil
        end
      end

      private

      def terminate(waiter)
        return unless waiter

        begin
          Process.kill("TERM", -waiter.pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join(0.05)
        begin
          Process.kill("KILL", -waiter.pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join(0.05)
      end
    end

    class History
      def initialize(command_runner: CommandRunner.new, monotonic_clock: MONOTONIC_CLOCK)
        @command_runner = command_runner
        @monotonic_clock = monotonic_clock
      end

      def commits(hive_state_path:, slug:, deadline: nil)
        result = capture(
          [
            "git", "-C", hive_state_path, "log", Hive::GitOps::HIVE_BRANCH,
            "--format=%H%x00%cI%x00%s", "-F", "--grep", slug
          ],
          deadline: deadline
        )
        unless result.status.success?
          detail = result.err.strip.empty? ? result.out : result.err
          raise Hive::GitError,
                "git log #{Hive::GitOps::HIVE_BRANCH} failed for #{slug}: #{detail}"
        end

        result.out.each_line.filter_map do |line|
          sha, committed_at, subject = line.chomp.split("\0", 3)
          next if sha.to_s.empty? || committed_at.to_s.empty? || subject.to_s.empty?
          next unless subject.include?("/#{slug} ")

          { sha: sha, committed_at: committed_at, subject: subject }
        end
      end

      def file_at(hive_state_path:, sha:, relative_path:, deadline: nil)
        result = capture(
          [ "git", "-C", hive_state_path, "show", "#{sha}:#{relative_path}" ],
          deadline: deadline
        )
        result.status.success? ? result.out : nil
      end

      private

      def capture(argv, deadline:)
        return Open3.capture3(*argv).then { |out, err, status| CommandResult.new(out:, err:, status:) } unless deadline

        @command_runner.capture(argv, deadline: deadline, monotonic_clock: @monotonic_clock)
      end
    end

    module_function

    def parse(value, warn_context: nil)
      return nil if value.nil?
      return value.utc if value.is_a?(Time)
      unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        warn "hive: completion_time: invalid completed_at for #{warn_context}; keeping task visible" if warn_context
        return nil
      end

      Time.iso8601(value).utc
    rescue ArgumentError
      warn "hive: completion_time: invalid completed_at for #{warn_context}; keeping task visible" if warn_context
      nil
    end

    def discover(task, history: History.new, deadline: nil, monotonic_clock: MONOTONIC_CLOCK)
      ensure_before_deadline!(deadline, monotonic_clock)
      from_history(task, history: history, deadline: deadline, monotonic_clock: monotonic_clock) ||
        discover_from_mtimes(task, deadline: deadline, monotonic_clock: monotonic_clock)
    rescue Hive::GitError => e
      warn "hive: completion_time: #{e.message}; falling back to filesystem mtimes"
      discover_from_mtimes(task, deadline: deadline, monotonic_clock: monotonic_clock)
    end

    def discover_from_mtimes(task, deadline: nil, monotonic_clock: MONOTONIC_CLOCK)
      ensure_before_deadline!(deadline, monotonic_clock)
      readable_mtime(task.state_file) || readable_mtime(task.folder)
    end

    def from_history(task, history: History.new, deadline: nil,
                     monotonic_clock: MONOTONIC_CLOCK)
      ensure_before_deadline!(deadline, monotonic_clock)
      membership_workflow = task.action_workflow if task.respond_to?(:action_workflow)
      terminal = (membership_workflow || task.workflow).stages.last
      commit_args = { hive_state_path: task.hive_state_path, slug: task.slug }
      commit_args[:deadline] = deadline if deadline
      entries = history.commits(**commit_args)
      credible = entries.filter_map do |entry|
        ensure_before_deadline!(deadline, monotonic_clock)
        next unless completion_entry?(task, terminal, entry, history: history, deadline: deadline)

        parse(entry.fetch(:committed_at))
      end
      credible.min
    end

    def completion_entry?(task, terminal, entry, history:, deadline: nil)
      subject = entry.fetch(:subject)
      arrival = subject.include?("/#{task.slug} ") &&
                subject.include?("approve") && subject.include?("-> #{terminal.dir}")
      return true if terminal.kind == :inert && arrival
      return false unless [ :agent, :council ].include?(terminal.kind)
      return false unless subject.start_with?("hive: #{terminal.dir}/#{task.slug} ")

      state_rel = File.join("stages", terminal.dir, task.slug, terminal.state_file)
      state_args = {
        hive_state_path: task.hive_state_path, sha: entry.fetch(:sha), relative_path: state_rel
      }
      state_args[:deadline] = deadline if deadline
      state = history.file_at(**state_args)
      return false unless state&.match?(TERMINAL_MARKER)

      deliverable = terminal.deliverable || terminal.state_file
      deliverable_rel = File.join("stages", terminal.dir, task.slug, deliverable)
      deliverable_args = {
        hive_state_path: task.hive_state_path, sha: entry.fetch(:sha), relative_path: deliverable_rel
      }
      deliverable_args[:deadline] = deadline if deadline
      contents = history.file_at(**deliverable_args)
      !contents.to_s.empty?
    end

    def readable_mtime(path)
      File.mtime(path).utc
    rescue SystemCallError, IOError
      nil
    end

    def ensure_before_deadline!(deadline, monotonic_clock)
      return unless deadline
      return if monotonic_clock.call < deadline

      raise DeadlineExceeded, "completion history deadline exceeded"
    end
  end
end
