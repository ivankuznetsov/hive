require "hive"
require "hive/paths"

module Hive
  module Web
    # Single source of truth for the native shared-app environment migration.
    # Only the six enumerated HIVEBOX_* names are deprecated; container image,
    # supervisor, repo-root, and session-secret settings remain canonical.
    module Environment
      Setting = Data.define(:canonical, :legacy, :default)
      USE_SETTING_DEFAULT = Object.new.freeze

      SETTINGS = [
        Setting.new(canonical: "HIVE_WEB_APP_DIR", legacy: "HIVEBOX_WEB_APP_DIR", default: nil),
        Setting.new(canonical: "HIVE_WEB_ORIGIN", legacy: "HIVEBOX_ORIGIN", default: nil),
        Setting.new(
          canonical: "HIVE_WEB_STORAGE_DIR",
          legacy: "HIVEBOX_STORAGE_DIR",
          default: -> { File.join(Hive::Paths.state_home, "web-storage") }
        ),
        Setting.new(canonical: "HIVE_WEB_LOCAL_LOOPBACK", legacy: "HIVEBOX_LOCAL_LOOPBACK", default: nil),
        Setting.new(canonical: "HIVE_WEB_DIFF_TIMEOUT_SEC", legacy: "HIVEBOX_DIFF_TIMEOUT_SEC", default: "15"),
        Setting.new(canonical: "HIVE_WEB_CLONE_TIMEOUT_SEC", legacy: "HIVEBOX_CLONE_TIMEOUT_SEC", default: "180")
      ].freeze
      SETTINGS_BY_NAME = SETTINGS.to_h { |setting| [ setting.canonical, setting ] }.freeze

      module_function

      def value(canonical, environment: ENV, default: USE_SETTING_DEFAULT)
        setting = setting!(canonical)
        canonical_value = present_value(environment[setting.canonical])
        return canonical_value if canonical_value

        legacy_value = present_value(environment[setting.legacy])
        return legacy_value if legacy_value

        selected_default = default.equal?(USE_SETTING_DEFAULT) ? setting.default : default
        selected_default.respond_to?(:call) ? selected_default.call : selected_default
      end

      def boolean(canonical, environment: ENV, default: false)
        selected = value(canonical, environment: environment, default: default)
        return selected if selected == true || selected == false

        normalized = selected.to_s.strip.downcase
        return true if %w[1 true yes on].include?(normalized)
        return false if %w[0 false no off].include?(normalized)

        raise Hive::Error,
              "#{canonical} must be one of 1/0, true/false, yes/no, or on/off (got #{selected.inspect})"
      end

      def warnings(environment: ENV)
        SETTINGS.filter_map do |setting|
          legacy_value = present_value(environment[setting.legacy])
          next unless legacy_value

          canonical_set = !present_value(environment[setting.canonical]).nil?
          message = if canonical_set
            "#{setting.legacy} is deprecated for native Hive web and was ignored because " \
              "#{setting.canonical} is set; migrate to #{setting.canonical}. " \
              "The alias remains supported until the next major release."
          else
            "#{setting.legacy} is deprecated for native Hive web; migrate to " \
              "#{setting.canonical}. The alias remains supported until the next major release."
          end
          {
            "kind" => "deprecated_environment_alias",
            "alias" => setting.legacy,
            "replacement" => setting.canonical,
            "ignored" => canonical_set,
            "message" => message
          }
        end
      end

      def emit_warnings(environment: ENV, output: $stderr, prefix: "hive")
        current = warnings(environment: environment)
        current.each { |warning| output.puts "#{prefix}: warning: #{warning.fetch('message')}" }
        current
      end

      def legacy_names
        SETTINGS.map(&:legacy)
      end

      def resolved_for_service(config:, environment: ENV, managed_app_dir:)
        origin_default = config["origin"].to_s.strip
        origin_default = "http://#{config.fetch('bind')}:#{config.fetch('port')}" if origin_default.empty?
        {
          "HIVE_WEB_APP_DIR" => value(
            "HIVE_WEB_APP_DIR", environment: environment, default: managed_app_dir
          ),
          "HIVE_WEB_ORIGIN" => value(
            "HIVE_WEB_ORIGIN", environment: environment, default: origin_default
          ),
          "HIVE_WEB_STORAGE_DIR" => value(
            "HIVE_WEB_STORAGE_DIR", environment: environment
          ),
          "HIVE_WEB_LOCAL_LOOPBACK" => boolean(
            "HIVE_WEB_LOCAL_LOOPBACK",
            environment: environment,
            default: config.fetch("local_loopback", true)
          ) ? "1" : "0",
          "HIVE_WEB_DIFF_TIMEOUT_SEC" => value(
            "HIVE_WEB_DIFF_TIMEOUT_SEC", environment: environment
          ).to_s,
          "HIVE_WEB_CLONE_TIMEOUT_SEC" => value(
            "HIVE_WEB_CLONE_TIMEOUT_SEC", environment: environment
          ).to_s
        }.freeze
      end

      def setting!(canonical)
        SETTINGS_BY_NAME.fetch(canonical) do
          raise ArgumentError, "unknown Hive web environment setting #{canonical.inspect}"
        end
      end
      private_class_method :setting!

      def present_value(value)
        value unless value.to_s.strip.empty?
      end
      private_class_method :present_value
    end
  end
end
