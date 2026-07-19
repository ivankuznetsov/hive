require "fileutils"
require "json"
require "time"
require "hive"
require "hive/paths"
require "hive/screenote/secure_file"
require "hive/stringify_keys"

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

        data = JSON.parse(JSON.generate(Hive::StringifyKeys.call(credentials)))
        Hive::Screenote::SecureFile.write_json(path, data)
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
    end
  end
end
