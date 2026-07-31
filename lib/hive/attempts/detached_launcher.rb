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
                     hive_executable: File.expand_path("../../../bin/hive", __dir__),
                     worker_release_io: nil)
        @store = store
        @heartbeat_sec = heartbeat_sec
        @stale_sec = stale_sec
        @first_heartbeat_timeout_sec = first_heartbeat_timeout_sec
        @timeout_sec = timeout_sec
        @kill_grace_sec = kill_grace_sec
        @ready_timeout_sec = ready_timeout_sec
        @capability = capability
        @hive_executable = hive_executable
        @worker_release_io = worker_release_io
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
            wrapper_pid =
              fork_wrapper(record, claim_capability, writer)
            write_qualification_custody(
              record,
              wrapper_pid
            )
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
        @worker_release_io&.close unless
          @worker_release_io&.closed?
      end

      private

      def fork_wrapper(record, claim_capability, writer)
        claim_reader, claim_writer = IO.pipe
        claim_writer.write(claim_capability)
        claim_writer.close
        wrapper_pid = fork do
          writer.close_on_exec = false
          claim_reader.close_on_exec = false
          @worker_release_io.close_on_exec = false if
            @worker_release_io
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
          options = {
            writer.fileno => writer.fileno,
            claim_reader.fileno => claim_reader.fileno,
            in: File::NULL,
            out: File::NULL,
            err: File::NULL,
            close_others: true
          }
          if @worker_release_io
            release_fd = @worker_release_io.fileno
            env["HIVE_ATTEMPT_WORKER_RELEASE_FD"] =
              release_fd.to_s
            options[release_fd] = release_fd
          end
          exec(
            env, *command,
            **options
          )
        end
        claim_reader.close unless claim_reader.closed?
        wrapper_pid
      ensure
        claim_writer&.close unless claim_writer&.closed?
      end

      def write_qualification_custody(record, wrapper_pid)
        root = ENV["HIVE_QUALIFICATION_CUSTODY_ROOT"].to_s
        return if root.empty?

        require "hive/attempts/process_identity"
        require "hive/modules/migration/qualification_process_custody"
        snapshot =
          Hive::Attempts::ProcessIdentity.new.capture(
            wrapper_pid
          )
        unless snapshot
          raise Hive::ConfigError,
                "qualification wrapper custody is unavailable"
        end
        Hive::Modules::Migration::QualificationProcessCustody.write(
          root: root,
          attempt_id: record.attempt_id,
          wrapper: snapshot.to_h
        )
      rescue StandardError
        begin
          Process.kill("TERM", Integer(wrapper_pid))
        rescue Errno::ESRCH, Errno::EPERM, ArgumentError,
               TypeError
          nil
        end
        raise
      end
    end
  end
end
