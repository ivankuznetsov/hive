require "hive/paths"

module Hive
  module RuntimeControlPlane
    # One-shot CLI authority for the operational-status read-only fallback.
    # The one-shot authority is fiber-local (via Thread.current storage), bound
    # to the activating PID and one runtime database. It is intentionally not
    # propagated to worker threads or long-lived in-process Status callers.
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
          session_id: Object.new,
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
        switches = words.map { |word| word.start_with?("--") ? word.tr("_", "-") : word }
        return false unless words.find { |argument| !argument.start_with?("-") } == "status"
        return false unless boolean_option_value(switches, "operational") == true
        return false if %w[diagnose daemon-task].any? do |name|
          switches.any? { |argument| argument == "--#{name}" || argument.start_with?("--#{name}=") }
        end

        %w[write force internal-task-graph].none? do |name|
          boolean_option_value(switches, name) == true
        end
      end

      def active?
        context = current
        context && context.fetch(:owner_pid) == Process.pid
      end

      def active_for?(database_path)
        active? && current.fetch(:database_path) == File.expand_path(database_path)
      end

      def session_id_for(database_path)
        current.fetch(:session_id) if active_for?(database_path)
      end

      def clear!
        !Thread.current[THREAD_KEY].nil?
      ensure
        Thread.current[THREAD_KEY] = nil
      end

      def current = Thread.current[THREAD_KEY]
      private_class_method :current

      def boolean_option_value(words, name)
        Array(words).each_with_index.map do |argument, index|
          case argument
          when "--#{name}"
            value = boolean_literal(words[index + 1])
            value.nil? ? true : value
          when /\A--#{Regexp.escape(name)}=(.+)\z/i
            boolean_literal(Regexp.last_match(1))
          when "--no-#{name}", "--skip-#{name}"
            false
          end
        end.compact.last
      end
      private_class_method :boolean_option_value

      def boolean_literal(value)
        return true if %w[true t].include?(value.to_s.downcase)
        false if %w[false f].include?(value.to_s.downcase)
      end
      private_class_method :boolean_literal
    end
  end
end
