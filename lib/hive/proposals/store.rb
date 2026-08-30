require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "hive/atomic_file"
require "hive/proposals/projection"

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

      def initialize(root:, id_generator: -> { SecureRandom.uuid })
        @root = File.expand_path(root)
        @records_root = File.join(@root, "records")
        @events_root = File.join(@root, "events")
        @id_generator = id_generator
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
          write_record_unlocked!(Record.build(proposal_id: id, **attributes))
        end
      end

      def write_record!(record)
        record = record.is_a?(Record) ? record : Record.new(record)
        with_lock { write_record_unlocked!(record) }
      end

      def fetch_record(proposal_id)
        id = Proposals.proposal_id!(proposal_id)
        bytes = safe_read(record_path(id), logical_path: "records/#{id}.json")
        return nil if bytes.nil?
        raise InvalidRecord, "proposal record is quarantined" if bytes.is_a?(Diagnostic)

        parse_record(bytes, expected_id: id)
      rescue Errno::ENOENT
        nil
      end

      def append_event!(proposal_id:, type:, data:, source_event_id:, provenance:,
                        occurred_at: Time.now.utc, event_id: nil, policy: DEFAULT_POLICY)
        proposal_id = Proposals.proposal_id!(proposal_id, error: InvalidEvent)
        with_lock do
          raise InvalidEvent, "proposal does not exist" unless fetch_record_unlocked(proposal_id)
          existing = find_by_source_event_unlocked(source_event_id)
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
          write_event_unlocked!(event)
        end
      end

      def fetch_event(event_id)
        id = Proposals.event_id!(event_id)
        load.events.each_value.flatten.find { |event| event.event_id == id }
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
        events = load_events(diagnostics)
        projections = build_projections(records, events, diagnostics)
        Snapshot.new(
          records: records.sort_by(&:proposal_id).freeze,
          events: events.transform_values { |items| items.sort_by(&:version).freeze }.sort.to_h.freeze,
          projections: projections.sort_by(&:proposal_id).freeze,
          diagnostics: diagnostics.sort_by { |item| [ item.path, item.code ] }.first(MAX_DIAGNOSTICS).freeze
        )
      end

      def load_records(diagnostics)
        return [] unless safe_directory?(records_root)

        seen = {}
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
          if seen.key?(record.proposal_id)
            diagnostics << diagnostic("duplicate_record", path, bytes:, logical_path:, proposal_id: record.proposal_id)
            next
          end
          seen[record.proposal_id] = true
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
        return {} unless safe_directory?(events_root)

        events = Hash.new { |hash, key| hash[key] = [] }
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
        events
      end

      def build_projections(records, events, diagnostics)
        known = records.to_h { |record| [ record.proposal_id, record ] }
        projections = records.filter_map do |record|
          Projection.new(record:, events: events.fetch(record.proposal_id, []))
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
        cycle_nodes = cycle_nodes(supersession_edges.merge(retry_edges))
        cycle_nodes.each do |proposal_id|
          diagnostics << collection_diagnostic("lineage_cycle", proposal_id)
          valid.delete(proposal_id)
        end
        reciprocal = Hash.new { |hash, key| hash[key] = [] }
        supersession_edges.each { |predecessor, successor| reciprocal[successor] << predecessor }
        valid.values.map do |projection|
          Projection.new(
            record: projection.record, events: projection.events,
            supersedes: reciprocal.fetch(projection.proposal_id, [])
          )
        end
      end

      def same_subject?(left, right)
        left.subject == right.subject
      end

      def cycle_nodes(edges)
        cycles = []
        edges.each_key do |origin|
          path = []
          current = origin
          while current && !path.include?(current)
            path << current
            current = edges[current]
          end
          cycles.concat(path.drop(path.index(current))) if current && path.include?(current)
        end
        cycles.uniq.sort
      end

      def find_by_source_event_unlocked(source_event_id)
        id = Proposals.source_event_id!(source_event_id)
        snapshot = load_unlocked
        snapshot.records.find { |record| record.source_event_id == id } ||
          snapshot.events.values.flatten.find { |event| event.source_event_id == id }
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
          code:, path: logical_path.to_s.byteslice(0, 512),
          sha256: Digest::SHA256.hexdigest(safe_bytes),
          bytes: size || safe_bytes.bytesize, proposal_id:
        )
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
        lock_path = File.join(root, ".proposal.lock")
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(lock_path, flags, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise Error, "proposal state lock is unsafe"
      end
    end
  end
end
