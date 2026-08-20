require "json"
require "hive/patrol_fix"

module Hive
  module PatrolFix
    class InboxReport
      SCHEMA = "hive-patrol-fix-inbox-report".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = 32 * 1024
      MAX_TEXT_BYTES = 16 * 1024
      MAX_EVIDENCE = 64
      ROUTES = %w[fix escalate reject blocked].freeze
      FIELDS = %w[schema schema_version route rationale evidence blocker_owner].freeze

      class InvalidReport < Hive::Error; end

      attr_reader :route, :rationale, :evidence, :blocker_owner

      def self.read(path)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        source = File.open(path, flags) do |file|
          stat = file.stat
          raise InvalidReport, "inbox report must be a regular file" unless stat.file? && stat.nlink == 1
          raise InvalidReport, "inbox report exceeds #{MAX_BYTES} bytes" if stat.size > MAX_BYTES

          file.read(MAX_BYTES + 1)
        end
        parse(source)
      rescue Errno::ENOENT
        raise InvalidReport, "inbox report is missing"
      rescue Errno::ELOOP
        raise InvalidReport, "inbox report must not be a symlink"
      rescue SystemCallError, IOError => e
        raise InvalidReport, "inbox report is unreadable: #{e.class}: #{e.message}"
      end

      def self.parse(source)
        bytes = source.to_s
        raise InvalidReport, "inbox report exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
        bytes = bytes.dup.force_encoding(Encoding::UTF_8)
        raise InvalidReport, "inbox report must be valid UTF-8" unless bytes.valid_encoding?

        document = JSON.parse(bytes)
        raise InvalidReport, "inbox report must be an object" unless document.is_a?(Hash)
        unless document.keys.sort == FIELDS.sort
          raise InvalidReport, "inbox report fields must be exactly #{FIELDS.join(', ')}"
        end
        raise InvalidReport, "unknown inbox report schema" unless document["schema"] == SCHEMA
        raise InvalidReport, "unknown inbox report schema version" unless document["schema_version"] == SCHEMA_VERSION
        route = bounded_string!(document["route"], "route", 32)
        raise InvalidReport, "inbox report route is invalid" unless ROUTES.include?(route)
        rationale = bounded_string!(document["rationale"], "rationale", MAX_TEXT_BYTES)
        blocker = bounded_string!(document["blocker_owner"], "blocker_owner", 128)
        evidence = document["evidence"]
        unless evidence.is_a?(Array) && evidence.length.between?(1, MAX_EVIDENCE)
          raise InvalidReport, "inbox report evidence must contain 1..#{MAX_EVIDENCE} entries"
        end
        evidence = evidence.map.with_index do |entry, index|
          bounded_string!(entry, "evidence[#{index}]", MAX_TEXT_BYTES)
        end
        new(route: route, rationale: rationale, evidence: evidence, blocker_owner: blocker)
      rescue JSON::ParserError => e
        raise InvalidReport, "inbox report is malformed JSON: #{e.message}"
      end

      def self.bounded_string!(value, label, max)
        unless value.is_a?(String) && !value.empty?
          raise InvalidReport, "inbox report #{label} must be a non-empty string"
        end
        raise InvalidReport, "inbox report #{label} exceeds #{max} bytes" if value.bytesize > max
        if value.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidReport, "inbox report #{label} contains control characters"
        end
        value.dup.freeze
      end
      private_class_method :bounded_string!

      def initialize(route:, rationale:, evidence:, blocker_owner:)
        @route = route.freeze
        @rationale = rationale.freeze
        @evidence = evidence.dup.freeze
        @blocker_owner = blocker_owner.freeze
        freeze
      end

      def to_h
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "route" => route, "rationale" => rationale,
          "evidence" => evidence, "blocker_owner" => blocker_owner
        }
      end
    end
  end
end
