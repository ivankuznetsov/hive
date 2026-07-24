require "json"
require "rbconfig"
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
                     hive_executable: File.expand_path("../../../bin/hive", __dir__))
        @store = store
        @heartbeat_sec = heartbeat_sec
        @stale_sec = stale_sec
        @first_heartbeat_timeout_sec = first_heartbeat_timeout_sec
        @timeout_sec = timeout_sec
        @kill_grace_sec = kill_grace_sec
        @ready_timeout_sec = ready_timeout_sec
        @capability = capability
        @hive_executable = hive_executable
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
        reader, writer = IO.pipe
        launcher_pid = fork do
          reader.close
          begin
            Process.setsid
            fork_wrapper(record, claim_capability, writer)
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

      def fork_wrapper(record, claim_capability, writer)
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
    end
  end
end
