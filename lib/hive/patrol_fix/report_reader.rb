require "json"

module Hive
  module PatrolFix
    # Shared strict reader for the small JSON documents emitted by Patrol Fix
    # agents. The schema and allowed routes remain owned by each report type;
    # byte, encoding, field, and text validation live here once.
    module ReportReader
      MAX_BYTES = 32 * 1024
      MAX_TEXT_BYTES = 16 * 1024
      MAX_EVIDENCE = 64
      FIELDS = %w[schema schema_version route rationale evidence blocker_owner].freeze

      module_function

      def read(path, label:, error_class:, schema:, schema_version:, routes:, known_routes:)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        source = File.open(path, flags) do |file|
          stat = file.stat
          fail!(error_class, "#{label} must be a regular file") unless stat.file? && stat.nlink == 1
          fail!(error_class, "#{label} exceeds #{MAX_BYTES} bytes") if stat.size > MAX_BYTES

          file.read(MAX_BYTES + 1)
        end
        parse(
          source,
          label: label, error_class: error_class, schema: schema,
          schema_version: schema_version, routes: routes, known_routes: known_routes
        )
      rescue Errno::ENOENT
        fail!(error_class, "#{label} is missing")
      rescue Errno::ELOOP
        fail!(error_class, "#{label} must not be a symlink")
      rescue SystemCallError, IOError => e
        fail!(error_class, "#{label} is unreadable: #{e.class}: #{e.message}")
      end

      def parse(source, label:, error_class:, schema:, schema_version:, routes:, known_routes:)
        allowed_routes = normalize_routes!(routes, known_routes, error_class)
        bytes = source.to_s
        fail!(error_class, "#{label} exceeds #{MAX_BYTES} bytes") if bytes.bytesize > MAX_BYTES
        bytes = bytes.dup.force_encoding(Encoding::UTF_8)
        fail!(error_class, "#{label} must be valid UTF-8") unless bytes.valid_encoding?

        document = JSON.parse(bytes)
        fail!(error_class, "#{label} must be an object") unless document.is_a?(Hash)
        unless document.keys.sort == FIELDS.sort
          fail!(error_class, "#{label} fields must be exactly #{FIELDS.join(', ')}")
        end
        fail!(error_class, "unknown #{label} schema") unless document["schema"] == schema
        unless document["schema_version"] == schema_version
          fail!(error_class, "unknown #{label} schema version")
        end

        route = bounded_string!(document["route"], "#{label} route", 32, error_class)
        unless allowed_routes.include?(route)
          fail!(error_class, "#{label} route is not controller-allowed")
        end
        rationale = bounded_string!(document["rationale"], "#{label} rationale", MAX_TEXT_BYTES, error_class)
        blocker = bounded_string!(document["blocker_owner"], "#{label} blocker_owner", 128, error_class)
        evidence = document["evidence"]
        unless evidence.is_a?(Array) && evidence.length.between?(1, MAX_EVIDENCE)
          fail!(error_class, "#{label} evidence must contain 1..#{MAX_EVIDENCE} entries")
        end
        evidence = evidence.map.with_index do |entry, index|
          bounded_string!(entry, "#{label} evidence[#{index}]", MAX_TEXT_BYTES, error_class)
        end
        {
          route: route, rationale: rationale, evidence: evidence.freeze,
          blocker_owner: blocker
        }.freeze
      rescue JSON::ParserError => e
        fail!(error_class, "#{label} is malformed JSON: #{e.message}")
      end

      def normalize_routes!(routes, known_routes, error_class)
        allowed = Array(routes).map(&:to_s)
        known = Array(known_routes).map(&:to_s)
        unless !allowed.empty? && allowed.uniq == allowed && (allowed - known).empty?
          fail!(error_class, "controller allowed routes are invalid")
        end

        allowed.freeze
      end

      def bounded_string!(value, label, max, error_class)
        unless value.is_a?(String) && !value.empty?
          fail!(error_class, "#{label} must be a non-empty string")
        end
        fail!(error_class, "#{label} exceeds #{max} bytes") if value.bytesize > max
        if value.match?(/[\u0000-\u001f\u007f]/)
          fail!(error_class, "#{label} contains control characters")
        end
        value.dup.freeze
      end

      def fail!(error_class, message)
        raise error_class, message
      end
    end
  end
end
