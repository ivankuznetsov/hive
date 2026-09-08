require "fileutils"
require "json"
require "time"
require "tmpdir"
require "find"
require "pathname"
require "hive/atomic_file"
require "hive/proposals/source_event"

module Hive
  module Proposals
    class SourceEventStore
      INDEX_SCHEMA = "hive-proposal-source-index".freeze
      STATUS_SCHEMA = "hive-proposal-source-status".freeze
      MAX_FILE_BYTES = 256 * 1024
      MAX_TERMINAL_BYTES = 4 * 1024
      MAX_NAMESPACE_PATHS = 50_000
      DEFAULT_LIMITS = {
        "max_pending_sources" => 256,
        "max_project_events" => 10_000,
        "max_proposal_events" => 1_000,
        "max_project_bytes" => 64 * 1024 * 1024,
        "max_proposal_bytes" => 8 * 1024 * 1024,
        "max_sources_per_actor_per_hour" => 100
      }.freeze

      attr_reader :root, :inbox_root

      def initialize(root:, limits: {}, clock: -> { Time.now.utc },
                     lock_timeout: STATE_LOCK_TIMEOUT_SEC)
        @root = File.expand_path(root)
        @inbox_root = File.join(@root, "inbox")
        @limits = DEFAULT_LIMITS.merge(Proposals.stringify(limits || {}))
        @clock = clock
        @lock_timeout = lock_timeout
      end

      def admit!(source_event)
        event = source_event.is_a?(SourceEvent) ? source_event : SourceEvent.new(source_event)
        bytes = Proposals.canonical(event.to_h)
        raise QuotaExceeded, "proposal source receipt is oversize" if bytes.bytesize > MAX_FILE_BYTES

        with_lock do
          existing = read_event_unlocked(event.source_event_id)
          if existing
            return existing if existing.to_h == event.to_h

            raise Conflict, "proposal source event ID was reused with changed content"
          end
          current = prune_recent_actor_events(read_index_unlocked)
          next_index = Proposals.stringify(current)
          next_index["pending"] << event.source_event_id
          next_index["pending"].sort!
          next_index["pending_proposals"][event.source_event_id] = event.proposal_id
          next_index["reservations"][event.source_event_id] = {
            "bytes" => MAX_FILE_BYTES + MAX_TERMINAL_BYTES, "events" => 1
          }
          next_index["total_sources"] += 1
          add_usage!(
            next_index.fetch("usage"), event.proposal_id,
            bytes: bytes.bytesize, events: 1
          )
          next_index["recent_actor_events"] << {
            "actor_id" => event.to_h.dig("actor", "id"),
            "occurred_at" => Proposals.timestamp!(@clock.call, label: "proposal rate time")
          }
          index_bytes = encoded_index(next_index)
          enforce_source_quotas!(
            current, event, receipt_bytes: bytes.bytesize,
            next_index_bytes: index_bytes.bytesize
          )
          create_immutable(event_path(event.source_event_id), bytes)
          write_index_bytes_unlocked(index_bytes)
          event
        end
      rescue Errno::EEXIST
        raise Conflict, "proposal source receipt appeared concurrently"
      end

      def fetch(source_event_id)
        id = Proposals.source_event_id!(source_event_id)
        with_lock { read_event_unlocked(id) }
      end

      def pending_ids
        with_lock { read_index_unlocked.fetch("pending").dup.freeze }
      end

      def index
        with_lock { read_index_unlocked }
      end

      def status(source_event_id)
        id = Proposals.source_event_id!(source_event_id)
        with_lock do
          %w[consumed quarantine].each do |state|
            document = read_json(status_path(state, id), max_bytes: MAX_FILE_BYTES)
            return document if document
          end
          return { "state" => "pending", "source_event_id" => id } if read_index_unlocked["pending"].include?(id)
        end
        nil
      end

      def mark_consumed!(source_event_id, result:)
        terminal_status!(source_event_id, state: "consumed", result: result, reason: nil)
      end

      def quarantine!(source_event_id, code:, reason:)
        terminal_status!(
          source_event_id, state: "quarantine",
          result: nil, reason: {
            "code" => Proposals.label!(code, label: "proposal quarantine code"),
            "message" => Proposals.text!(reason, label: "proposal quarantine reason", max_bytes: 1_024)
          }
        )
      end

      def paths_for_admission(source_event_id)
        id = Proposals.source_event_id!(source_event_id)
        [ event_path(id), index_path ]
      end

      def paths_for_terminal(source_event_id, state:)
        id = Proposals.source_event_id!(source_event_id)
        [ status_path(state.to_s, id), index_path ]
      end

      def paths_for_lifecycle = [ index_path ]

      def enforce_lifecycle!(proposal_id:, actor_id:, event_bytes:)
        proposal_id = Proposals.proposal_id!(proposal_id)
        actor_id = Proposals.label!(actor_id, label: "proposal lifecycle authority")
        bytes = Integer(event_bytes)
        raise InvalidRecord, "proposal lifecycle event bytes must be positive" unless bytes.positive?

        with_lock do
          current = prune_recent_actor_events(read_index_unlocked)
          usage = namespace_usage_unlocked(current)
          next_index = Proposals.stringify(current)
          add_usage!(next_index.fetch("usage"), proposal_id, bytes:, events: 1)
          next_index.fetch("recent_actor_events") << {
            "actor_id" => actor_id,
            "occurred_at" => Proposals.timestamp!(@clock.call, label: "proposal rate time")
          }
          index_bytes = encoded_index(next_index)
          index_growth = index_bytes.bytesize - file_size(index_path)
          enforce_aggregate!(
            usage, proposal_id:, added_bytes: bytes + index_growth, added_events: 1,
            actor_id:, recent_events: current.fetch("recent_actor_events"),
            proposal_added_bytes: bytes
          )
          write_index_bytes_unlocked(index_bytes)
        end
        true
      rescue ArgumentError, TypeError
        raise InvalidRecord, "proposal lifecycle event bytes must be positive"
      end

      private

      def terminal_status!(source_event_id, state:, result:, reason:)
        id = Proposals.source_event_id!(source_event_id)
        with_lock do
          current = read_index_unlocked
          existing = %w[consumed quarantine].filter_map do |candidate|
            read_json(status_path(candidate, id), max_bytes: MAX_FILE_BYTES)
          end.first
          return existing if existing
          raise SourceUnavailable, "proposal source receipt is not pending" unless current["pending"].include?(id)
          proposal_id = current.fetch("pending_proposals").fetch(id)

          document = {
            "schema" => STATUS_SCHEMA, "schema_version" => 1,
            "source_event_id" => id, "proposal_id" => proposal_id, "state" => state,
            "result" => result, "reason" => reason,
            "recorded_at" => Proposals.timestamp!(@clock.call, label: "source status time")
          }
          bytes = Proposals.canonical(document)
          reservation = current.fetch("reservations").fetch(id)
          if bytes.bytesize > MAX_TERMINAL_BYTES || bytes.bytesize > reservation.fetch("bytes")
            raise Error, "proposal terminal status exceeds its admission reservation"
          end
          next_index = Proposals.stringify(current)
          next_index["pending"].delete(id)
          next_index["pending_proposals"].delete(id)
          next_index["reservations"].delete(id)
          next_index["#{state == 'consumed' ? 'consumed' : 'quarantined'}_count"] += 1
          canonical_bytes, canonical_events = canonical_usage_for_result(result)
          add_usage!(
            next_index.fetch("usage"), proposal_id,
            bytes: bytes.bytesize + canonical_bytes, events: canonical_events
          )
          index_bytes = encoded_index(next_index)
          create_immutable(status_path(state, id), bytes)
          write_index_bytes_unlocked(index_bytes)
          document
        end
      end

      def enforce_source_quotas!(current, event, receipt_bytes:, next_index_bytes:)
        if current["pending"].length >= integer_limit("max_pending_sources")
          raise QuotaExceeded, "proposal pending source quota exceeded"
        end
        usage = namespace_usage_unlocked(current)
        existing_index_bytes = file_size(index_path)
        index_growth = next_index_bytes - existing_index_bytes
        enforce_aggregate!(
          usage, proposal_id: event.proposal_id,
          added_bytes: receipt_bytes + MAX_FILE_BYTES + MAX_TERMINAL_BYTES + index_growth,
          proposal_added_bytes: receipt_bytes + MAX_FILE_BYTES + MAX_TERMINAL_BYTES,
          added_events: 2, actor_id: event.to_h.dig("actor", "id"),
          recent_events: current.fetch("recent_actor_events")
        )
      end

      def enforce_aggregate!(usage, proposal_id:, added_bytes:, added_events:, actor_id:,
                             proposal_added_bytes: added_bytes, recent_events:)
        if usage.fetch("project_events") + usage.fetch("reserved_events") + added_events >
           integer_limit("max_project_events")
          raise QuotaExceeded, "proposal project event quota exceeded"
        end
        if usage.fetch("project_bytes") + usage.fetch("reserved_bytes") + added_bytes >
           integer_limit("max_project_bytes")
          raise QuotaExceeded, "proposal project byte quota exceeded"
        end
        proposal = usage.fetch("proposals").fetch(
          proposal_id, { "events" => 0, "bytes" => 0, "reserved_bytes" => 0,
                         "reserved_events" => 0 }
        )
        if proposal.fetch("events") + proposal.fetch("reserved_events") + added_events >
           integer_limit("max_proposal_events")
          raise QuotaExceeded, "proposal event quota exceeded"
        end
        if proposal.fetch("bytes") + proposal.fetch("reserved_bytes") + proposal_added_bytes >
           integer_limit("max_proposal_bytes")
          raise QuotaExceeded, "proposal byte quota exceeded"
        end
        if recent_events.count { |entry| entry["actor_id"] == actor_id } >=
           integer_limit("max_sources_per_actor_per_hour")
          raise QuotaExceeded, "proposal authority rate limit exceeded"
        end
      end

      def integer_limit(key)
        value = Integer(@limits.fetch(key))
        raise InvalidRecord, "proposal limit #{key} must be positive" unless value.positive?
        value
      rescue ArgumentError, TypeError
        raise InvalidRecord, "proposal limit #{key} must be positive"
      end

      def read_index_unlocked
        document = read_json(index_path, max_bytes: MAX_FILE_BYTES)
        return empty_index unless document
        required = %w[
          schema schema_version pending consumed_count quarantined_count total_sources
          pending_proposals reservations usage recent_actor_events
        ]
        unless document.is_a?(Hash) && document.keys.sort == required.sort &&
               document["schema"] == INDEX_SCHEMA && document["schema_version"] == 1 &&
               document["pending"].is_a?(Array) && document["pending"].uniq == document["pending"] &&
               document["pending"].all? { |id| id.to_s.match?(SOURCE_EVENT_ID) } &&
               valid_usage_index?(document) && valid_persisted_usage?(document["usage"]) &&
               valid_recent_actor_events?(document["recent_actor_events"])
          raise QuarantinedSource, "proposal source index is malformed"
        end
        %w[consumed_count quarantined_count total_sources].each do |key|
          unless document[key].is_a?(Integer) && document[key] >= 0
            raise QuarantinedSource, "proposal source index counter is malformed"
          end
        end
        document
      end

      def empty_index
        usage, recent_actor_events = scan_namespace_unlocked
        {
          "schema" => INDEX_SCHEMA, "schema_version" => 1, "pending" => [],
          "consumed_count" => 0, "quarantined_count" => 0,
          "total_sources" => 0, "pending_proposals" => {}, "reservations" => {},
          "usage" => usage, "recent_actor_events" => recent_actor_events
        }
      end

      def valid_usage_index?(document)
        pending = document["pending_proposals"]
        reservations = document["reservations"]
        return false unless pending.is_a?(Hash) && pending.keys.sort == document["pending"].sort
        return false unless pending.all? do |source_id, proposal_id|
          source_id.match?(SOURCE_EVENT_ID) && proposal_id.match?(PROPOSAL_ID)
        end
        reservations.is_a?(Hash) && reservations.keys.sort == document["pending"].sort &&
          reservations.all? do |source_id, counters|
            source_id.match?(SOURCE_EVENT_ID) && counters.is_a?(Hash) &&
              counters.keys.sort == %w[bytes events] &&
              counters.values.all? { |value| value.is_a?(Integer) && value.positive? }
          end
      end

      def namespace_usage_unlocked(index)
        usage = Proposals.stringify(index.fetch("usage"))
        usage["project_bytes"] += file_size(index_path)
        usage["reserved_bytes"] = 0
        usage["reserved_events"] = 0
        usage.fetch("proposals").each_value do |proposal|
          proposal["reserved_bytes"] = 0
          proposal["reserved_events"] = 0
        end
        index.fetch("reservations").each do |source_id, reservation|
          proposal_id = index.fetch("pending_proposals").fetch(source_id)
          proposal = proposal_usage(usage, proposal_id)
          usage["reserved_bytes"] += reservation.fetch("bytes")
          usage["reserved_events"] += reservation.fetch("events")
          proposal["reserved_bytes"] += reservation.fetch("bytes")
          proposal["reserved_events"] += reservation.fetch("events")
        end
        usage
      end

      def proposal_usage(usage, proposal_id)
        usage.fetch("proposals")[proposal_id] ||= {
          "events" => 0, "bytes" => 0, "reserved_bytes" => 0, "reserved_events" => 0
        }
      end

      def proposal_id_for_file(relative, path, data: nil)
        case relative
        when %r{\Arecords/(prp-[^/]+)\.json\z}, %r{\Aevents/(prp-[^/]+)/}
          Regexp.last_match(1).match?(PROPOSAL_ID) ? Regexp.last_match(1) : nil
        when %r{\Ainbox/(pse-[0-9a-f]{64})\.json\z}
          document = data || JSON.parse(File.binread(path, MAX_FILE_BYTES + 1))
          document["proposal_id"] if document.is_a?(Hash) &&
            document["proposal_id"].to_s.match?(PROPOSAL_ID)
        when %r{\Ainbox/(?:consumed|quarantine)/(pse-[0-9a-f]{64})\.json\z}
          document = data || JSON.parse(File.binread(path, MAX_FILE_BYTES + 1))
          document["proposal_id"] if document.is_a?(Hash) &&
            document["proposal_id"].to_s.match?(PROPOSAL_ID)
        end
      rescue JSON::ParserError, QuarantinedSource, SystemCallError, IOError
        nil
      end

      def namespace_event_file?(relative)
        relative.match?(%r{\Arecords/[^/]+\.json\z}) ||
          relative.match?(%r{\Aevents/[^/]+/[^/]+\.json\z}) ||
          relative.match?(%r{\Ainbox/pse-[0-9a-f]{64}\.json\z})
      end

      def recent_actor_events_unlocked(actor_id, index = read_index_unlocked)
        prune_recent_actor_events(index).fetch("recent_actor_events")
          .count { |entry| entry["actor_id"] == actor_id }
      end

      def prune_recent_actor_events(index)
        cutoff = @clock.call - 3_600
        copy = Proposals.stringify(index)
        copy["recent_actor_events"] = copy.fetch("recent_actor_events").select do |entry|
          Time.iso8601(entry.fetch("occurred_at")) >= cutoff
        rescue ArgumentError
          false
        end
        copy
      end

      def scan_namespace_unlocked
        usage = { "project_bytes" => 0, "project_events" => 0, "proposals" => {} }
        recent_actor_events = []
        paths = 0
        return [ usage, recent_actor_events ] unless File.exist?(root) || File.symlink?(root)

        Find.find(root) do |path|
          next if path == root
          paths += 1
          raise QuotaExceeded, "proposal namespace path quota exceeded" if paths > MAX_NAMESPACE_PATHS
          stat = File.lstat(path)
          if stat.symlink?
            Find.prune if stat.directory?
            next
          end
          next unless stat.file?

          relative = path.delete_prefix("#{root}/")
          next if relative == "inbox/index.json"

          data = bounded_json_file(path, stat.size)
          proposal_id = proposal_id_for_file(relative, path, data:)
          usage["project_bytes"] += stat.size
          event_file = namespace_event_file?(relative)
          usage["project_events"] += 1 if event_file
          if proposal_id
            proposal = usage.fetch("proposals")[proposal_id] ||= { "bytes" => 0, "events" => 0 }
            proposal["bytes"] += stat.size
            proposal["events"] += 1 if event_file
          end
          actor_event = recent_actor_event(relative, data)
          recent_actor_events << actor_event if actor_event
        rescue Errno::ENOENT, Errno::ENOTDIR
          next
        end
        [ usage, recent_actor_events ]
      end

      def bounded_json_file(path, size)
        return nil if size > MAX_FILE_BYTES

        data = JSON.parse(File.binread(path, MAX_FILE_BYTES + 1))
        data if data.is_a?(Hash)
      rescue JSON::ParserError, SystemCallError, IOError
        nil
      end

      def recent_actor_event(relative, data)
        return unless data.is_a?(Hash)

        actor_id, occurred_at = if relative.match?(%r{\Ainbox/pse-[0-9a-f]{64}\.json\z})
          [ data.dig("actor", "id"), data["created_at"] ] if data["actor"].is_a?(Hash)
        elsif relative.match?(%r{\Aevents/[^/]+/[^/]+\.json\z}) && data["type"] != "evaluation"
          provenance = data["provenance"]
          [ provenance.dig("actor", "id"), data["occurred_at"] ] if
            provenance.is_a?(Hash) && provenance["actor"].is_a?(Hash)
        end
        return unless actor_id.is_a?(String) && actor_id.bytesize <= 512 && actor_id.match?(SAFE_LABEL)
        return unless occurred_at.is_a?(String) && Time.iso8601(occurred_at) >= @clock.call - 3_600

        {
          "actor_id" => actor_id,
          "occurred_at" => Proposals.timestamp!(occurred_at, label: "proposal rate time")
        }
      rescue ArgumentError, InvalidRecord
        nil
      end

      def add_usage!(usage, proposal_id, bytes:, events:)
        usage["project_bytes"] += bytes
        usage["project_events"] += events
        proposal = usage.fetch("proposals")[proposal_id] ||= { "bytes" => 0, "events" => 0 }
        proposal["bytes"] += bytes
        proposal["events"] += events
      end

      def valid_persisted_usage?(usage)
        return false unless usage.is_a?(Hash) && usage.keys.sort == %w[project_bytes project_events proposals]
        return false unless %w[project_bytes project_events].all? do |key|
          usage[key].is_a?(Integer) && usage[key] >= 0
        end
        proposals = usage["proposals"]
        proposals.is_a?(Hash) && proposals.all? do |proposal_id, counters|
          proposal_id.match?(PROPOSAL_ID) && counters.is_a?(Hash) &&
            counters.keys.sort == %w[bytes events] &&
            counters.values.all? { |value| value.is_a?(Integer) && value >= 0 }
        end
      end

      def valid_recent_actor_events?(entries)
        entries.is_a?(Array) && entries.length <= MAX_NAMESPACE_PATHS &&
          entries.all? do |entry|
            entry.is_a?(Hash) && entry.keys.sort == %w[actor_id occurred_at] &&
              entry["actor_id"].is_a?(String) && entry["actor_id"].bytesize <= 512 &&
              entry["actor_id"].match?(SAFE_LABEL) &&
              Proposals.timestamp!(entry["occurred_at"], label: "proposal rate time")
          rescue InvalidRecord
            false
          end
      end

      def canonical_usage_for_result(result)
        return [ 0, 0 ] unless result.is_a?(Hash)
        kind = result["kind"]
        proposal_id = Proposals.proposal_id!(result["proposal_id"])
        path = case kind
        when "record"
          File.join(root, "records", "#{proposal_id}.json")
        when "event"
          event_id = Proposals.event_id!(result["event_id"])
          Dir.glob(File.join(root, "events", proposal_id, "*-#{event_id}.json")).first
        end
        [ path ? file_size(path) : 0, path ? 1 : 0 ]
      rescue InvalidRecord, InvalidEvent
        [ 0, 0 ]
      end

      def write_index_unlocked(document)
        write_index_bytes_unlocked(encoded_index(document))
      end

      def encoded_index(document)
        bytes = Proposals.canonical(document)
        raise QuotaExceeded, "proposal source index is oversize" if bytes.bytesize > MAX_FILE_BYTES
        bytes
      end

      def write_index_bytes_unlocked(bytes)
        Hive::AtomicFile.write(index_path, bytes, mode: 0o600)
      end

      def read_event_unlocked(source_event_id)
        bytes = read_bytes(event_path(source_event_id), max_bytes: MAX_FILE_BYTES)
        bytes && SourceEvent.new(JSON.parse(bytes))
      rescue JSON::ParserError, InvalidRecord => error
        raise QuarantinedSource, "proposal source receipt is malformed: #{error.class}"
      end

      def read_json(path, max_bytes:)
        bytes = read_bytes(path, max_bytes: max_bytes)
        bytes && JSON.parse(bytes)
      rescue JSON::ParserError
        raise QuarantinedSource, "proposal source state is malformed"
      end

      def read_bytes(path, max_bytes:)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          stat = file.stat
          unless stat.file?
            raise QuarantinedSource, "proposal source path is not a regular file"
          end
          raise QuarantinedSource, "proposal source file is oversize" if stat.size > max_bytes

          bytes = file.read(max_bytes + 1)
          if bytes.bytesize > max_bytes
            raise QuarantinedSource, "proposal source file is oversize"
          end
          bytes
        end
      rescue Errno::ENOENT
        nil
      rescue Errno::ELOOP
        raise QuarantinedSource, "proposal source path is not a regular file"
      end

      def create_immutable(path, bytes)
        ensure_safe_directory!(File.dirname(path))
        Hive::AtomicFile.create(path, bytes, mode: 0o600)
      end

      def with_lock
        ensure_safe_directory!(inbox_root)
        Proposals.with_state_lock(root, timeout: @lock_timeout) { yield }
      end

      def ensure_safe_directory!(path)
        unless path == root || path.start_with?("#{root}/")
          raise Error, "proposal source directory escapes its root"
        end
        FileUtils.mkdir_p(root, mode: 0o700) unless path_exists?(root)
        ensure_one_directory!(root)
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).each_filename.to_a
        current = root
        relative.each do |segment|
          current = File.join(current, segment)
          ensure_one_directory!(current)
        end
      end

      def ensure_one_directory!(path)
        FileUtils.mkdir(path, mode: 0o700) unless path_exists?(path)
        status = File.lstat(path)
        raise Error, "proposal source directory is unsafe" unless status.directory? && !status.symlink?
        File.chmod(0o700, path)
      rescue Errno::EEXIST
        retry
      end

      def path_exists?(path) = File.exist?(path) || File.symlink?(path)

      def file_size(path)
        stat = File.lstat(path)
        stat.file? && !stat.symlink? ? stat.size : 0
      rescue Errno::ENOENT, Errno::ENOTDIR
        0
      end

      def event_path(id) = File.join(inbox_root, "#{id}.json")
      def index_path = File.join(inbox_root, "index.json")
      def status_path(state, id) = File.join(inbox_root, state, "#{id}.json")
    end
  end
end
