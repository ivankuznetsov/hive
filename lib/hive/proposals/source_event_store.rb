require "fileutils"
require "json"
require "time"
require "tmpdir"
require "hive/atomic_file"
require "hive/proposals/source_event"

module Hive
  module Proposals
    class SourceEventStore
      INDEX_SCHEMA = "hive-proposal-source-index".freeze
      STATUS_SCHEMA = "hive-proposal-source-status".freeze
      MAX_FILE_BYTES = 256 * 1024
      DEFAULT_LIMITS = {
        "max_pending_sources" => 256,
        "max_project_events" => 10_000,
        "max_proposal_events" => 1_000,
        "max_project_bytes" => 64 * 1024 * 1024,
        "max_proposal_bytes" => 8 * 1024 * 1024,
        "max_sources_per_actor_per_hour" => 100
      }.freeze

      attr_reader :root, :inbox_root

      def initialize(root:, limits: {}, clock: -> { Time.now.utc })
        @root = File.expand_path(root)
        @inbox_root = File.join(@root, "inbox")
        @limits = DEFAULT_LIMITS.merge(Proposals.stringify(limits || {}))
        @clock = clock
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
          current = read_index_unlocked
          enforce_quotas!(current, event, bytes.bytesize)
          create_immutable(event_path(event.source_event_id), bytes)
          current["pending"] << event.source_event_id
          current["pending"].sort!
          current["pending_proposals"][event.source_event_id] = event.proposal_id
          current["total_sources"] += 1
          current["total_bytes"] += bytes.bytesize
          usage = current["proposal_usage"][event.proposal_id] ||= { "sources" => 0, "bytes" => 0 }
          usage["sources"] += 1
          usage["bytes"] += bytes.bytesize
          current["recent_admissions"] = retained_admissions(current).push(
            "actor_id" => event.to_h.dig("actor", "id"),
            "at" => Proposals.timestamp!(@clock.call, label: "source admission time")
          )
          write_index_unlocked(current)
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

          document = {
            "schema" => STATUS_SCHEMA, "schema_version" => 1,
            "source_event_id" => id, "state" => state,
            "result" => result, "reason" => reason,
            "recorded_at" => Proposals.timestamp!(@clock.call, label: "source status time")
          }
          bytes = Proposals.canonical(document)
          proposal_id = current["pending_proposals"].fetch(id, nil)
          enforce_terminal_bytes!(current, proposal_id, bytes.bytesize)
          create_immutable(status_path(state, id), bytes)
          current["pending"].delete(id)
          current["pending_proposals"].delete(id)
          current["#{state == 'consumed' ? 'consumed' : 'quarantined'}_count"] += 1
          current["total_bytes"] += bytes.bytesize
          current["proposal_usage"][proposal_id]["bytes"] += bytes.bytesize if proposal_id
          write_index_unlocked(current)
          document
        end
      end

      def enforce_quotas!(current, event, bytes)
        if current["pending"].length >= integer_limit("max_pending_sources")
          raise QuotaExceeded, "proposal pending source quota exceeded"
        end
        if current["total_sources"] >= integer_limit("max_project_events")
          raise QuotaExceeded, "proposal project event quota exceeded"
        end
        if current["total_bytes"] + bytes > integer_limit("max_project_bytes")
          raise QuotaExceeded, "proposal project byte quota exceeded"
        end
        usage = current.fetch("proposal_usage").fetch(
          event.proposal_id, { "sources" => 0, "bytes" => 0 }
        )
        if usage.fetch("sources") >= integer_limit("max_proposal_events")
          raise QuotaExceeded, "proposal event quota exceeded"
        end
        if usage.fetch("bytes") + bytes > integer_limit("max_proposal_bytes")
          raise QuotaExceeded, "proposal byte quota exceeded"
        end
        actor = event.to_h.dig("actor", "id")
        count = retained_admissions(current).count { |entry| entry["actor_id"] == actor }
        if count >= integer_limit("max_sources_per_actor_per_hour")
          raise QuotaExceeded, "proposal authority rate limit exceeded"
        end
      end

      def enforce_terminal_bytes!(current, proposal_id, bytes)
        if current["total_bytes"] + bytes > integer_limit("max_project_bytes")
          raise QuotaExceeded, "proposal project byte quota exceeded"
        end
        return unless proposal_id

        usage = current.fetch("proposal_usage").fetch(proposal_id)
        if usage.fetch("bytes") + bytes > integer_limit("max_proposal_bytes")
          raise QuotaExceeded, "proposal byte quota exceeded"
        end
      end

      def retained_admissions(current)
        cutoff = @clock.call - 3_600
        Array(current["recent_admissions"]).select do |entry|
          Time.iso8601(entry.fetch("at")) >= cutoff
        rescue ArgumentError, KeyError
          false
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
          schema schema_version pending consumed_count quarantined_count total_sources total_bytes
          recent_admissions pending_proposals proposal_usage
        ]
        unless document.is_a?(Hash) && document.keys.sort == required.sort &&
               document["schema"] == INDEX_SCHEMA && document["schema_version"] == 1 &&
               document["pending"].is_a?(Array) && document["pending"].uniq == document["pending"] &&
               document["pending"].all? { |id| id.to_s.match?(SOURCE_EVENT_ID) } &&
               valid_usage_index?(document)
          raise QuarantinedSource, "proposal source index is malformed"
        end
        %w[consumed_count quarantined_count total_sources total_bytes].each do |key|
          unless document[key].is_a?(Integer) && document[key] >= 0
            raise QuarantinedSource, "proposal source index counter is malformed"
          end
        end
        document
      end

      def empty_index
        {
          "schema" => INDEX_SCHEMA, "schema_version" => 1, "pending" => [],
          "consumed_count" => 0, "quarantined_count" => 0,
          "total_sources" => 0, "total_bytes" => 0, "recent_admissions" => [],
          "pending_proposals" => {}, "proposal_usage" => {}
        }
      end

      def valid_usage_index?(document)
        pending = document["pending_proposals"]
        usage = document["proposal_usage"]
        return false unless pending.is_a?(Hash) && pending.keys.sort == document["pending"].sort
        return false unless pending.all? do |source_id, proposal_id|
          source_id.match?(SOURCE_EVENT_ID) && proposal_id.match?(PROPOSAL_ID)
        end
        usage.is_a?(Hash) && usage.all? do |proposal_id, counters|
          proposal_id.match?(PROPOSAL_ID) && counters.is_a?(Hash) &&
            counters.keys.sort == %w[bytes sources] &&
            counters.values.all? { |value| value.is_a?(Integer) && value >= 0 }
        end
      end

      def write_index_unlocked(document)
        Hive::AtomicFile.write(index_path, Proposals.canonical(document), mode: 0o600)
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
        stat = File.lstat(path)
        raise QuarantinedSource, "proposal source path is not a regular file" unless stat.file? && !stat.symlink?
        raise QuarantinedSource, "proposal source file is oversize" if stat.size >= max_bytes
        File.binread(path)
      rescue Errno::ENOENT
        nil
      end

      def create_immutable(path, bytes)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        Hive::AtomicFile.create(path, bytes, mode: 0o600)
      end

      def with_lock
        FileUtils.mkdir_p(inbox_root, mode: 0o700)
        lock_path = File.join(
          Dir.tmpdir, "hive-proposal-#{Digest::SHA256.hexdigest(root)}.lock"
        )
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def event_path(id) = File.join(inbox_root, "#{id}.json")
      def index_path = File.join(inbox_root, "index.json")
      def status_path(state, id) = File.join(inbox_root, state, "#{id}.json")
    end
  end
end
