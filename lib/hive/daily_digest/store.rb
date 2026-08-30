require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/daily_digest/record"
require "hive/paths"

module Hive
  module DailyDigest
    # Owner-private versioned filesystem store. One sibling lock serializes
    # open replacement, close, amendments, and pruning across processes.
    class Store
      class Error < DailyDigest::Error; end
      class ImmutableRecord < Error; end
      class Conflict < Error; end
      class UnsafePath < Error; end

      attr_reader :root

      def initialize(root: Hive::Paths.daily_digest_root)
        @root = File.expand_path(root)
      end

      def write_base(record)
        prepared = Record.prepare(record)
        date = prepared.fetch("local_date")
        synchronize do
          raise PrunedRecord, "digest #{date} was pruned" if tombstone_exists?(date)

          existing = read_json(base_path(date)) if File.file?(base_path(date))
          if existing && existing.fetch("lifecycle") == "closed"
            return existing if existing.fetch("record_id") == prepared.fetch("record_id")

            raise ImmutableRecord, "closed digest #{date} is immutable"
          end
          if existing && prepared.fetch("lifecycle") == "open" &&
             existing.fetch("local_date") != prepared.fetch("local_date")
            raise Conflict, "open digest identity changed during replacement"
          end

          write_json(base_path(date), prepared)
          prepared
        end
      end

      def append_amendment(local_date, amendment)
        date = normalize_date(local_date)
        prepared = Record.prepare_amendment(date, amendment)
        synchronize do
          raise PrunedRecord, "digest #{date} was pruned" if tombstone_exists?(date)
          base = read_json(base_path(date))
          raise MissingRecord, "digest #{date} is missing" unless base
          unless base.fetch("lifecycle") == "closed"
            raise ImmutableRecord, "digest #{date} must close before it can be amended"
          end

          path = amendment_path(date, prepared.fetch("amendment_id"))
          if File.file?(path)
            existing = read_json(path)
            return existing if Record.canonical_json(existing) == Record.canonical_json(prepared)

            raise Conflict, "conflicting digest amendment #{prepared.fetch('amendment_id').inspect}"
          end
          write_json(path, prepared)
          prepared
        end
      end

      def read(local_date)
        date = normalize_date(local_date)
        synchronize(shared: true) do
          if tombstone_exists?(date)
            return read_json(tombstone_path(date)).merge("lifecycle" => "pruned")
          end
          base = read_json(base_path(date))
          raise MissingRecord, "digest #{date} is missing" unless base

          amendments = amendment_files(date).map { |path| read_json(path) }
                                               .sort_by { |entry| [ entry.fetch("amended_at"), entry.fetch("amendment_id") ] }
          effective(base, amendments, read_json(frontier_path(date)))
        end
      end

      def advance_frontiers(local_date, source_frontiers)
        date = normalize_date(local_date)
        synchronize do
          raise PrunedRecord, "digest #{date} was pruned" if tombstone_exists?(date)
          base = read_json(base_path(date))
          raise MissingRecord, "digest #{date} is missing" unless base

          amendments = amendment_files(date).map { |path| read_json(path) }
          current = effective(base, amendments, read_json(frontier_path(date)))
                    .fetch("effective_source_frontiers")
          merged = merge_frontiers(current, source_frontiers)
          return merged if Record.canonical_json(current) == Record.canonical_json(merged)

          write_json(frontier_path(date), merged)
          merged
        end
      end

      def prune(local_date, pruned_at:, reason:)
        date = normalize_date(local_date)
        synchronize do
          return read_json(tombstone_path(date)) if tombstone_exists?(date)

          base = read_json(base_path(date))
          raise MissingRecord, "digest #{date} is missing" unless base
          unless base.fetch("lifecycle") == "closed"
            raise ImmutableRecord, "open digest #{date} cannot be pruned"
          end
          amendments = amendment_files(date).map { |path| read_json(path) }
          projected = effective(base, amendments, read_json(frontier_path(date)))
          payload = {
            "schema" => "hive-digest-prune-receipt",
            "schema_version" => 1,
            "local_date" => date,
            "record_id" => base.fetch("record_id"),
            "pruned_at" => normalize_time(pruned_at),
            "reason" => String(reason),
            "interval" => base.slice(
              "local_date", "sequence", "time_zone", "starts_at", "ends_at",
              "boundary_kind", "cutover"
            ),
            "source_frontiers" => projected.fetch("effective_source_frontiers", {}),
            "discards" => [],
            "discarded_amendment_ids" => amendment_files(date).map do |path|
              read_json(path).fetch("amendment_id")
            end.sort
          }
          payload["receipt_id"] = Record.content_id(payload)
          write_json(tombstone_path(date), payload)
          projection = record_directory(date)
          FileUtils.remove_entry_secure(projection) if File.directory?(projection)
          Hive::AtomicFile.fsync_directory(File.dirname(projection))
          payload
        end
      end

      # A tombstone is permanent history. Late source input is acknowledged by
      # appending a bounded discard audit and advancing its frontier in the same
      # locked atomic rewrite; the removed projection is never recreated.
      def discard_pruned(local_date, entries:, source_frontiers:, discarded_at:)
        date = normalize_date(local_date)
        synchronize do
          tombstone = read_json(tombstone_path(date))
          raise MissingRecord, "digest #{date} has no prune tombstone" unless tombstone

          existing = Array(tombstone["discards"])
          normalized = Array(entries).map do |entry|
            normalize_discard(entry, discarded_at: discarded_at)
          end
          known = existing.to_h { |entry| [ entry.fetch("discard_id"), entry ] }
          normalized.each do |entry|
            current = known[entry.fetch("discard_id")]
            if current && Record.canonical_json(current) != Record.canonical_json(entry)
              raise Conflict, "conflicting pruned digest discard #{entry.fetch('discard_id')}"
            end
            known[entry.fetch("discard_id")] ||= entry
          end
          tombstone["discards"] = known.values.sort_by do |entry|
            [ entry.fetch("discarded_at"), entry.fetch("discard_id") ]
          end
          tombstone["source_frontiers"] = merge_frontiers(
            tombstone.fetch("source_frontiers", {}), source_frontiers
          )
          write_json(tombstone_path(date), tombstone)
          tombstone
        end
      end

      def dates
        synchronize(shared: true) do
          persisted = Dir.glob(File.join(records_root, "????-??-??"))
                         .select { |path| File.directory?(path) }
                         .map { |path| File.basename(path) }
          pruned = Dir.glob(File.join(tombstones_root, "????-??-??.json"))
                      .map { |path| File.basename(path, ".json") }
          (persisted + pruned).uniq.sort.freeze
        end
      end

      def intervals
        dates.filter_map do |date|
          value = read(date)
          interval = value["lifecycle"] == "pruned" ? value["interval"] : value
          next unless interval.is_a?(Hash)

          interval.slice(
            "local_date", "sequence", "time_zone", "starts_at", "ends_at",
            "boundary_kind", "cutover", "interval_id"
          )
        end.sort_by do |interval|
          [ interval["sequence"] || Float::INFINITY, interval.fetch("starts_at") ]
        end.freeze
      end

      def base_path(local_date)
        File.join(record_directory(normalize_date(local_date)), "base.json")
      end

      def frontier_path(local_date)
        File.join(record_directory(normalize_date(local_date)), "frontiers.json")
      end

      def tombstone_path(local_date)
        File.join(tombstones_root, "#{normalize_date(local_date)}.json")
      end

      private

      def effective(base, amendments, frontier_overlay = nil)
        resolved = amendments.flat_map { |entry| entry.fetch("resolved_gap_ids") }.uniq
        gaps = base.fetch("gaps").reject { |gap| resolved.include?(gap["gap_id"]) }
        gaps.concat(amendments.flat_map { |entry| entry.fetch("gaps", []) })
        gaps = gaps.uniq { |gap| gap.fetch("gap_id") }
        items = (base.fetch("items") + amendments.flat_map { |entry| entry.fetch("items") })
                .uniq { |item| item.fetch("fact_id") }
        attention = (
          base.fetch("attention") + amendments.flat_map { |entry| entry.fetch("attention", []) }
        ).uniq { |item| item.fetch("attention_id") }
        frontiers = amendments.reduce(base.fetch("source_frontiers", {})) do |memo, amendment|
          merge_frontiers(memo, amendment.fetch("source_frontiers", {}))
        end
        frontiers = merge_frontiers(frontiers, frontier_overlay || {})
        completeness = gaps.empty? ? "complete" : "partial"
        content = if !items.empty? || !attention.empty?
          "non_empty"
        elsif completeness == "partial"
          "unknown"
        else
          "empty"
        end
        base.merge(
          "amendments" => amendments,
          "items" => items,
          "attention" => attention,
          "effective_gaps" => gaps,
          "effective_completeness" => completeness,
          "effective_content" => content,
          "effective_source_frontiers" => frontiers
        )
      end

      def normalize_discard(value, discarded_at:)
        input = Record.canonical_object(value.to_h)
        identity = input.fetch("identity").to_s.byteslice(0, 256)
        source = input.fetch("source").to_s.byteslice(0, 80)
        kind = input.fetch("kind").to_s.byteslice(0, 80)
        raise InvalidRecord, "pruned discard identity/source/kind are required" if
          identity.empty? || source.empty? || kind.empty?

        row = {
          "identity" => identity,
          "kind" => kind,
          "source" => source,
          "observed_at" => normalize_time(input["observed_at"] || discarded_at),
          "discarded_at" => normalize_time(discarded_at),
          "reason" => input.fetch("reason", "projection was pruned").to_s.byteslice(0, 240)
        }
        row["discard_id"] = Record.content_id(row)
        row
      rescue KeyError, NoMethodError
        raise InvalidRecord, "pruned discard must be an object with identity, source, and kind"
      end

      def merge_frontiers(existing, incoming)
        Record.canonical_object(existing.to_h.merge(incoming.to_h))
      rescue NoMethodError
        raise InvalidRecord, "source frontiers must be objects"
      end

      def record_directory(date)
        File.join(records_root, date)
      end

      def records_root
        File.join(root, "records")
      end

      def tombstones_root
        File.join(root, "tombstones")
      end

      def amendment_path(date, amendment_id)
        digest = Digest::SHA256.hexdigest(amendment_id)
        File.join(record_directory(date), "amendments", "#{digest}.json")
      end

      def amendment_files(date)
        Dir.glob(File.join(record_directory(date), "amendments", "*.json")).sort
      end

      def tombstone_exists?(date)
        File.file?(tombstone_path(date))
      end

      def write_json(path, value)
        ensure_private_directory!(File.dirname(path))
        Hive::AtomicFile.write(path, "#{Record.canonical_json(value)}\n", mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
        value
      end

      def read_json(path)
        return nil unless File.file?(path)

        JSON.parse(File.binread(path))
      rescue JSON::ParserError => error
        raise Error, "digest state at #{path} is corrupt: #{error.message}"
      end

      def synchronize(shared: false)
        ensure_private_directory!(root)
        lock_path = File.join(root, ".store.lock")
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(lock_path, flags, 0o600) do |lock|
          raise UnsafePath, "digest store lock is not a regular file" unless lock.stat.file?

          lock.chmod(0o600)
          lock.flock(shared ? File::LOCK_SH : File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise UnsafePath, "digest store lock cannot be a symlink"
      end

      def ensure_private_directory!(path)
        FileUtils.mkdir_p(path, mode: 0o700)
        cursor = path
        while cursor.start_with?(root) && cursor != File.dirname(cursor)
          File.chmod(0o700, cursor) if File.directory?(cursor)
          break if cursor == root

          cursor = File.dirname(cursor)
        end
      end

      def normalize_date(value)
        Date.iso8601(value.to_s).iso8601
      rescue Date::Error, TypeError
        raise InvalidRecord, "invalid digest local date #{value.inspect}"
      end

      def normalize_time(value)
        time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
        time.utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise InvalidRecord, "invalid digest timestamp #{value.inspect}"
      end
    end
  end
end
