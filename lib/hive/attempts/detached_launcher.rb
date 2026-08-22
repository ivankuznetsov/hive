require "json"
require "rbconfig"
require "digest"
require "hive/attempts/contracts"
require "hive/attempts/store"

module Hive
  module Attempts
    # POSIX double-fork adapter. The short-lived launcher creates a new
    # session, forks the authoritative wrapper into it, then exits so neither
    # the foreground caller nor daemon remains the wrapper's lifecycle parent.
    class DetachedLauncher
      def self.supported?
        Process.respond_to?(:fork) && Process.respond_to?(:setsid)
      end

      def initialize(store:, heartbeat_sec: 5, stale_sec: 30,
                     first_heartbeat_timeout_sec: 30, timeout_sec: nil,
                     kill_grace_sec: 1, ready_timeout_sec: 5,
                     capability: -> { self.class.supported? },
                     systemd_scope: -> { self.class.systemd_scope_available? },
                     systemd_run: "systemd-run",
                     hive_executable: File.expand_path("../../../bin/hive", __dir__))
        @store = store
        @heartbeat_sec = heartbeat_sec
        @stale_sec = stale_sec
        @first_heartbeat_timeout_sec = first_heartbeat_timeout_sec
        @timeout_sec = timeout_sec
        @kill_grace_sec = kill_grace_sec
        @ready_timeout_sec = ready_timeout_sec
        @capability = capability
        @systemd_scope = systemd_scope
        @systemd_run = systemd_run
        @hive_executable = hive_executable
      end

      # A POSIX session survives an ordinary parent exit, but systemd still
      # keeps it in the daemon service's cgroup. systemd-oomd kills that whole
      # cgroup, so a single memory-pressure event can otherwise erase the
      # daemon and every accepted attempt together. A transient user scope is
      # a sibling cgroup and preserves the caller's environment and inherited
      # descriptors, which is exactly the durable-attempt boundary we need.
      def self.systemd_scope_available?
        return false unless RbConfig::CONFIG.fetch("host_os", "").include?("linux")

        runtime_dir = ENV["XDG_RUNTIME_DIR"].to_s
        runtime_dir = "/run/user/#{Process.uid}" if runtime_dir.empty?
        return false unless File.socket?(File.join(runtime_dir, "bus"))

        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
          File.executable?(File.join(dir, "systemd-run"))
        end
      rescue SystemCallError
        false
      end

      def preflight!
        unless @capability.call && File.file?(@hive_executable)
          raise UnsupportedDetachment,
                "durable attempts require POSIX detached-session support before launch can be accepted"
        end
        true
      end

      def launch(record, claim_capability:)
        preflight!
        use_systemd_scope = @systemd_scope.call == true
        reader, writer = IO.pipe
        launcher_pid = fork do
          reader.close
          begin
            Process.setsid
            fork_wrapper(record, claim_capability, writer, use_systemd_scope:)
          rescue StandardError => e
            writer.write(JSON.generate(
              "claimed" => false, "attempt_id" => record.attempt_id,
              "error" => "launcher failed: #{e.message}"
            ) + "\n")
          ensure
            writer.close unless writer.closed?
          end
          exit! 0
        end
        writer.close
        Process.wait(launcher_pid)

        ready = IO.select([ reader ], nil, nil, @ready_timeout_sec)
        return { "claimed" => false, "attempt_id" => record.attempt_id, "state" => "launching" } unless ready

        line = reader.gets
        line ? JSON.parse(line) : { "claimed" => false, "attempt_id" => record.attempt_id }
      ensure
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
      end

      private

      def fork_wrapper(record, claim_capability, writer, use_systemd_scope: false)
        claim_reader, claim_writer = IO.pipe
        claim_writer.write(claim_capability)
        claim_writer.close
        wrapper_pid = fork do
          writer.close_on_exec = false
          claim_reader.close_on_exec = false
          command = [
            RbConfig.ruby, @hive_executable, "__attempt-supervise", record.attempt_id,
            "--store-root", @store.root,
            "--heartbeat-sec", @heartbeat_sec.to_s,
            "--stale-sec", @stale_sec.to_s,
            "--first-heartbeat-timeout-sec", @first_heartbeat_timeout_sec.to_s,
            "--kill-grace-sec", @kill_grace_sec.to_s
          ]
          command.concat([ "--timeout-sec", @timeout_sec.to_s ]) if @timeout_sec
          command = systemd_scope_command(record, command) if use_systemd_scope
          env = ENV.keys.grep(/\AHIVE_ATTEMPT_/).to_h { |key| [ key, nil ] }.merge(
            "HIVE_ATTEMPT_READY_FD" => writer.fileno.to_s,
            "HIVE_ATTEMPT_CLAIM_FD" => claim_reader.fileno.to_s
          )
          exec(
            env, *command,
            writer.fileno => writer.fileno,
            claim_reader.fileno => claim_reader.fileno,
            in: File::NULL, out: File::NULL, err: File::NULL,
            close_others: true
          )
        end
        claim_reader.close unless claim_reader.closed?
        wrapper_pid
      ensure
        claim_writer&.close unless claim_writer&.closed?
      end

      def systemd_scope_command(record, command)
        unit = "hive-attempt-#{Digest::SHA256.hexdigest(record.attempt_id.to_s)[0, 24]}"
        [
          @systemd_run, "--user", "--scope", "--quiet", "--collect",
          "--unit=#{unit}", "--description=Hive durable attempt #{record.attempt_id}",
          *command
        ]
      end
    end
  end
end
