require "digest"
require "open3"
require "hive/repository_identity"

module Hive
  module ContextProvenance
    module RepositorySnapshot
      COMMAND_TIMEOUT_SECONDS = 2.0
      MAX_OUTPUT_BYTES = 16 * 1024
      POLL_SECONDS = 0.01

      module_function

      def capture(project_root, timeout_sec: COMMAND_TIMEOUT_SECONDS)
        root = File.realpath(File.expand_path(project_root))
        head = git(root, %w[rev-parse --verify HEAD], timeout_sec: timeout_sec)
        branch = git(root, %w[symbolic-ref --quiet --short HEAD], timeout_sec: timeout_sec)
        remote = git(root, %w[remote get-url origin], timeout_sec: timeout_sec)
        identity = repository_identity(remote, root)
        diagnostics = []
        diagnostics << diagnostic("head_unavailable") unless head
        diagnostics << diagnostic("repository_identity_unavailable") unless identity

        {
          "state" => head ? (identity ? "current" : "partial") : "unavailable",
          "head_oid" => valid_oid(head),
          "branch" => bounded(branch, 255),
          "repository" => identity,
          "observed_from" => "local_git",
          "diagnostics" => diagnostics
        }
      rescue SystemCallError, IOError, ArgumentError => e
        unavailable(e.class.name)
      end

      def git(root, args, timeout_sec: COMMAND_TIMEOUT_SECONDS)
        output, status, overflow = capture_command(
          [ "git", "-C", root, *args ], timeout_sec: timeout_sec,
          max_bytes: MAX_OUTPUT_BYTES
        )
        return nil unless status&.success? && !overflow

        output.to_s.strip
      rescue SystemCallError, IOError
        nil
      end

      def capture_command(argv, timeout_sec:, max_bytes:)
        reader, writer = IO.pipe
        pid = Process.spawn(
          { "GIT_TERMINAL_PROMPT" => "0", "GIT_OPTIONAL_LOCKS" => "0" },
          *argv, in: :close, out: writer, err: File::NULL, pgroup: true
        )
        writer.close
        output = String.new(encoding: Encoding::BINARY)
        overflow = false
        deadline = monotonic_now + timeout_sec
        status = nil
        loop do
          if output.bytesize <= max_bytes
            chunk = reader.read_nonblock([ 16 * 1024, max_bytes + 1 - output.bytesize ].max,
                                         exception: false)
            if chunk.is_a?(String)
              output << chunk
              overflow = true if output.bytesize > max_bytes
            end
          end
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            status = waited.last
            output << reader.read.to_s unless overflow
            overflow ||= output.bytesize > max_bytes
            break
          end
          if overflow || monotonic_now >= deadline
            terminate(pid)
            status = nil
            break
          end
          sleep POLL_SECONDS
        end
        [ output.byteslice(0, max_bytes).to_s, status, overflow ]
      ensure
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
      end

      def terminate(pid)
        Process.kill("TERM", -pid)
        deadline = monotonic_now + 0.1
        until monotonic_now >= deadline
          return if Process.waitpid(pid, Process::WNOHANG)

          sleep POLL_SECONDS
        end
        Process.kill("KILL", -pid)
        Process.waitpid(pid)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def repository_identity(remote, root)
        value = Hive::RepositoryIdentity.normalize(remote, base_path: root)
        return nil if value.to_s.empty?
        return value unless value.start_with?("local:")

        "local-sha256:#{Digest::SHA256.hexdigest(value)}"
      end

      def valid_oid(value)
        value if value.to_s.match?(/\A[0-9a-f]{40,64}\z/)
      end

      def bounded(value, bytes)
        return nil if value.to_s.empty?

        value.to_s.byteslice(0, bytes).to_s.force_encoding(Encoding::UTF_8).scrub("")
      end

      def unavailable(error_class)
        {
          "state" => "unavailable", "head_oid" => nil, "branch" => nil,
          "repository" => nil, "observed_from" => "local_git",
          "diagnostics" => [ diagnostic("capture_failed", error_class) ]
        }
      end

      def diagnostic(code, detail = nil)
        { "code" => code, "detail" => detail }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
