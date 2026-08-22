require "json"
require "hive/patrol_fix"

module Hive
  module PatrolFix
    class FixReport
      SCHEMA = "hive-patrol-fix-fix-report".freeze
      MAX_BYTES = 32 * 1024
      MAX_COMMANDS = 16
      FIELDS = %w[schema schema_version status summary validation_commands].freeze
      class InvalidReport < Hive::Error; end
      attr_reader :status, :summary, :validation_commands

      def self.read(path)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        bytes = File.open(path, flags) do |file|
          stat = file.stat
          raise InvalidReport, "fix report must be a regular file" unless stat.file? && stat.nlink == 1
          raise InvalidReport, "fix report exceeds #{MAX_BYTES} bytes" if stat.size > MAX_BYTES
          file.read(MAX_BYTES + 1)
        end
        parse(bytes)
      rescue Errno::ENOENT then raise InvalidReport, "fix report is missing"
      rescue Errno::ELOOP then raise InvalidReport, "fix report must not be a symlink"
      rescue SystemCallError, IOError => e
        raise InvalidReport, "fix report is unreadable: #{e.class}: #{e.message}"
      end

      def self.parse(source)
        bytes = source.to_s
        raise InvalidReport, "fix report exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
        bytes = bytes.dup.force_encoding(Encoding::UTF_8)
        raise InvalidReport, "fix report must be valid UTF-8" unless bytes.valid_encoding?
        document = JSON.parse(bytes)
        unless document.is_a?(Hash) && document.keys.sort == FIELDS.sort
          raise InvalidReport, "fix report has an invalid field set"
        end
        raise InvalidReport, "unknown fix report schema" unless document["schema"] == SCHEMA && document["schema_version"] == 1
        status = document["status"]
        raise InvalidReport, "fix report status must be fixed or blocked" unless %w[fixed blocked].include?(status)
        summary = string!(document["summary"], "summary", 16_384)
        commands = document["validation_commands"]
        unless commands.is_a?(Array) && commands.length <= MAX_COMMANDS
          raise InvalidReport, "validation_commands must be a bounded array"
        end
        normalized = commands.map.with_index do |command, index|
          unless command.is_a?(Hash) && command.keys.sort == %w[command identity]
            raise InvalidReport, "validation_commands[#{index}] has an invalid field set"
          end
          { "identity" => string!(command["identity"], "identity", 128),
            "command" => string!(command["command"], "command", 4_096) }.freeze
        end
        new(status: status, summary: summary, validation_commands: normalized)
      rescue JSON::ParserError => e
        raise InvalidReport, "fix report is malformed JSON: #{e.message}"
      end

      def self.string!(value, label, max)
        unless value.is_a?(String) && value.bytesize.between?(1, max) &&
               !value.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidReport, "fix report #{label} is invalid"
        end
        value.dup.freeze
      end
      private_class_method :string!

      def initialize(status:, summary:, validation_commands:)
        @status, @summary = status.freeze, summary.freeze
        @validation_commands = validation_commands.dup.freeze
        freeze
      end

      def to_h
        { "schema" => SCHEMA, "schema_version" => 1, "status" => status,
          "summary" => summary, "validation_commands" => validation_commands }
      end
    end
  end
end
