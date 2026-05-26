require "json"
require "fileutils"
require "time"

module Hive
  module Bot
    class AlertStore
      SCHEMA_VERSION = 1

      Entry = Data.define(:first_seen_at, :reminded_at, :delivered_to,
                          :consecutive_failures, :next_attempt_after, :absent_since, :row)
      RowSnapshot = Data.define(:project, :slug, :stage, :marker, :attrs, :action) do
        def initialize(project:, slug:, stage:, marker:, attrs: {}, action: nil)
          super
        end
      end

      def initialize(path:, logger: nil)
        @path = path ? File.expand_path(path) : nil
        @logger = logger
        @mutex = Mutex.new
        @data = empty_data
        load!
      end

      def each_fingerprint
        return enum_for(:each_fingerprint) unless block_given?

        synchronize { entries.keys }.each { |fingerprint| yield fingerprint }
      end

      def add(fingerprint, row, now, delivered_to: [])
        synchronize do
          with_rollback do
            entries[fingerprint] = {
              "first_seen_at" => timestamp(now),
              "reminded_at" => nil,
              "delivered_to" => normalize_chat_ids(delivered_to),
              "consecutive_failures" => 0,
              "next_attempt_after" => nil,
              "absent_since" => nil,
              "row" => serialize_row(row)
            }
            persist_locked!
          end
        end
      end

      def mark_absent(fingerprint, now)
        synchronize do
          entry = entries[fingerprint]
          return false unless entry
          return false if entry["absent_since"]

          with_rollback do
            entry["absent_since"] = timestamp(now)
            persist_locked!
          end
          true
        end
      end

      def mark_present(fingerprint)
        synchronize do
          entry = entries[fingerprint]
          return false unless entry
          return false if entry["absent_since"].nil?

          with_rollback do
            entry["absent_since"] = nil
            persist_locked!
          end
          true
        end
      end

      def record_delivery(fingerprint, chat_ids)
        synchronize do
          entry = entries[fingerprint]
          return false unless entry

          existing = Array(entry["delivered_to"]).map(&:to_s)
          additions = normalize_chat_ids(chat_ids) - existing
          return false if additions.empty?

          with_rollback do
            entry["delivered_to"] = existing + additions
            entry["consecutive_failures"] = 0
            entry["next_attempt_after"] = nil
            persist_locked!
          end
          true
        end
      end

      def record_send_failure(fingerprint, now, backoff_for: nil)
        synchronize do
          entry = entries[fingerprint]
          return false unless entry

          failures = entry["consecutive_failures"].to_i + 1
          delay = backoff_for || backoff_seconds(failures)
          with_rollback do
            entry["consecutive_failures"] = failures
            entry["next_attempt_after"] = timestamp(now + delay)
            persist_locked!
          end
          true
        end
      end

      def record_send_success(fingerprint)
        synchronize do
          entry = entries[fingerprint]
          return false unless entry
          return false if entry["consecutive_failures"].to_i.zero? && entry["next_attempt_after"].nil?

          with_rollback do
            entry["consecutive_failures"] = 0
            entry["next_attempt_after"] = nil
            persist_locked!
          end
          true
        end
      end

      private

      def with_rollback
        snapshot = Marshal.load(Marshal.dump(@data))
        yield
      rescue StandardError
        @data = snapshot
        raise
      end

      public

      def mark_reminded(fingerprint, now)
        synchronize do
          entry = entries[fingerprint]
          next unless entry

          with_rollback do
            entry["reminded_at"] = timestamp(now)
            persist_locked!
          end
        end
      end

      def remove(fingerprint)
        synchronize do
          entry = entries[fingerprint]
          next nil unless entry

          with_rollback do
            entries.delete(fingerprint)
            persist_locked!
          end
          row_from_raw(entry["row"])
        end
      end

      def remove_matching(project:, slug:, stage: nil, marker: nil, match_attr: nil)
        attr_key, attr_value = parse_match_attr(match_attr)
        synchronize do
          targets = entries.select do |_fingerprint, raw|
            row = row_from_raw(raw.is_a?(Hash) ? raw["row"] : nil)
            next false unless row.project.to_s == project.to_s
            next false unless row.slug.to_s == slug.to_s
            next false unless stage.nil? || row.stage.to_s == stage.to_s
            next false unless marker.nil? || marker.to_s.empty? || row.marker.to_s.casecmp(marker.to_s).zero?
            next false if attr_key && row.attrs.to_h.transform_keys(&:to_s)[attr_key].to_s != attr_value.to_s

            true
          end
          next 0 if targets.empty?

          with_rollback do
            targets.each_key { |fingerprint| entries.delete(fingerprint) }
            persist_locked!
          end
          targets.size
        end
      end

      def entry(fingerprint)
        synchronize do
          raw = entries[fingerprint]
          raw ? entry_from_raw(raw) : nil
        end
      end

      private

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def parse_match_attr(match_attr)
        return [ nil, nil ] if match_attr.nil? || match_attr.to_s.empty?

        key, value = match_attr.to_s.split("=", 2)
        return [ nil, nil ] if key.to_s.empty? || value.nil?

        [ key.to_s, value.to_s ]
      end

      def load!
        return unless @path && File.exist?(@path)

        raw = begin
          File.read(@path)
        rescue SystemCallError, IOError => e
          handle_corrupt!(e)
          return
        end

        parsed = JSON.parse(raw)
        unless parsed.is_a?(Hash) &&
               parsed["schema_version"] == SCHEMA_VERSION &&
               parsed["entries"].is_a?(Hash) &&
               parsed["entries"].all? { |fingerprint, entry| fingerprint.is_a?(String) && entry.is_a?(Hash) }
          raise JSON::ParserError, "invalid alert store schema"
        end

        @data = {
          "schema_version" => SCHEMA_VERSION,
          "entries" => parsed["entries"]
        }
      rescue JSON::ParserError, TypeError => e
        handle_corrupt!(e)
      end

      def handle_corrupt!(error)
        corrupt_path = corrupt_path_for(@path)
        begin
          File.rename(@path, corrupt_path) if @path && File.exist?(@path)
        rescue SystemCallError
          corrupt_path = nil
        end
        @logger&.event(:alert_store_corrupt, path: @path, corrupt_path: corrupt_path,
                                             error_class: error.class.name, message: error.message)
        @data = empty_data
      end

      def empty_data
        { "schema_version" => SCHEMA_VERSION, "entries" => {} }
      end

      def entries
        @data["entries"] ||= {}
      end

      def persist_locked!
        return unless @path

        FileUtils.mkdir_p(File.dirname(@path))
        tmp_path = File.join(File.dirname(@path), ".#{File.basename(@path)}.#{$$}.#{Thread.current.object_id}.tmp")
        File.open(tmp_path, "w") do |f|
          f.write(JSON.pretty_generate(@data))
          f.fsync
        end
        File.rename(tmp_path, @path)
        begin
          Dir.open(File.dirname(@path)) { |dir| dir.fsync }
        rescue StandardError
          nil
        end
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end

      def serialize_row(row)
        {
          "project" => row.project.to_s,
          "slug" => row.slug.to_s,
          "stage" => row.stage.to_s,
          "marker" => row.marker.to_s,
          "attrs" => row.attrs.to_h.transform_keys(&:to_s),
          "action" => row.action.to_s
        }
      end

      def entry_from_raw(raw)
        Entry.new(
          first_seen_at: parse_time(raw["first_seen_at"]),
          reminded_at: parse_time(raw["reminded_at"]),
          delivered_to: Array(raw["delivered_to"]).map(&:to_s),
          consecutive_failures: raw["consecutive_failures"].to_i,
          next_attempt_after: parse_time(raw["next_attempt_after"]),
          absent_since: parse_time(raw["absent_since"]),
          row: row_from_raw(raw["row"])
        )
      end

      def normalize_chat_ids(chat_ids)
        Array(chat_ids).map(&:to_s).uniq
      end

      BACKOFF_BASE_SEC = 60
      BACKOFF_MAX_SEC = 1800

      def backoff_seconds(failures)
        # 1=60, 2=120, 3=240, 4=480, 5=960, 6=1800, cap 1800
        exponent = [ failures - 1, 5 ].min
        delay = BACKOFF_BASE_SEC * (2**exponent)
        [ delay, BACKOFF_MAX_SEC ].min
      end

      def row_from_raw(raw)
        raw = raw.is_a?(Hash) ? raw : {}
        RowSnapshot.new(
          project: raw["project"],
          slug: raw["slug"],
          stage: raw["stage"],
          marker: raw["marker"],
          attrs: raw["attrs"].is_a?(Hash) ? raw["attrs"] : {},
          action: raw["action"]
        )
      end

      def timestamp(time)
        time.utc.iso8601
      end

      def parse_time(value)
        return nil if value.nil? || value.to_s.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def corrupt_path_for(path)
        "#{path}.corrupt-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}"
      end
    end
  end
end
