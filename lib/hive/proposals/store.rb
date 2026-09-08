require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "tmpdir"
require "hive/atomic_file"
require "hive/proposals/projection"
require "hive/secret_patterns"

module Hive
  module Proposals
    Diagnostic = Data.define(:code, :path, :sha256, :bytes, :proposal_id) do
      def to_h
        {
          "kind" => "quarantine", "code" => code, "path" => path,
          "sha256" => sha256, "bytes" => bytes, "proposal_id" => proposal_id
        }
      end
    end

    Snapshot = Data.define(:records, :events, :projections, :diagnostics) do
      def empty? = records.empty? && events.empty? && diagnostics.empty?
    end

    class Store
      MAX_FILE_BYTES = 256 * 1024
      MAX_DIAGNOSTICS = 1_024
      EVENT_FILENAME = /\A(\d+)-(pev-[0-9a-f-]+)\.json\z/i

      attr_reader :root, :records_root, :events_root

      class Transaction
        def initialize(store)
          @store = store
        end

        def snapshot = @snapshot ||= @store.send(:load_unlocked)

        def append_event!(**attributes)
          event = @store.send(:append_event_unlocked!, snapshot:, **attributes)
          @snapshot = nil
          event
        end
      end

      def initialize(root:, id_generator: -> { SecureRandom.uuid }, unsafe_paths: {},
                     lock_timeout: STATE_LOCK_TIMEOUT_SEC)
        @root = File.expand_path(root)
        @records_root = File.join(@root, "records")
        @events_root = File.join(@root, "events")
        @id_generator = id_generator
        @unsafe_paths = Proposals.stringify(unsafe_paths || {})
        @lock_timeout = lock_timeout
      end

      def create_record!(proposal_id: nil, **attributes)
        with_lock do
          existing = find_by_source_event_unlocked(attributes.fetch(:source_event_id))
          if existing
            unless existing.is_a?(Record)
              raise Conflict, "proposal source event already belongs to another mutation"
            end
            candidate = Record.build(
              proposal_id: existing.proposal_id, **attributes
            )
            return existing if candidate.to_h == existing.to_h

            raise Conflict, "proposal source event conflicts with its immutable record"
          end
          id = proposal_id || "prp-#{@id_generator.call}"
          record = Record.build(proposal_id: id, **attributes)
          validate_retry_predecessor!(record)
          write_record_unlocked!(record)
        end
      end

      def write_record!(record)
        record = record.is_a?(Record) ? record : Record.new(record)
        with_lock { write_record_unlocked!(record) }
      end

      def fetch_record(proposal_id)
        id = Proposals.proposal_id!(proposal_id)
        path = record_path(id)
        return nil unless path_exists?(path)

        bytes = safe_read(path, logical_path: "records/#{id}.json")
        return nil if bytes.nil?
        raise InvalidRecord, "proposal record is quarantined" if bytes.is_a?(Diagnostic)

        parse_record(bytes, expected_id: id)
      end

      def append_event!(proposal_id:, type:, data:, source_event_id:, provenance:,
                        occurred_at: Time.now.utc, event_id: nil, policy: DEFAULT_POLICY,
                        before_write: nil)
        proposal_id = Proposals.proposal_id!(proposal_id, error: InvalidEvent)
        with_lock do
          append_event_unlocked!(
            proposal_id:, type:, data:, source_event_id:, provenance:,
            occurred_at:, event_id:, policy:, before_write:
          )
        end
      end

      def transaction
        with_lock { yield Transaction.new(self) }
      end

      def fetch_event(event_id)
        id = Proposals.event_id!(event_id)
        load.events.values.flatten.find { |event| event.event_id == id }
      end

      def load
        load_unlocked
      end

      def projection(proposal_id)
        load.projections.find { |item| item.proposal_id == proposal_id.to_s }
      end

      def paths_for_record(proposal_id)
        [ record_path(Proposals.proposal_id!(proposal_id)) ]
      end

      def path_for_event(event)
        event = event.is_a?(Event) ? event : Event.new(event)
        event_path(event)
      end

      private

      def append_event_unlocked!(proposal_id:, type:, data:, source_event_id:, provenance:,
                                 occurred_at:, event_id:, policy:, snapshot: nil,
                                 before_write: nil)
        raise InvalidEvent, "proposal does not exist" unless fetch_record_unlocked(proposal_id)
        existing = find_by_source_event_unlocked(source_event_id, snapshot:)
        if existing
          unless existing.is_a?(Event) && existing.proposal_id == proposal_id && existing.type == type.to_s
            raise Conflict, "proposal source event already belongs to another mutation"
          end
          candidate = Event.build(
            event_id: existing.event_id, proposal_id:, version: existing.version,
            type:, data:, source_event_id:, provenance:, occurred_at:, policy:
          )
          return existing if candidate.to_h == existing.to_h

          raise Conflict, "proposal source event conflicts with its immutable event"
        end
        version = next_version_unlocked(proposal_id)
        id = event_id || "pev-#{@id_generator.call}"
        event = Event.build(
          event_id: id, proposal_id:, version:, type:, data:, source_event_id:,
          provenance:, occurred_at:, policy:
        )
        before_write&.call(event, Proposals.canonical(event.to_h))
        write_event_unlocked!(event)
      end

      def write_record_unlocked!(record)
        path = record_path(record.proposal_id)
        bytes = Proposals.canonical(record.to_h)
        if path_exists?(path)
          existing = safe_read(path, logical_path: logical(path))
          if existing.is_a?(String) && existing == bytes
            return record
          end
          raise Conflict, "immutable proposal record already exists with different content"
        end
        create_immutable(path, bytes)
        cache_source_event!(record)
        record
      end

      def write_event_unlocked!(event)
        path = event_path(event)
        bytes = Proposals.canonical(event.to_h)
        if path_exists?(path)
          existing = safe_read(path, logical_path: logical(path))
          return event if existing.is_a?(String) && existing == bytes

          raise Conflict, "immutable proposal event path already exists with different content"
        end
        create_immutable(path, bytes)
        cache_source_event!(event)
        event
      end

      def create_immutable(path, bytes)
        raise QuotaExceeded, "proposal file exceeds #{MAX_FILE_BYTES} bytes" if bytes.bytesize > MAX_FILE_BYTES

        ensure_safe_directory!(File.dirname(path))
        Hive::AtomicFile.create(path, bytes, mode: 0o600)
      rescue Errno::EEXIST
        raise Conflict, "immutable proposal path appeared concurrently"
      rescue SystemCallError, IOError => e
        raise Error, "proposal file could not be created: #{e.class}"
      end

      def load_unlocked
        diagnostics = []
        records = load_records(diagnostics)
        events, reserved_versions = load_events(diagnostics)
        load_source_quarantine(diagnostics)
        projections = build_projections(records, events, reserved_versions, diagnostics)
        Snapshot.new(
          records: records.sort_by(&:proposal_id).freeze,
          events: events.transform_values { |items| items.sort_by(&:version).freeze }.sort.to_h.freeze,
          projections: projections.sort_by(&:proposal_id).freeze,
          diagnostics: diagnostics.sort_by { |item| [ item.path, item.code ] }.first(MAX_DIAGNOSTICS).freeze
        )
      end

      def load_records(diagnostics)
        return [] unless safe_directory?(records_root)

        children(records_root).filter_map do |basename|
          logical_path = "records/#{basename}"
          path = File.join(records_root, basename)
          unless basename.end_with?(".json")
            diagnostics << diagnostic("invalid_record_filename", path, logical_path:)
            next
          end
          bytes = safe_read(path, logical_path:)
          if bytes.is_a?(Diagnostic)
            diagnostics << bytes
            next
          end
          record = parse_record(bytes, expected_id: File.basename(basename, ".json"))
          record
        rescue JSON::ParserError
          diagnostics << diagnostic("invalid_json", path, bytes:, logical_path:)
          nil
        rescue InvalidRecord
          diagnostics << diagnostic("invalid_record", path, bytes:, logical_path:)
          nil
        end
      end

      def load_events(diagnostics)
        return [ {}, {} ] unless safe_directory?(events_root)

        events = Hash.new { |hash, key| hash[key] = [] }
        reserved_versions = Hash.new { |hash, key| hash[key] = [] }
        seen_ids = {}
        children(events_root).each do |proposal_basename|
          proposal_path = File.join(events_root, proposal_basename)
          unless proposal_basename.match?(PROPOSAL_ID) && safe_directory?(proposal_path)
            diagnostics << diagnostic(
              "invalid_event_directory", proposal_path, logical_path: "events/#{proposal_basename}"
            )
            next
          end
          children(proposal_path).each do |basename|
            path = File.join(proposal_path, basename)
            logical_path = "events/#{proposal_basename}/#{basename}"
            reserved = basename.match(/\A(\d+)-/)&.[](1)&.to_i
            reserved_versions[proposal_basename] << reserved if reserved&.positive?
            match = basename.match(EVENT_FILENAME)
            unless match && match[1].to_i.positive?
              diagnostics << diagnostic(
                "invalid_event_filename", path, logical_path:, proposal_id: proposal_basename
              )
              next
            end
            bytes = safe_read(path, logical_path:)
            if bytes.is_a?(Diagnostic)
              diagnostics << bytes
              next
            end
            event = parse_event(
              bytes, expected_proposal_id: proposal_basename,
              expected_version: match[1].to_i, expected_event_id: match[2]
            )
            if seen_ids.key?(event.event_id)
              diagnostics << diagnostic(
                "duplicate_event", path, bytes:, logical_path:, proposal_id: proposal_basename
              )
              next
            end
            seen_ids[event.event_id] = true
            events[proposal_basename] << event
          rescue JSON::ParserError
            diagnostics << diagnostic(
              "invalid_json", path, bytes:, logical_path:, proposal_id: proposal_basename
            )
          rescue InvalidEvent
            diagnostics << diagnostic(
              "invalid_event", path, bytes:, logical_path:, proposal_id: proposal_basename
            )
          end
        end
        [ events, reserved_versions ]
      end

      def build_projections(records, events, reserved_versions, diagnostics)
        known = records.to_h { |record| [ record.proposal_id, record ] }
        projections = records.filter_map do |record|
          Projection.new(
            record:, events: events.fetch(record.proposal_id, []),
            reserved_versions: reserved_versions.fetch(record.proposal_id, [])
          )
        rescue InconsistentHistory
          diagnostics << collection_diagnostic("inconsistent_history", record.proposal_id)
          nil
        end
        dangling_event_ids = events.keys - known.keys
        dangling_event_ids.each do |proposal_id|
          diagnostics << collection_diagnostic("dangling_proposal_reference", proposal_id)
        end
        valid = projections.to_h { |projection| [ projection.proposal_id, projection ] }
        supersession_edges = {}
        projections.each do |projection|
          successor = projection.superseded_by
          next unless successor
          successor_projection = valid[successor]
          unless successor_projection && same_subject?(projection, successor_projection) &&
                 successor_projection.record["lineage"]["requested_supersedes"] == projection.proposal_id
            diagnostics << collection_diagnostic("dangling_or_mismatched_supersession", projection.proposal_id)
            valid.delete(projection.proposal_id)
            next
          end
          supersession_edges[projection.proposal_id] = successor
        end
        retry_edges = projections.to_h do |projection|
          [ projection.proposal_id, projection.record["lineage"]["retries"] ]
        end.compact
        retry_edges.each do |proposal_id, predecessor_id|
          projection = valid[proposal_id]
          predecessor = valid[predecessor_id]
          next if projection && predecessor && proposal_id != predecessor_id &&
                  same_subject?(projection, predecessor)

          diagnostics << collection_diagnostic("dangling_or_mismatched_retry", proposal_id)
          valid.delete(proposal_id)
        end
        retry_edges.select! { |proposal_id, predecessor_id| valid.key?(proposal_id) && valid.key?(predecessor_id) }
        cycle_nodes = Proposals.lineage_cycle_nodes(supersession_edges.merge(retry_edges))
        cycle_nodes.each do |proposal_id|
          diagnostics << collection_diagnostic("lineage_cycle", proposal_id)
          valid.delete(proposal_id)
        end
        reciprocal = Hash.new { |hash, key| hash[key] = [] }
        supersession_edges.each { |predecessor, successor| reciprocal[successor] << predecessor }
        valid.values.map do |projection|
          Projection.new(
            record: projection.record, events: projection.events,
            supersedes: reciprocal.fetch(projection.proposal_id, []),
            reserved_versions: projection.reserved_versions
          )
        end
      end

      def load_source_quarantine(diagnostics)
        directory = File.join(root, "inbox", "quarantine")
        return unless safe_directory?(directory)

        children(directory).each do |basename|
          path = File.join(directory, basename)
          logical_path = "inbox/quarantine/#{basename}"
          bytes = safe_read(path, logical_path:)
          if bytes.is_a?(Diagnostic)
            diagnostics << bytes
            next
          end
          document = JSON.parse(bytes)
          valid = document.is_a?(Hash) && document["schema"] == "hive-proposal-source-status" &&
            document["schema_version"] == 1 && document["state"] == "quarantine" &&
            document["source_event_id"].to_s.match?(SOURCE_EVENT_ID) &&
            document["proposal_id"].to_s.match?(PROPOSAL_ID) &&
            document.dig("reason", "code").is_a?(String)
          raise InvalidRecord unless valid

          code = Proposals.label!(document.dig("reason", "code"), label: "source quarantine code")
          diagnostics << Diagnostic.new(
            code: "source_#{code}".byteslice(0, 128), path: safe_diagnostic_path(logical_path),
            sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize,
            proposal_id: document.fetch("proposal_id")
          )
        rescue JSON::ParserError, InvalidRecord
          diagnostics << diagnostic("invalid_source_quarantine", path, bytes:, logical_path:)
        end
      end

      def same_subject?(left, right)
        left.subject == right.subject
      end

      def validate_retry_predecessor!(record)
        predecessor_id = record["lineage"]["retries"]
        return unless predecessor_id
        raise InvalidRecord, "proposal retry predecessor must be distinct" if predecessor_id == record.proposal_id

        predecessor = fetch_record_unlocked(predecessor_id)
        unless predecessor && predecessor.subject == record.subject
          raise InvalidRecord, "proposal retry predecessor is missing or has a different subject"
        end
      end

      def find_by_source_event_unlocked(source_event_id, snapshot: nil)
        id = Proposals.source_event_id!(source_event_id)
        if snapshot
          return snapshot.records.find { |record| record.source_event_id == id } ||
            snapshot.events.values.flatten.find { |event| event.source_event_id == id }
        end

        refresh_source_event_cache_unlocked!
        value = @source_event_cache[id]
        raise Conflict, "proposal source event belongs to multiple canonical mutations" if value == :conflict
        value
      end

      def refresh_source_event_cache_unlocked!
        generation = source_event_cache_generation
        return if @source_event_cache && @source_event_cache_generation == generation

        snapshot = load_unlocked
        cache = {}
        (snapshot.records + snapshot.events.values.flatten).each do |item|
          id = item.source_event_id
          cache[id] = cache.key?(id) ? :conflict : item
        end
        @source_event_cache = cache
        @source_event_cache_generation = generation
      end

      def cache_source_event!(item)
        return unless @source_event_cache

        id = item.source_event_id
        @source_event_cache[id] = @source_event_cache.key?(id) ? :conflict : item
        @source_event_cache_generation = source_event_cache_generation
      end

      def source_event_cache_generation
        paths = children(records_root).map { |child| File.join(records_root, child) }
        if safe_directory?(events_root)
          children(events_root).each do |proposal|
            directory = File.join(events_root, proposal)
            paths << directory
            paths.concat(children(directory).map { |child| File.join(directory, child) }) if safe_directory?(directory)
          end
        end
        paths.sort.filter_map do |path|
          stat = File.lstat(path)
          [ path, stat.ftype, stat.ino, stat.size, stat.mtime.to_r.to_s, stat.ctime.to_r.to_s ]
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        end
      end

      def fetch_record_unlocked(proposal_id)
        path = record_path(proposal_id)
        return nil unless path_exists?(path)
        bytes = safe_read(path, logical_path: logical(path))
        raise InvalidRecord, "proposal record is quarantined" if bytes.is_a?(Diagnostic)

        parse_record(bytes, expected_id: proposal_id)
      end

      def next_version_unlocked(proposal_id)
        directory = File.join(events_root, proposal_id)
        return 1 unless safe_directory?(directory)

        reserved = children(directory).filter_map do |basename|
          match = basename.match(/\A(\d+)-/)
          match && match[1].to_i
        end
        (reserved.max || 0) + 1
      end

      def parse_record(bytes, expected_id:)
        data = JSON.parse(bytes)
        raise InvalidRecord, "proposal record is not canonical" unless Proposals.canonical(data) == bytes
        record = Record.new(data)
        raise InvalidRecord, "proposal record path identity conflicts" unless record.proposal_id == expected_id
        record
      end

      def parse_event(bytes, expected_proposal_id:, expected_version:, expected_event_id:)
        data = JSON.parse(bytes)
        raise InvalidEvent, "proposal event is not canonical" unless Proposals.canonical(data) == bytes
        event = Event.new(data)
        unless event.proposal_id == expected_proposal_id && event.version == expected_version &&
               event.event_id == expected_event_id
          raise InvalidEvent, "proposal event path identity conflicts"
        end
        event
      end

      def safe_read(path, logical_path:)
        if (unsafe = @unsafe_paths[logical_path])
          bytes = File.binread(path, MAX_FILE_BYTES)
          return diagnostic(unsafe.fetch("code"), path, bytes:, logical_path:)
        end
        status = File.lstat(path)
        return diagnostic("symlink", path, logical_path:) if status.symlink?
        return diagnostic("special_file", path, logical_path:) unless status.file?
        return diagnostic("oversize", path, logical_path:, size: status.size) if status.size > MAX_FILE_BYTES

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          opened = file.stat
          current = File.lstat(path)
          unless opened.file? && !current.symlink? && opened.dev == current.dev && opened.ino == current.ino
            return diagnostic("raced_file", path, logical_path:)
          end
          bytes = file.read(MAX_FILE_BYTES + 1)
          return diagnostic("oversize", path, logical_path:, size: bytes.bytesize) if bytes.bytesize > MAX_FILE_BYTES
          bytes
        end
      rescue Errno::ELOOP
        diagnostic("symlink", path, logical_path:)
      rescue Errno::ENOENT, Errno::ENOTDIR
        diagnostic("missing_file", path, logical_path:)
      rescue SystemCallError, IOError
        diagnostic("unreadable_file", path, logical_path:)
      end

      def diagnostic(code, path, bytes: nil, logical_path:, size: nil, proposal_id: nil)
        safe_bytes = bytes || bounded_file_digest_input(path)
        Diagnostic.new(
          code:, path: safe_diagnostic_path(logical_path),
          sha256: Digest::SHA256.hexdigest(safe_bytes),
          bytes: size || safe_bytes.bytesize, proposal_id:
        )
      end

      def safe_diagnostic_path(value)
        Hive::SecretPatterns.redact(value.to_s).byteslice(0, 512).to_s
          .force_encoding(Encoding::UTF_8).scrub("")
      end

      def collection_diagnostic(code, proposal_id)
        Diagnostic.new(
          code:, path: "projections/#{proposal_id}",
          sha256: Digest::SHA256.hexdigest("#{code}\0#{proposal_id}"),
          bytes: 0, proposal_id:
        )
      end

      def bounded_file_digest_input(path)
        return "" unless File.file?(path) && !File.symlink?(path)
        File.binread(path, MAX_FILE_BYTES)
      rescue SystemCallError, IOError
        ""
      end

      def safe_directory?(path)
        status = File.lstat(path)
        status.directory? && !status.symlink?
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def ensure_safe_directory!(path)
        unless path == root || path.start_with?("#{root}/")
          raise Error, "proposal state directory escapes its root"
        end
        unless path_exists?(root)
          FileUtils.mkdir_p(root, mode: 0o700)
        end
        root_status = File.lstat(root)
        unless root_status.directory? && !root_status.symlink?
          raise Error, "proposal state directory is unsafe"
        end
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).each_filename.to_a
        current = root
        ensure_one_directory!(current)
        relative.each do |segment|
          current = File.join(current, segment)
          ensure_one_directory!(current)
        end
      end

      def ensure_one_directory!(path)
        FileUtils.mkdir(path, mode: 0o700) unless path_exists?(path)
        status = File.lstat(path)
        raise Error, "proposal state directory is unsafe" unless status.directory? && !status.symlink?
        File.chmod(0o700, path)
      rescue Errno::EEXIST
        retry
      end

      def children(path)
        Dir.children(path).sort
      rescue Errno::ENOENT, Errno::ENOTDIR
        []
      end

      def record_path(proposal_id) = File.join(records_root, "#{proposal_id}.json")

      def event_path(event)
        File.join(
          events_root, event.proposal_id,
          format("%020d-%s.json", event.version, event.event_id)
        )
      end

      def logical(path)
        Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      end

      def path_exists?(path) = File.exist?(path) || File.symlink?(path)

      def with_lock
        ensure_safe_directory!(root)
        Proposals.with_state_lock(root, timeout: @lock_timeout) { yield }
      end
    end
  end
end
