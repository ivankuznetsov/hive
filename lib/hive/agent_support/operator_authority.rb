require "open3"
require "hive/errors"
require "hive/agent_support"
require "hive/process_kill"

module Hive::AgentSupport
  # Managed launches carry denial provenance in their initial process
  # environment. The command boundary reads the live OS ancestry, including
  # the agent process, rather than trusting the command's mutable environment.
  # This is a same-user workflow boundary, not isolation from a hostile process
  # that can modify other processes or controller code as the operator's uid.
  module OperatorAuthority
    ENVIRONMENT_KEY = "HIVE_MANAGED_AGENT_POLICY".freeze
    ENVIRONMENT_VALUE = "operator-commands-denied/v1".freeze
    LAUNCH_ENVIRONMENT = { ENVIRONMENT_KEY => ENVIRONMENT_VALUE }.freeze
    MAX_ANCESTORS = 128
    MAX_ENVIRONMENT_BYTES = 8 * 1024 * 1024

    class Denied < Hive::Error
      def initialize
        super("review-grant requires an operator; Hive-managed agents cannot grant review passes")
      end

      def error_kind = "agent_denied"
    end

    class AuthorityUnavailable < Hive::Error
      def initialize
        super("operator source could not be verified from process ancestry; retry from an operator terminal")
      end

      def error_kind = "source_unverified"
    end

    module_function

    def assert_operator!(process_tree: ProcessTree.new)
      raise Denied if process_tree.call.any? { |ancestor| ancestor.fetch("managed") }

      { "caller" => "uid:#{Process.uid}".freeze, "source" => "operator_cli".freeze }.freeze
    rescue IOError, SystemCallError, ArgumentError, IndexError, TypeError
      raise AuthorityUnavailable
    end

    def launch_environment
      # Refuse launches when their future command callers cannot inspect the
      # managed ancestor. This policy is required, unlike optional tool scopes.
      ProcessTree.new.call
      LAUNCH_ENVIRONMENT
    rescue IOError, SystemCallError, ArgumentError, IndexError, TypeError
      raise AuthorityUnavailable
    end

    class ProcessTree
      def initialize(pid: Process.pid, uid: Process.uid, proc_root: "/proc",
                     platform: RUBY_PLATFORM, ps: nil)
        @pid = pid
        @uid = uid
        @proc_root = proc_root
        @platform = platform
        @ps = ps
      end

      def call
        ancestors = []
        pid = @pid
        MAX_ANCESTORS.times do
          raise IOError, "cyclic process ancestry" if ancestors.any? { |row| row.fetch("pid") == pid }

          snapshot = linux? ? proc_snapshot(pid) : ps_snapshot(pid)
          ancestors << snapshot
          return ancestors if snapshot.fetch("managed") || snapshot.fetch("parent") <= 1

          pid = snapshot.fetch("parent")
        end
        raise IOError, "process ancestry exceeds its bound"
      end

      private

      def linux? = @platform.include?("linux")

      def proc_snapshot(pid)
        root = File.join(@proc_root, pid.to_s)
        before = proc_identity(root)
        managed = File.stat(root).uid == @uid && proc_managed?(root, before.fetch(0))
        raise IOError, "process ancestry changed" unless before == proc_identity(root)

        { "pid" => pid, "parent" => before.fetch(0), "managed" => managed }
      end

      def proc_managed?(root, parent)
        managed_environment?(File.binread(File.join(root, "environ"), MAX_ENVIRONMENT_BYTES + 1))
      rescue Errno::EACCES, Errno::EPERM
        # systemd --user is deliberately non-dumpable. Its PPID=1 places it
        # at the OS session boundary, outside any live managed ancestry.
        raise unless parent <= 1

        false
      end

      def proc_identity(root)
        fields = File.binread(File.join(root, "stat"), 4096).split(") ").last.to_s.split
        [ Integer(fields.fetch(1), 10), Integer(fields.fetch(19), 10) ]
      end

      def managed_environment?(bytes)
        raise IOError, "process environment exceeds its bound" if bytes.bytesize > MAX_ENVIRONMENT_BYTES

        bytes.split("\0").include?("#{ENVIRONMENT_KEY}=#{ENVIRONMENT_VALUE}")
      end

      def ps_snapshot(pid)
        ps = @ps || Hive::ProcessKill::SYSTEM_PS_PATHS.find do |path|
          File.file?(path) && File.executable?(path)
        end
        raise IOError, "process inventory is unavailable" unless ps

        before = ps_identity(ps, pid)
        environment, _stderr, status = Open3.capture3(ps, "eww", "-p", pid.to_s, "-o", "command=")
        raise IOError, "process environment is unavailable" unless status.success?
        raise IOError, "process environment exceeds its bound" if environment.bytesize > MAX_ENVIRONMENT_BYTES
        raise IOError, "process ancestry changed" unless before == ps_identity(ps, pid)

        managed = before.fetch(1) == @uid && environment.match?(
          /(?:\A|\s)#{ENVIRONMENT_KEY}=#{Regexp.escape(ENVIRONMENT_VALUE)}(?:\s|\z)/
        )
        { "pid" => pid, "parent" => before.fetch(0), "managed" => managed }
      end

      def ps_identity(ps, pid)
        output, _stderr, status = Open3.capture3(
          ps, "-p", pid.to_s, "-o", "ppid=", "-o", "uid=", "-o", "lstart="
        )
        raise IOError, "process identity is unavailable" unless status.success?

        parent, uid, started = output.strip.split(/\s+/, 3)
        raise IOError, "process start identity is unavailable" if started.to_s.empty?

        [ Integer(parent, 10), Integer(uid, 10), started ]
      end
    end
  end
end
