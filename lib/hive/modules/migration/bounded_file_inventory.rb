require "base64"
require "digest"
require "json"
require "hive/errors"

module Hive
  module Modules
    module Migration
      # Filesystem-order-independent inventory with constant-sized snapshots
      # and O(page-size) selection. A cursor freezes a lexicographic high-water
      # mark so restarts neither skip nor duplicate names that belonged to the
      # original bounded inventory.
      class BoundedFileInventory
        Snapshot = Data.define(:count, :through, :fingerprint, :binding)
        Page = Data.define(:names, :next_cursor)
        CURSOR_KEYS = %w[
          after binding count fingerprint through version
        ].freeze
        CURSOR_VERSION = 1
        MAX_CURSOR_BYTES = 2_048
        FINGERPRINT_MASK = (1 << 256) - 1

        def initialize(directory:, relative:, filename_pattern:, max_entries:,
                       cursor_prefix:, malformed_message:, overflow_message:,
                       missing: false)
          @directory = directory
          @relative = relative.to_s
          @filename_pattern = filename_pattern
          @cursor_prefix = cursor_prefix.to_s
          @malformed_message = malformed_message.to_s
          @overflow_message = overflow_message.to_s
          @max_entries = Integer(max_entries)
          @missing = missing
          malformed! unless @max_entries.positive? &&
                            @cursor_prefix.match?(/\A[a-z0-9-]+\z/)
          @binding = ::Digest::SHA256.hexdigest(
            "#{@cursor_prefix}\0#{@directory.root}\0#{@relative}"
          ).freeze
        rescue ArgumentError, TypeError
          malformed!
        end

        def snapshot
          count = 0
          through = nil
          fingerprint = 0
          each_valid_name do |name|
            count += 1
            overflow! if count > @max_entries
            through = name if through.nil? || name > through
            fingerprint = fingerprint_add(fingerprint, name)
          end
          Snapshot.new(
            count: count,
            through: through,
            fingerprint: fingerprint_hex(fingerprint),
            binding: @binding
          ).freeze
        end

        def page(limit:, cursor: nil, snapshot: nil)
          limit = Integer(limit)
          malformed! unless limit.positive? && limit <= @max_entries
          malformed! if cursor && snapshot
          state, after = cursor ? decode_cursor(cursor) :
            [ validate_snapshot(snapshot || self.snapshot), nil ]
          selected = []
          visited = 0
          observed = 0
          fingerprint = 0
          each_valid_name do |name|
            visited += 1
            overflow! if visited > @max_entries
            next unless state.through && name <= state.through

            observed += 1
            fingerprint = fingerprint_add(fingerprint, name)
            next if after && name <= after

            insert_bounded(selected, name, limit + 1)
          end
          malformed! unless observed == state.count &&
                            fingerprint_hex(fingerprint) == state.fingerprint
          return Page.new(names: selected.freeze, next_cursor: nil).freeze if selected.size <= limit

          names = selected.first(limit).freeze
          Page.new(
            names: names,
            next_cursor: encode_cursor(state, names.last)
          ).freeze
        rescue Hive::ConfigError
          raise
        rescue ArgumentError, TypeError, JSON::ParserError, EncodingError
          malformed!
        end

        def each_name(page_size:, snapshot: nil)
          return enum_for(__method__, page_size: page_size, snapshot: snapshot) unless block_given?

          state = validate_snapshot(snapshot || self.snapshot)
          cursor = nil
          loop do
            page = page(limit: page_size, cursor: cursor, snapshot: cursor ? nil : state)
            page.names.each { |name| yield name }
            cursor = page.next_cursor
            break unless cursor
          end
          nil
        end

        private

        def each_valid_name
          @directory.each_child(@relative, missing: @missing) do |name|
            malformed! unless name.is_a?(String) &&
                              @filename_pattern.match?(name)
            yield name
          end
        rescue Hive::ConfigError => error
          raise if [ @malformed_message, @overflow_message ].include?(error.message)

          malformed!
        end

        def insert_bounded(selected, name, capacity)
          index = selected.bsearch_index { |candidate| candidate > name } ||
                  selected.length
          selected.insert(index, name)
          selected.pop if selected.length > capacity
        end

        def validate_snapshot(value)
          malformed! unless value.is_a?(Snapshot) &&
                            value.binding == @binding &&
                            value.count.is_a?(Integer) &&
                            value.count.between?(0, @max_entries) &&
                            valid_boundary?(value.through) &&
                            value.fingerprint.to_s.match?(/\A[0-9a-f]{64}\z/) &&
                            (value.count.zero? == value.through.nil?)
          value
        end

        def valid_boundary?(value)
          value.nil? ||
            (value.is_a?(String) && @filename_pattern.match?(value))
        end

        def encode_cursor(snapshot, after)
          payload = {
            "after" => after,
            "binding" => snapshot.binding,
            "count" => snapshot.count,
            "fingerprint" => snapshot.fingerprint,
            "through" => snapshot.through,
            "version" => CURSOR_VERSION
          }
          encoded = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
          "#{@cursor_prefix}.#{encoded}"
        end

        def decode_cursor(value)
          malformed! unless value.is_a?(String) &&
                            value.bytesize <= MAX_CURSOR_BYTES
          prefix, encoded = value.split(".", 2)
          malformed! unless prefix == @cursor_prefix && encoded && !encoded.empty?
          payload = JSON.parse(Base64.urlsafe_decode64(encoded))
          malformed! unless payload.is_a?(Hash) &&
                            payload.keys.sort == CURSOR_KEYS &&
                            payload["version"] == CURSOR_VERSION &&
                            valid_boundary?(payload["after"])
          snapshot = validate_snapshot(
            Snapshot.new(
              count: payload["count"],
              through: payload["through"],
              fingerprint: payload["fingerprint"],
              binding: payload["binding"]
            )
          )
          after = payload["after"]
          malformed! if after.nil? || snapshot.through.nil? ||
                        after >= snapshot.through
          [ snapshot, after ]
        end

        def fingerprint_add(fingerprint, name)
          (fingerprint + ::Digest::SHA256.hexdigest(name).to_i(16)) &
            FINGERPRINT_MASK
        end

        def fingerprint_hex(fingerprint)
          format("%064x", fingerprint)
        end

        def malformed!
          raise Hive::ConfigError, @malformed_message
        end

        def overflow!
          raise Hive::ConfigError, @overflow_message
        end
      end
    end
  end
end
