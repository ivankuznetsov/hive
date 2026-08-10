require "digest"
require "json"

module Hive
  class UserService
    class Definition
      PLATFORMS = %i[linux macos unsupported].freeze

      attr_reader :platform, :service_name, :target_path, :content, :launchd_label

      def initialize(platform:, service_name:, target_path:, content:, launchd_label: nil)
        @platform = platform.to_sym
        raise ArgumentError, "unsupported service platform #{platform.inspect}" unless PLATFORMS.include?(@platform)

        @service_name = String(service_name)
        raise ArgumentError, "service_name must not be empty" if @service_name.empty?

        @target_path = target_path&.then { |path| File.expand_path(path) }
        @content = content&.dup&.freeze
        @launchd_label = String(launchd_label || "local.#{@service_name}")
        validate_platform_fields!
        @fingerprint = Digest::SHA256.hexdigest(
          JSON.generate(
            platform: @platform,
            service_name: @service_name,
            target_path: @target_path,
            content: @content,
            launchd_label: @launchd_label
          )
        )
        freeze
      end

      def fingerprint
        @fingerprint
      end

      private

      def validate_platform_fields!
        return if platform == :unsupported && target_path.nil? && content.nil?
        return if platform != :unsupported && target_path

        raise ArgumentError,
              "supported services require target_path; unsupported services require neither target_path nor content"
      end
    end
  end
end
