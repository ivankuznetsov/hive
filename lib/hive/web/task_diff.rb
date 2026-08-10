require "open3"
require "hive"
require "hive/invoked_binary"
require "hive/secret_patterns"
require "hive/worktree"

module Hive
  module Web
    # Produces a bounded, typed view of one task-owned worktree. The service is
    # deliberately independent of Rails so HTML and JSON controllers share the
    # exact same ownership, subprocess, redaction, and status contract.
    class TaskDiff
      DEFAULT_TIMEOUT_SEC = 15.0
      DEFAULT_MAX_BYTES = 512 * 1024
      DIAGNOSTIC_MAX_BYTES = 16 * 1024
      UNTRACKED_MAX_PATHS = 500
      POLL_INTERVAL_SEC = 0.02

      class MissingBinary < Hive::Error; end
      class CommandTimeout < Hive::Error; end

      Result = Data.define(
        :state, :sections, :truncated, :invalid_encoding, :reason,
        :diagnostic, :next_action, :http_status
      ) do
        def to_h
          {
            "state" => state,
            "sections" => sections,
            "truncated" => truncated,
            "invalid_encoding" => invalid_encoding,
            "reason" => reason,
            "diagnostic" => diagnostic,
            "next_action" => next_action
          }
        end
      end

      CommandStatus = Data.define(:success?, :exitstatus)

      def initialize(task:, expected_root: nil, pointer_reader: Hive::Worktree.method(:read_owned_pointer),
                     runner: nil, git_bin: nil, timeout_sec: DEFAULT_TIMEOUT_SEC,
                     max_bytes: DEFAULT_MAX_BYTES)
        @task = task
        @expected_root = expected_root || Hive::Worktree.canonical_root(task.project_root)
        @pointer_reader = pointer_reader
        @runner = runner || method(:run_command)
        @git_bin = git_bin
        @timeout_sec = Float(timeout_sec)
        @max_bytes = Integer(max_bytes)
        raise ArgumentError, "diff timeout must be positive" unless @timeout_sec.positive?
        raise ArgumentError, "diff byte cap must be positive" unless @max_bytes.positive?
      end

      def call
        pointer = read_pointer
        path = pointer.fetch("path")
        base = pointer["execute_base_head"].to_s
        base = pointer["base_oid"].to_s unless valid_oid?(base)
        base = resolve_head(path) unless valid_oid?(base)

        remaining = @max_bytes
        truncated = false
        invalid_encoding = false
        sections = {}
        command_specs(base).each do |name, args, nul_delimited|
          output, command_truncated = capture(path, args, max_bytes: [ remaining, 1 ].max)
          text, invalid = normalize(output, nul_delimited: nul_delimited)
          text, section_truncated = cap(text, remaining)
          sections[name] = text
          remaining -= text.bytesize
          truncated ||= command_truncated || section_truncated
          invalid_encoding ||= invalid
        end

        state =
          if truncated || invalid_encoding
            "truncated"
          elsif sections.values.all?(&:empty?)
            "empty"
          else
            "available"
          end
        Result.new(
          state: state,
          sections: sections,
          truncated: truncated,
          invalid_encoding: invalid_encoding,
          reason: invalid_encoding ? "invalid_encoding_scrubbed" : nil,
          diagnostic: nil,
          next_action: state == "empty" ? "Return to the task status." : "Inspect the owned worktree for full context.",
          http_status: 200
        )
      rescue Hive::WorktreeError, Errno::ENOENT, Errno::ENOTDIR => e
        unavailable(
          status: 409, reason: "worktree_unavailable", error: e,
          next_action: "Inspect task status and run the worktree diagnosis; Hive will not recreate it from this page."
        )
      rescue MissingBinary => e
        unavailable(
          status: 503, reason: "git_missing", error: e,
          next_action: "Install Git and retry this single diff request."
        )
      rescue CommandTimeout => e
        unavailable(
          status: 504, reason: "git_timeout", error: e,
          next_action: "Retry once; if it repeats, inspect the owned worktree and Git process state locally."
        )
      rescue CommandFailure => e
        unavailable(
          status: 422, reason: "git_failed", error: e,
          next_action: "Run the reported Git operation in the owned worktree after repairing its repository state."
        )
      end

      private

      CommandFailure = Class.new(Hive::Error)

      def read_pointer
        @pointer_reader.call(
          task_folder: @task.folder,
          project_root: @task.project_root,
          slug: @task.slug,
          expected_root: @expected_root
        )
      rescue ArgumentError
        # A small injectable seam for tests and older adapters that accept the
        # production arguments positionally.
        @pointer_reader.call(
          @task.folder,
          project_root: @task.project_root,
          slug: @task.slug,
          expected_root: @expected_root
        )
      end

      def command_specs(base)
        common = [ "--no-ext-diff", "--no-textconv" ]
        [
          [ "committed", [ "diff", *common, "#{base}..HEAD", "--" ], false ],
          [ "staged", [ "diff", *common, "--cached", "--" ], false ],
          [ "unstaged", [ "diff", *common, "--" ], false ],
          [ "untracked", [ "ls-files", "--others", "--exclude-standard", "-z" ], true ]
        ]
      end

      def resolve_head(path)
        output, = capture(path, [ "rev-parse", "HEAD" ], max_bytes: 256)
        oid = output.to_s.strip
        return oid if valid_oid?(oid)

        raise CommandFailure, "Git returned an invalid HEAD identity"
      end

      def capture(path, args, max_bytes:)
        git = @git_bin || Hive::InvokedBinary.which("git")
        raise MissingBinary, "Git executable is unavailable" unless git

        argv = [
          git, "-c", "core.hooksPath=/dev/null",
          "-c", "diff.external=", "-c", "core.pager=cat",
          "-c", "pager.diff=false", "-C", path, *args
        ]
        output, error, status, metadata = @runner.call(
          argv,
          timeout_sec: @timeout_sec,
          max_bytes: max_bytes,
          diagnostic_max_bytes: DIAGNOSTIC_MAX_BYTES
        )
        unless status.success?
          detail = error.to_s.empty? ? output.to_s : error.to_s
          raise CommandFailure,
                "Git exited #{status.respond_to?(:exitstatus) ? status.exitstatus : "nonzero"}: #{safe_text(detail)}"
        end

        [ output.to_s.b, metadata.is_a?(Hash) && metadata[:stdout_truncated] == true ]
      rescue Errno::ENOENT => e
        raise MissingBinary, e.message
      end

      def normalize(output, nul_delimited:)
        binary = String.new(output.to_s.b)
        valid = binary.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        text = binary.force_encoding(Encoding::UTF_8).scrub
        if nul_delimited
          paths = text.split("\0", -1).reject(&:empty?)
          paths = paths.first(UNTRACKED_MAX_PATHS)
          text = paths.join("\n")
          text << "\n" unless text.empty?
        end
        [ Hive::SecretPatterns.redact(text), !valid ]
      end

      def cap(text, bytes)
        mutable = String.new(text.to_s, encoding: Encoding::UTF_8)
        return [ mutable, false ] if mutable.bytesize <= bytes

        [ String.new(mutable.byteslice(0, bytes).to_s.force_encoding(Encoding::UTF_8).scrub), true ]
      end

      def safe_text(value)
        text = value.to_s.b.byteslice(0, DIAGNOSTIC_MAX_BYTES).to_s
                    .force_encoding(Encoding::UTF_8).scrub
        Hive::SecretPatterns.redact(text)
      end

      def unavailable(status:, reason:, error:, next_action:)
        Result.new(
          state: "unavailable",
          sections: empty_sections,
          truncated: false,
          invalid_encoding: false,
          reason: reason,
          diagnostic: safe_text(error.message),
          next_action: next_action,
          http_status: status
        )
      end

      def empty_sections
        %w[committed staged unstaged untracked].to_h do |name|
          [ name, String.new(encoding: Encoding::UTF_8) ]
        end
      end

      def valid_oid?(value)
        value.to_s.match?(/\A[0-9a-f]{40,64}\z/i)
      end

      def run_command(argv, timeout_sec:, max_bytes:, diagnostic_max_bytes:)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        pid = Process.spawn(
          {
            "GIT_TERMINAL_PROMPT" => "0",
            "GIT_CONFIG_NOSYSTEM" => "1",
            "GIT_SSH_COMMAND" => "ssh -oBatchMode=yes"
          },
          *argv,
          pgroup: true,
          in: File::NULL,
          out: stdout_w,
          err: stderr_w
        )
        stdout_w.close
        stderr_w.close
        out_reader = Thread.new { read_bounded(stdout_r, max_bytes) }
        err_reader = Thread.new { read_bounded(stderr_r, diagnostic_max_bytes) }
        status = wait_with_deadline(pid, timeout_sec)
        output, output_truncated = out_reader.value
        error, error_truncated = err_reader.value
        [
          output, error, CommandStatus.new(success?: status.success?, exitstatus: status.exitstatus),
          { stdout_truncated: output_truncated, stderr_truncated: error_truncated }
        ]
      rescue Errno::ENOENT => e
        raise MissingBinary, e.message
      ensure
        [ stdout_w, stderr_w, stdout_r, stderr_r ].each do |io|
          io&.close unless io&.closed?
        rescue IOError
          nil
        end
        [ out_reader, err_reader ].compact.each { |thread| thread.join(1) }
      end

      def read_bounded(io, max_bytes)
        output = String.new(encoding: Encoding::BINARY)
        truncated = false
        loop do
          chunk = io.readpartial(16 * 1024)
          remaining = max_bytes + 1 - output.bytesize
          output << chunk.byteslice(0, remaining) if remaining.positive?
          truncated ||= output.bytesize > max_bytes || chunk.bytesize > remaining
        end
      rescue EOFError, IOError
        [ output.byteslice(0, max_bytes).to_s, truncated ]
      end

      def wait_with_deadline(pid, timeout_sec)
        deadline = monotonic_now + timeout_sec
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          return waited.last if waited
          if monotonic_now >= deadline
            terminate_group(pid)
            raise CommandTimeout, "Git timed out after #{timeout_sec}s"
          end
          sleep POLL_INTERVAL_SEC
        end
      end

      def terminate_group(pid)
        Process.kill("TERM", -pid)
        deadline = monotonic_now + 1
        while monotonic_now < deadline
          waited = Process.waitpid2(pid, Process::WNOHANG)
          return if waited
          sleep POLL_INTERVAL_SEC
        end
        Process.kill("KILL", -pid)
        Process.waitpid2(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
