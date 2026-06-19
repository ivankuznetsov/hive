require "hive/config"

module Hive
  module VisualArtifactsReadiness
    CAPTURE_TOOLS = %w[ffmpeg asciinema].freeze

    module_function

    def capture_tooling_status(path_env: ENV["PATH"])
      tools = CAPTURE_TOOLS.to_h do |name|
        path = which(name, path_env: path_env)
        [ name.to_sym, { present: !path.nil?, path: path } ]
      end
      missing = CAPTURE_TOOLS.reject { |name| tools.fetch(name.to_sym).fetch(:present) }

      tools.merge(
        missing: missing,
        satisfied: missing.empty?
      )
    end

    def screenote_connected?
      screenote_status.fetch(:connected)
    end

    def screenote_status
      cfg = Hive::Config.load_global_screenote
      connected = present_string?(cfg["base_url"]) && present_string?(cfg["api_token"])
      {
        connected: connected,
        base_url: cfg["base_url"],
        reason: connected ? nil : "screenote.base_url and screenote.api_token are not both configured"
      }
    rescue Hive::ConfigError => e
      {
        connected: false,
        base_url: nil,
        reason: e.message
      }
    end

    def which(name, path_env:)
      path_env.to_s.split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end
    private_class_method :which

    def present_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end
    private_class_method :present_string?
  end
end
