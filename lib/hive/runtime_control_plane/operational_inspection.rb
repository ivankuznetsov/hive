require "hive/paths"

module Hive
  module RuntimeControlPlane
    # One-shot CLI authority for the operational-status read-only fallback.
    # The context is thread/process scoped and bound to one runtime database;
    # long-lived in-process Status callers never create it.
    module OperationalInspection
      THREAD_KEY = :hive_runtime_operational_inspection

      module_function

      def activate_from_failure(error:, argv:, state_home:, inherited_reservation: false,
                                database: nil)
        return false if inherited_reservation
        return false unless error.is_a?(Unavailable) && error.code == :state_storage_read_only
        return false unless eligible_route?(argv)

        root = File.expand_path(state_home)
        database ||= Database.new(path: Hive::Paths.runtime_control_plane_path(root))
        return false unless database.confirmed_read_only_storage?

        Thread.current[THREAD_KEY] = {
          owner_pid: Process.pid,
          state_home: root,
          database_path: File.expand_path(database.path)
        }.freeze
        true
      end

      # Kept here rather than on ActivationGate so loading the low-level
      # runtime-control-plane entrypoint does not pull CLI activation and its
      # higher-level agent/work-ledger dependencies into every database user.
      def eligible_route?(argv)
        words = Array(argv).map(&:to_s)
        return false unless words.find { |argument| !argument.start_with?("-") } == "status"
        return false unless boolean_option_value(words, "operational") == true
        return false if %w[diagnose daemon-task].any? do |name|
          words.any? { |argument| argument == "--#{name}" || argument.start_with?("--#{name}=") }
        end

        %w[write force internal-task-graph].none? do |name|
          boolean_option_value(words, name) == true
        end
      end

      def active?
        context = current
        context && context.fetch(:owner_pid) == Process.pid
      end

      def active_for?(database_path)
        active? && current.fetch(:database_path) == File.expand_path(database_path)
      end

      def clear!
        !Thread.current[THREAD_KEY].nil?
      ensure
        Thread.current[THREAD_KEY] = nil
      end

      def current = Thread.current[THREAD_KEY]
      private_class_method :current

      def boolean_option_value(words, name)
        Array(words).map do |argument|
          case argument
          when "--#{name}", "--#{name}=true", "--#{name}=TRUE", "--#{name}=t", "--#{name}=T"
            true
          when "--no-#{name}", "--skip-#{name}", "--#{name}=false", "--#{name}=FALSE",
               "--#{name}=f", "--#{name}=F"
            false
          end
        end.compact.last
      end
      private_class_method :boolean_option_value
    end
  end
end
