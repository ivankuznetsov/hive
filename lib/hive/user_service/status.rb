require "digest"
require "json"

module Hive
  class UserService
    class Status
      CONTENT_STATES = %i[absent matching drifted unsafe unreadable].freeze

      attr_reader :platform, :unit_path, :content_state, :file_identity,
                  :manager_available, :enabled, :running, :diagnostics

      def initialize(platform:, unit_path:, content_state:, file_identity:,
                     manager_available:, enabled:, running:, diagnostics: [])
        @platform = platform.to_sym
        @unit_path = unit_path
        @content_state = content_state.to_sym
        unless CONTENT_STATES.include?(@content_state)
          raise ArgumentError, "unknown service content state #{content_state.inspect}"
        end

        @file_identity = file_identity&.transform_keys(&:to_sym)&.freeze
        @manager_available = !!manager_available
        @enabled = !!enabled
        @running = !!running
        @diagnostics = diagnostics.map(&:to_sym).uniq.freeze
        @observation_key = Digest::SHA256.hexdigest(
          JSON.generate(
            platform: @platform,
            unit_path: @unit_path,
            content_state: @content_state,
            file_identity: @file_identity,
            manager_available: @manager_available,
            enabled: @enabled,
            running: @running,
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
