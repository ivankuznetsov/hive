require "digest"
require "hive/patrol_fix"

module Hive
  module PatrolFix
    module Migration
      # Drains source-owned, snapshot-stable pages into one source-neutral
      # preflight inventory. Ports own all Patrol-specific parsing and storage;
      # this component only validates their immutable observations.
      class Inventory
        CANDIDATE_KEYS = %w[
          source_kind source_id source_schema canonical_digest authority_state
          semantic_root observations blocking_reason
        ].freeze
        OPAQUE_KEYS = %w[source_id canonical_digest byte_size].freeze
        AUTHORITY_STATES = %w[accepted claimed blocked].freeze
        DIGEST = /\A[0-9a-f]{64}\z/
        MAX_CANDIDATES = 16_384
        MAX_OPAQUE = 16_384
        MAX_PAGES = 16_384
        MAX_PAGE_ENTRIES = 4_096
        MAX_OBSERVATIONS_PER_CANDIDATE = 4_096
        MAX_OPAQUE_ENTRY_BYTES = 64 * 1024 * 1024

        class InvalidInventory < Hive::Error; end

        def initialize(source_ports:, page_size: 128)
          @source_ports = Array(source_ports)
          @page_size = Integer(page_size)
          invalid!("migration inventory requires at least one source port") if
            @source_ports.empty?
          invalid!("migration inventory page size is invalid") unless
            @page_size.between?(1, 512)
        rescue ArgumentError, TypeError
          raise InvalidInventory, "migration inventory page size is invalid"
        end

        def capture
          candidates = @source_ports.flat_map { |port| drain(port) }
          candidates.sort_by! { |entry| source_ref(entry) }
          invalid!("migration inventory exceeds the bounded limit") if
            candidates.length > MAX_CANDIDATES
          refs = candidates.map { |entry| source_ref(entry) }
          invalid!("migration inventory repeats a source identity") unless
            refs.uniq.length == refs.length

          opaque = @source_ports.flat_map do |port|
            port.respond_to?(:opaque_v3_entries) ? Array(port.opaque_v3_entries) : []
          end.map { |entry| validate_opaque(entry) }
          opaque.sort_by! { |entry| entry.fetch("source_id") }
          invalid!("opaque v3 inventory exceeds the bounded limit") if opaque.length > MAX_OPAQUE
          invalid!("opaque v3 inventory repeats a source identity") unless
            opaque.map { |entry| entry.fetch("source_id") }.uniq.length == opaque.length

          result = {
            "candidates" => candidates,
            "count" => candidates.length,
            "root_digest" => inventory_root(candidates),
            "opaque_v3" => {
              "count" => opaque.length,
              "root_digest" => Digest::SHA256.hexdigest(PatrolFix.canonical_json(opaque)),
              "entries" => opaque
            }
          }
          PatrolFix.deep_freeze(result)
        end

        private

        def drain(port)
          cursor = nil
          snapshot_token = nil
          seen_cursors = {}
          entries = []
          pages = 0
          loop do
            page = port.migration_page(limit: @page_size, cursor: cursor)
            validate_page!(page)
            token = page.fetch("snapshot_token")
            snapshot_token ||= token
            invalid!("migration source changed between cursor pages") unless token == snapshot_token
            entries.concat(page.fetch("entries").map { |entry| validate_candidate(entry) })
            invalid!("migration inventory exceeds the bounded limit") if entries.length > MAX_CANDIDATES
            next_cursor = page.fetch("next_cursor")
            break unless next_cursor

            invalid!("migration inventory cursor repeated") if seen_cursors[next_cursor]
            seen_cursors[next_cursor] = true
            cursor = next_cursor
            pages += 1
            invalid!("migration inventory has too many pages") if pages > MAX_PAGES
          end
          entries
        rescue KeyError, NoMethodError => error
          invalid!("migration source port returned an invalid page: #{error.message}")
        end

        def validate_page!(page)
          valid = page.is_a?(Hash) &&
            page.keys.sort == %w[entries next_cursor snapshot_token] &&
            page["entries"].is_a?(Array) &&
            page["entries"].length <= MAX_PAGE_ENTRIES &&
            page["snapshot_token"].is_a?(String) &&
            page["snapshot_token"].match?(DIGEST) &&
            (page["next_cursor"].nil? ||
             (page["next_cursor"].is_a?(String) && !page["next_cursor"].empty?))
          invalid!("migration source port returned an invalid page") unless valid
        end

        def validate_candidate(entry)
          unless entry.is_a?(Hash) && entry.keys.sort == CANDIDATE_KEYS.sort
            invalid!("migration source candidate fields are invalid")
          end
          %w[source_kind source_id source_schema].each do |key|
            text!(entry.fetch(key), "migration source #{key}")
          end
          digest!(entry.fetch("canonical_digest"), "migration source digest")
          invalid!("migration source authority state is invalid") unless
            AUTHORITY_STATES.include?(entry.fetch("authority_state"))
          root = entry.fetch("semantic_root")
          text!(root, "migration semantic root") if root
          observations = entry.fetch("observations")
          invalid!("migration source observations are invalid") unless
            observations.is_a?(Array) &&
            observations.length <= MAX_OBSERVATIONS_PER_CANDIDATE
          reason = entry.fetch("blocking_reason")
          text!(reason, "migration blocking reason") if reason
          if entry.fetch("authority_state") == "blocked" && reason.nil?
            invalid!("a blocked migration source requires a reason")
          end
          PatrolFix.deep_freeze(PatrolFix.deep_copy(entry))
        end

        def validate_opaque(entry)
          unless entry.is_a?(Hash) && entry.keys.sort == OPAQUE_KEYS.sort
            invalid!("opaque v3 inventory fields are invalid")
          end
          text!(entry.fetch("source_id"), "opaque v3 source identity")
          digest!(entry.fetch("canonical_digest"), "opaque v3 source digest")
          invalid!("opaque v3 byte size is invalid") unless
            entry.fetch("byte_size").is_a?(Integer) &&
            entry.fetch("byte_size").between?(0, MAX_OPAQUE_ENTRY_BYTES)
          PatrolFix.deep_freeze(PatrolFix.deep_copy(entry))
        end

        def inventory_root(candidates)
          projection = candidates.map do |entry|
            entry.slice("source_kind", "source_id", "source_schema", "canonical_digest")
          end.sort_by { |entry| [ entry.fetch("source_kind"), entry.fetch("source_id") ] }
          Digest::SHA256.hexdigest(PatrolFix.canonical_json(projection))
        end

        def source_ref(entry)
          "#{entry.fetch('source_kind')}:#{entry.fetch('source_id')}"
        end

        def text!(value, label)
          invalid!("#{label} is invalid") unless
            value.is_a?(String) && !value.empty? && value.bytesize <= 4_096 &&
            !value.match?(/[\u0000-\u001f\u007f]/)
        end

        def digest!(value, label)
          invalid!("#{label} is invalid") unless value.is_a?(String) && value.match?(DIGEST)
        end

        def invalid!(message)
          raise InvalidInventory, message.to_s[0, 512]
        end
      end
    end
  end
end
