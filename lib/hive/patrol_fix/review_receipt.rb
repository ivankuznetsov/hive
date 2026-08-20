require "json"
require "hive/patrol_fix"

module Hive
  module PatrolFix
    # Strict model-output value for the independent Patrol Fix review gate.
    # Controller identity, evidence, diff, validation and HEAD are deliberately
    # absent: Review resolves and binds those values after parsing this report.
    class ReviewReceipt
      SCHEMA = "hive-patrol-fix-review-report".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = 32 * 1024
      MAX_TEXT_BYTES = 16 * 1024
      MAX_EVIDENCE = 64
      ROUTES = %w[publish rework escalate reject blocked].freeze
      FIELDS = %w[schema schema_version route rationale evidence blocker_owner].freeze

      class InvalidReport < Hive::Error; end

      attr_reader :route, :rationale, :evidence, :blocker_owner

      def self.read(path, allowed_routes: ROUTES)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        source = File.open(path, flags) do |file|
          stat = file.stat
          raise InvalidReport, "review report must be a regular file" unless stat.file? && stat.nlink == 1
          raise InvalidReport, "review report exceeds #{MAX_BYTES} bytes" if stat.size > MAX_BYTES

          file.read(MAX_BYTES + 1)
        end
        parse(source, allowed_routes: allowed_routes)
      rescue Errno::ENOENT
        raise InvalidReport, "review report is missing"
      rescue Errno::ELOOP
        raise InvalidReport, "review report must not be a symlink"
      rescue SystemCallError, IOError => e
        raise InvalidReport, "review report is unreadable: #{e.class}: #{e.message}"
      end

      def self.parse(source, allowed_routes: ROUTES)
        allowed = Array(allowed_routes).map(&:to_s)
        unless !allowed.empty? && (allowed - ROUTES).empty? && allowed.uniq == allowed
          raise InvalidReport, "controller allowed routes are invalid"
        end
        bytes = source.to_s
        raise InvalidReport, "review report exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
        bytes = bytes.dup.force_encoding(Encoding::UTF_8)
        raise InvalidReport, "review report must be valid UTF-8" unless bytes.valid_encoding?

        document = JSON.parse(bytes)
        raise InvalidReport, "review report must be an object" unless document.is_a?(Hash)
        unless document.keys.sort == FIELDS.sort
          raise InvalidReport, "review report fields must be exactly #{FIELDS.join(', ')}"
        end
        raise InvalidReport, "unknown review report schema" unless document["schema"] == SCHEMA
        raise InvalidReport, "unknown review report schema version" unless document["schema_version"] == SCHEMA_VERSION
        route = bounded_string!(document["route"], "route", 32)
        raise InvalidReport, "review report route is not controller-allowed" unless allowed.include?(route)
        rationale = bounded_string!(document["rationale"], "rationale", MAX_TEXT_BYTES)
        blocker = bounded_string!(document["blocker_owner"], "blocker_owner", 128)
        evidence = document["evidence"]
        unless evidence.is_a?(Array) && evidence.length.between?(1, MAX_EVIDENCE)
          raise InvalidReport, "review report evidence must contain 1..#{MAX_EVIDENCE} entries"
        end
        evidence = evidence.map.with_index do |entry, index|
          bounded_string!(entry, "evidence[#{index}]", MAX_TEXT_BYTES)
        end
        new(route: route, rationale: rationale, evidence: evidence, blocker_owner: blocker)
      rescue JSON::ParserError => e
        raise InvalidReport, "review report is malformed JSON: #{e.message}"
      end

      def self.bounded_string!(value, label, max)
        unless value.is_a?(String) && !value.empty?
          raise InvalidReport, "review report #{label} must be a non-empty string"
        end
        raise InvalidReport, "review report #{label} exceeds #{max} bytes" if value.bytesize > max
        if value.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidReport, "review report #{label} contains control characters"
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
    end
  end
end
