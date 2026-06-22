require "fileutils"
require "json"
require "time"
require "hive"
require "hive/paths"

module Hive
  module Screenote
    class CredentialStore
      FILENAME = "screenote.json".freeze

      attr_reader :path

      def self.default_path
        File.join(Hive::Paths.config_home, FILENAME)
      end

      def initialize(path: self.class.default_path)
        @path = path
      end

      def load
        return nil unless File.exist?(path)

        data = JSON.parse(File.read(path))
        unless data.is_a?(Hash)
          raise Hive::ConfigError,
                "screenote credential file at #{path} must contain a JSON object"
        end

        data
      rescue JSON::ParserError => e
        raise Hive::ConfigError,
              "screenote credential file at #{path} is invalid JSON: #{e.message}"
      end

      def save(credentials)
        unless credentials.is_a?(Hash)
          raise Hive::ConfigError, "screenote credentials must be a Hash"
        end

        data = JSON.parse(JSON.generate(stringify_keys(credentials)))
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(data)}\n", mode: "w", perm: 0o600)
        File.chmod(0o600, path)
        data
      end

      def clear
        FileUtils.rm_f(path)
      end

      def present?
        File.file?(path)
      end

      def expired?(credentials = load, now: Time.now)
        return true unless credentials.is_a?(Hash)

        expires_at = credentials["expires_at"].to_s.strip
        return true if expires_at.empty?

        Time.parse(expires_at) <= now
      rescue ArgumentError
        true
      end

      private

      def stringify_keys(value)
        case value
        when Hash
          value.to_h { |key, child| [ key.to_s, stringify_keys(child) ] }
        when Array
          value.map { |child| stringify_keys(child) }
        else
          value
        end
      end
    end
  end
end
