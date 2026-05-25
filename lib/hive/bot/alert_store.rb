require "json"
require "fileutils"
require "time"

module Hive
  module Bot
    class AlertStore
      SCHEMA_VERSION = 1

      Entry = Data.define(:first_seen_at, :reminded_at, :row)
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

      def add(fingerprint, row, now)
        synchronize do
          entries[fingerprint] = {
            "first_seen_at" => timestamp(now),
            "reminded_at" => nil,
            "row" => serialize_row(row)
          }
          persist_locked!
        end
      end

      def mark_reminded(fingerprint, now)
        synchronize do
          entry = entries[fingerprint]
          next unless entry

          entry["reminded_at"] = timestamp(now)
          persist_locked!
        end
      end

      def remove(fingerprint)
        synchronize do
          entry = entries.delete(fingerprint)
          persist_locked! if entry
          entry ? row_from_raw(entry["row"]) : nil
        end
      end

      def remove_matching(project:, slug:, stage: nil)
        synchronize do
          before = entries.size
          entries.delete_if do |_fingerprint, raw|
            row = row_from_raw(raw.is_a?(Hash) ? raw["row"] : nil)
            row.project.to_s == project.to_s &&
              row.slug.to_s == slug.to_s &&
              (stage.nil? || row.stage.to_s == stage.to_s)
          end
          removed = before - entries.size
          persist_locked! if removed.positive?
          removed
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
          row: row_from_raw(raw["row"])
        )
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
