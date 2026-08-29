require "thread"
require "hive/errors"
require "hive/paths"

module Hive
  module RuntimeControlPlane
    APPLICATION_ID = 0x48495645
    SCHEMA_VERSION = 1
    BUSY_TIMEOUT_MS = 5_000
    MINIMUM_SQLITE_VERSION = "3.35.0".freeze
    MIGRATIONS_DIR = File.expand_path("runtime_control_plane/migrations", __dir__).freeze

    class Error < Hive::Error
      attr_reader :code, :action, :details

      def initialize(message, code:, action: nil, details: {})
        super(message)
        @code = code.to_sym
        @action = action
        @details = details.freeze
      end
    end

    class MigrationRequired < Error
      def exit_code = Hive::ExitCodes::CONFIG
    end

    class Unavailable < Error
      def exit_code = Hive::ExitCodes::UNAVAILABLE
    end

    class IntegrityError < Error
      def exit_code = Hive::ExitCodes::SOFTWARE
    end

    class ForkUnsafe < Error
      def initialize(message)
        super(
          message,
          code: :fork_during_transaction,
          action: "finish or roll back the transaction before creating a process"
        )
      end

      def exit_code = Hive::ExitCodes::TEMPFAIL
    end

    class CodecError < Error
      def exit_code = Hive::ExitCodes::CONFIG
    end

    class IdentityError < Error
      def exit_code = Hive::ExitCodes::CONFIG
    end

    class << self
      def database(path: Hive::Paths.runtime_control_plane_path, **options)
        reset_after_fork!
        owner_mutex.synchronize do
          expanded = File.expand_path(path)
          if @database && @database.path != expanded
            @database.disconnect
            @database = nil
          end
          @database ||= Database.new(path: expanded, **options)
        end
      end

      def disconnect
        reset_after_fork!
        owner_mutex.synchronize do
          @database&.disconnect
          @database = nil
        end
        true
      end

      private

      def reset_after_fork!
        pid = Process.pid
        return if @owner_pid == pid

        @database&.disconnect
        @database = nil
        @owner_pid = pid
        @owner_mutex = Mutex.new
      end

      def owner_mutex
        @owner_mutex ||= Mutex.new
      end
    end
  end
end

require "hive/runtime_control_plane/process_guard"
require "hive/runtime_control_plane/codec"
require "hive/runtime_control_plane/identity"
require "hive/runtime_control_plane/diagnostics"
require "hive/runtime_control_plane/database"
require "hive/runtime_control_plane/operational_repository"
