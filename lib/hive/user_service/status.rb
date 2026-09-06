require "digest"
require "json"

module Hive
  class UserService
    class Status
      CONTENT_STATES = %i[absent matching drifted unsafe unreadable].freeze
      MANAGER_AVAILABILITIES = %i[available conclusively_absent indeterminate].freeze
      TRANSITIONAL_ACTIVE_STATES = %w[activating deactivating reloading].freeze

      attr_reader :platform, :unit_path, :content_state, :file_identity,
                  :manager_available, :manager_availability, :enabled, :running,
                  :active_state, :load_state, :fragment_path, :need_daemon_reload, :main_pid,
                  :process_start, :manager_evidence_source, :diagnostics

      def initialize(platform:, unit_path:, content_state:, file_identity:,
                     manager_available: nil, manager_availability: nil,
                     enabled:, running:, active_state: nil, load_state: nil, fragment_path: nil,
                     need_daemon_reload: nil, main_pid: nil, process_start: nil,
                     manager_evidence_source: :observed,
                     diagnostics: [])
        @platform = platform.to_sym
        @unit_path = unit_path
        @content_state = content_state.to_sym
        unless CONTENT_STATES.include?(@content_state)
          raise ArgumentError, "unknown service content state #{content_state.inspect}"
        end

        @file_identity = file_identity&.transform_keys(&:to_sym)&.freeze
        @manager_availability = if manager_availability
          manager_availability.to_sym
        elsif manager_available
          :available
        else
          :conclusively_absent
        end
        unless MANAGER_AVAILABILITIES.include?(@manager_availability)
          raise ArgumentError, "unknown manager availability #{manager_availability.inspect}"
        end
        @manager_available = @manager_availability == :available
        @enabled = !!enabled
        @running = !!running
        @active_state = active_state&.to_s
        @load_state = load_state&.to_s
        @fragment_path = fragment_path&.then { |path| File.expand_path(path.to_s) }
        @need_daemon_reload = if need_daemon_reload.nil?
          nil
        else
          !!need_daemon_reload
        end
        @main_pid = Integer(main_pid || 0)
        @process_start = process_start&.to_s
        @manager_evidence_source = manager_evidence_source.to_sym
        @diagnostics = diagnostics.map(&:to_sym).uniq.freeze
        @observation_key = Digest::SHA256.hexdigest(
          JSON.generate(
            platform: @platform,
            unit_path: @unit_path,
            content_state: @content_state,
            file_identity: @file_identity,
            manager_availability: @manager_availability,
            enabled: @enabled,
            running: @running,
            active_state: @active_state,
            load_state: @load_state,
            fragment_path: @fragment_path,
            need_daemon_reload: @need_daemon_reload,
            main_pid: @main_pid,
            process_start: @process_start,
            manager_evidence_source: @manager_evidence_source,
            diagnostics: @diagnostics
          )
        )
        freeze
      end

      def installed?
        content_state != :absent
      end

      def manager_available?
        manager_available
      end

      def enabled?
        enabled
      end

      def running?
        running
      end

      def process_live?
        main_pid.positive?
      end

      def stopped?
        !running? && !process_live? && !TRANSITIONAL_ACTIVE_STATES.include?(active_state)
      end

      def loaded_definition_current?
        return true unless platform == :linux

        load_state == "loaded" && fragment_path == unit_path && need_daemon_reload == false
      end

      def process_identity
        return nil unless running? && main_pid.positive? && process_start && !process_start.empty?

        { main_pid: main_pid, process_start: process_start }.freeze
      end

      def observation_key
        @observation_key
      end

      def to_h
        {
          "platform" => platform.to_s,
          "unit_path" => unit_path,
          "service_installed" => installed?,
          "service_enabled" => enabled?,
          "service_running" => running?,
          "service_manager_available" => manager_available?
        }
      end
    end
  end
end
