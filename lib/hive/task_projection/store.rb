require "digest"
require "json"
require "hive/atomic_file"
require "hive/attempts/store"
require "hive/paths"
require "hive/task_projection"
require "hive/task_journal"
require "hive/task_workspace/limits"

module Hive
  class TaskProjection
    class Store
      SNAPSHOT_BASENAME = "task-projection.json".freeze
      CHECKPOINT_BASENAME = "task-projection.checkpoint.json".freeze
      CHECKPOINT_SCHEMA = "hive-task-projection-checkpoint".freeze
      CHECKPOINT_SCHEMA_VERSION = 1
      CHECKPOINT_ANCHOR_BYTES = 4 * 1024

      BoundedRead = Data.define(
        :projection, :state, :diagnostics, :truncated, :journal_cursor,
        :journal_records
      ) do
        def initialize(projection:, state:, diagnostics:, truncated:, journal_cursor:,
                       journal_records: [])
          super(
            projection: projection,
            state: state.to_s.freeze,
            diagnostics: JSON.parse(JSON.generate(diagnostics), freeze: true),
            truncated: truncated == true,
            journal_cursor: Integer(journal_cursor || 0),
            journal_records: JSON.parse(JSON.generate(journal_records), freeze: true)
          )
        end
      end

      attr_reader :task_folder, :journal_path, :snapshot_path, :checkpoint_path, :attempt_store

      def initialize(task_folder:, projector: Hive::TaskProjection, attempt_store: default_attempt_store)
        @task_folder = File.expand_path(task_folder)
        @journal_path = File.join(@task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
        @snapshot_path = File.join(@task_folder, SNAPSHOT_BASENAME)
        @checkpoint_path = File.join(@task_folder, CHECKPOINT_BASENAME)
        @projector = projector
        @attempt_store = attempt_store
      end

      def read(marker: nil)
        snapshot = read_snapshot
        bytes = journal_bytes
        ensure_journal_after_handoff!(snapshot: snapshot, marker: marker, bytes: bytes)
        quick_binding = {
          "cursor" => bytes.bytesize,
          "hash" => ::Digest::SHA256.hexdigest(bytes),
          "event_id" => snapshot&.dig("journal", "event_id")
        }
        if valid?(snapshot, quick_binding) && attempt_bindings_valid?(snapshot)
          projection = Hive::TaskProjection.from_data(snapshot)
          return marker ? projection.with_marker(marker) : projection
        end

        replay(journal_binding(bytes), marker: marker)
      end

      def rebuild!(marker: nil)
        snapshot = read_snapshot
        bytes = journal_bytes
        ensure_journal_after_handoff!(snapshot: snapshot, marker: marker, bytes: bytes)
        binding = journal_binding(bytes)
        projection = replay(binding, marker: marker)
        publish(projection)
        publish_checkpoint(binding: binding, bytes: bytes, projection: projection)
        projection
      end

      # Workspace reads use a separately bounded checkpoint and only replay
      # the append-only suffix. The lifecycle-facing #read and #rebuild!
      # methods intentionally retain their historical behavior.
      def read_bounded(marker: nil, limits: Hive::TaskWorkspace::Limits.new,
                       snapshot_max_bytes: nil, journal_suffix_max_bytes: nil,
                       journal_event_limit: nil)
        snapshot_limit = snapshot_max_bytes || limits.fetch(:projection_snapshot_bytes)
        suffix_limit = journal_suffix_max_bytes || limits.fetch(:journal_suffix_bytes)
        event_limit = journal_event_limit || limits.fetch(:journal_events)

        with_journal_read_lock do
          checkpoint = read_checkpoint(snapshot_limit)
          return read_without_checkpoint(
            marker: marker, suffix_limit: suffix_limit, event_limit: event_limit,
            snapshot_limit: snapshot_limit, checkpoint_reason: checkpoint.fetch("reason")
          ) unless checkpoint.fetch("valid")

          read_from_checkpoint(
            checkpoint.fetch("document"), marker: marker,
            suffix_limit: suffix_limit, event_limit: event_limit
          )
        end
      rescue Hive::TaskProjection::Error, Hive::TaskJournal::Error,
             JSON::ParserError, KeyError, TypeError, ArgumentError,
             SystemCallError, IOError => e
        degraded_bounded_read(
          reason: "bounded_projection_failed", state: "partial", error: e,
          snapshot_limit: snapshot_limit || Hive::TaskWorkspace::Limits.new.fetch(:projection_snapshot_bytes)
        )
      end

      def publish(projection)
        body = "#{Hive::TaskProjection.canonical_json(projection.to_h)}\n"
        Hive::AtomicFile.write(snapshot_path, body, mode: 0o644)
        Hive::AtomicFile.fsync_directory(task_folder)
        snapshot_path
      end

      def valid?(snapshot, binding = journal_binding)
        return false unless snapshot.is_a?(Hash)
        return false unless snapshot["schema"] == Hive::TaskProjection::SCHEMA
        return false unless snapshot["schema_version"] == Hive::TaskProjection::SCHEMA_VERSION

        journal = snapshot["journal"]
        journal.is_a?(Hash) &&
          journal["cursor"] == binding.fetch("cursor") &&
          journal["hash"] == binding.fetch("hash") &&
          journal["event_id"] == binding.fetch("event_id")
      end

      private

      def publish_checkpoint(binding:, bytes:, projection:)
        stat = File.stat(journal_path) if File.exist?(journal_path)
        cursor = binding.fetch("cursor")
        prefix = bytes.byteslice(0, cursor).to_s
        document = {
          "schema" => CHECKPOINT_SCHEMA,
          "schema_version" => CHECKPOINT_SCHEMA_VERSION,
          "state" => "current",
          "journal" => {
            "cursor" => cursor,
            "hash" => binding.fetch("hash"),
            "event_id" => binding.fetch("event_id"),
            "device" => stat&.dev,
            "inode" => stat&.ino,
            "head_hash" => ::Digest::SHA256.hexdigest(
              prefix.byteslice(0, CHECKPOINT_ANCHOR_BYTES).to_s
            ),
            "tail_hash" => ::Digest::SHA256.hexdigest(
              prefix.byteslice([ cursor - CHECKPOINT_ANCHOR_BYTES, 0 ].max,
                                CHECKPOINT_ANCHOR_BYTES).to_s
            )
          },
          "snapshot" => projection.to_h
        }
        body = "#{Hive::TaskProjection.canonical_json(document)}\n"
        limit = Hive::TaskWorkspace::Limits.new.fetch(:projection_snapshot_bytes)
        if body.bytesize > limit
          document = {
            "schema" => CHECKPOINT_SCHEMA,
            "schema_version" => CHECKPOINT_SCHEMA_VERSION,
            "state" => "oversized",
            "observed_bytes" => body.bytesize,
            "cap" => "projection_snapshot_bytes"
          }
          body = "#{Hive::TaskProjection.canonical_json(document)}\n"
        end
        Hive::AtomicFile.write(checkpoint_path, body, mode: 0o644)
        Hive::AtomicFile.fsync_directory(task_folder)
      rescue SystemCallError, IOError, JSON::GeneratorError
        # A checkpoint is a read optimization, never lifecycle authority.
        nil
      end

      def read_checkpoint(limit)
        document = read_json_descriptor(checkpoint_path, limit)
        unless document["schema"] == CHECKPOINT_SCHEMA &&
               document["schema_version"] == CHECKPOINT_SCHEMA_VERSION
          return { "valid" => false, "reason" => "checkpoint_invalid" }
        end
        return { "valid" => false, "reason" => "checkpoint_oversized" } unless
          document["state"] == "current"
        unless document["snapshot"].is_a?(Hash) && document["journal"].is_a?(Hash)
          return { "valid" => false, "reason" => "checkpoint_invalid" }
        end

        Hive::TaskProjection.from_data(document.fetch("snapshot"))
        { "valid" => true, "document" => document }
      rescue Errno::ENOENT
        { "valid" => false, "reason" => "checkpoint_missing" }
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError,
             Hive::TaskProjection::Error, SystemCallError, IOError
        { "valid" => false, "reason" => "checkpoint_invalid" }
      end

      def read_from_checkpoint(checkpoint, marker:, suffix_limit:, event_limit:)
        journal = checkpoint.fetch("journal")
        cursor = Integer(journal.fetch("cursor"))
        base_projection = Hive::TaskProjection.from_data(checkpoint.fetch("snapshot"))
        return degraded_from_projection(
          base_projection, reason: "checkpoint_prefix_changed", state: "stale", cursor: cursor
        ) unless checkpoint_prefix_valid?(journal, cursor)

        suffix, current_size, over_limit = journal_suffix(cursor, suffix_limit)
        if over_limit
          return degraded_from_projection(
            base_projection, reason: "suffix_limit_exceeded", state: "partial",
            cursor: cursor, truncated: true,
            details: {
              "cap" => "journal_suffix_bytes", "observed_bytes" => current_size - cursor,
              "limit" => suffix_limit
            }
          )
        end
        unless suffix.empty? || suffix.end_with?("\n")
          return degraded_from_projection(
            base_projection, reason: "journal_suffix_torn", state: "partial",
            cursor: cursor
          )
        end
        if suffix.empty?
          projection = marker ? base_projection.with_marker(marker) : base_projection
          return BoundedRead.new(
            projection: projection, state: "current", diagnostics: [],
            truncated: false, journal_cursor: current_size, journal_records: []
          )
        end
        event_count = suffix.lines.count { |line| !line.strip.empty? }
        if event_count > event_limit
          return degraded_from_projection(
            base_projection, reason: "suffix_event_limit_exceeded", state: "partial",
            cursor: cursor, truncated: true,
            details: {
              "cap" => "journal_events", "observed_count" => event_count,
              "limit" => event_limit
            }
          )
        end

        replayed = Hive::TaskProjection.replay_journal(suffix, attempt_store: @attempt_store)
        records = checkpoint_seed_records(base_projection) + replayed.records
        projection = @projector.project(
          records: records,
          cursor: current_size,
          # The exact full-file digest belongs to the checkpoint at its
          # cursor. A suffix replay does not fabricate a replacement digest.
          journal_hash: suffix.empty? ? journal["hash"] : nil,
          marker: marker
        )
        projection_data = projection.to_h
        projection_data["provenance"]["authoritative_event_count"] =
          base_projection.to_h.dig("provenance", "authoritative_event_count").to_i +
          replayed.records.length
        projection_data["provenance"]["legacy_event_count"] =
          base_projection.to_h.dig("provenance", "legacy_event_count").to_i
        projection = Hive::TaskProjection.from_data(projection_data)
        BoundedRead.new(
          projection: projection, state: "current", diagnostics: [],
          truncated: false, journal_cursor: current_size,
          journal_records: replayed.records.map do |record|
            record.reject { |key, _| key.to_s.start_with?("__") }
          end
        )
      end

      def read_without_checkpoint(marker:, suffix_limit:, event_limit:, snapshot_limit:,
                                  checkpoint_reason:)
        size = File.size(journal_path)
        if size > suffix_limit
          return degraded_bounded_read(
            reason: checkpoint_reason, state: "partial", snapshot_limit: snapshot_limit,
            truncated: true,
            details: {
              "cap" => "journal_suffix_bytes", "observed_bytes" => size,
              "limit" => suffix_limit
            }
          )
        end
        bytes = read_binary_descriptor(journal_path, suffix_limit)
        unless bytes.empty? || bytes.end_with?("\n")
          return degraded_bounded_read(
            reason: "journal_suffix_torn", state: "partial", snapshot_limit: snapshot_limit
          )
        end
        count = bytes.lines.count { |line| !line.strip.empty? }
        if count > event_limit
          return degraded_bounded_read(
            reason: "journal_event_limit_exceeded", state: "partial",
            snapshot_limit: snapshot_limit, truncated: true,
            details: { "cap" => "journal_events", "observed_count" => count, "limit" => event_limit }
          )
        end

        binding = journal_binding(bytes)
        projection = replay(binding, marker: marker)
        BoundedRead.new(
          projection: projection, state: "partial",
          diagnostics: [ bounded_diagnostic(checkpoint_reason) ],
          truncated: false, journal_cursor: binding.fetch("cursor"),
          journal_records: binding.fetch("records").map do |record|
            record.reject { |key, _| key.to_s.start_with?("__") }
          end
        )
      rescue Errno::ENOENT
        projection = @projector.project(records: [], cursor: 0,
                                        journal_hash: ::Digest::SHA256.hexdigest(""), marker: marker)
        BoundedRead.new(
          projection: projection, state: "partial",
          diagnostics: [ bounded_diagnostic(checkpoint_reason) ],
          truncated: false, journal_cursor: 0, journal_records: []
        )
      end

      def checkpoint_prefix_valid?(journal, cursor)
        path_stat = File.lstat(journal_path)
        return false unless path_stat.file? && !path_stat.symlink?

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(journal_path, flags) do |io|
          stat = io.stat
          return false unless stat.file? && stat.size >= cursor &&
            stat.dev == path_stat.dev && stat.ino == path_stat.ino
          return false unless journal["device"].nil? || stat.dev == journal["device"]
          return false unless journal["inode"].nil? || stat.ino == journal["inode"]

          head = io.pread([ cursor, CHECKPOINT_ANCHOR_BYTES ].min, 0).to_s
          tail_offset = [ cursor - CHECKPOINT_ANCHOR_BYTES, 0 ].max
          tail = io.pread(cursor - tail_offset, tail_offset).to_s
          ::Digest::SHA256.hexdigest(head) == journal["head_hash"] &&
            ::Digest::SHA256.hexdigest(tail) == journal["tail_hash"]
        end
      rescue SystemCallError, IOError
        false
      end

      def checkpoint_seed_records(projection)
        data = projection.to_h
        attempts = Array(data.dig("journal", "attempts"))
        task = data["task"]
        conditions = (Array(data.dig("conditions", "current")) +
                      Array(data.dig("conditions", "history"))).sort_by do |fact|
          [ fact["transitioned_at"].to_s, fact["event_id"].to_s ]
        end
        records = conditions.filter_map do |fact|
          next if fact["event_id"].nil?

          attempt = attempts.find { |row| row["attempt_id"] == fact["attempt_id"] }
          {
            "schema" => Hive::TaskJournal::Envelope::SCHEMA,
            "schema_version" => Hive::TaskJournal::Envelope::SCHEMA_VERSION,
            "event_id" => fact["event_id"], "event_type" => "condition_observed",
            "occurred_at" => fact["transitioned_at"], "observed_at" => fact["transitioned_at"],
            "task" => task, "stage" => attempt&.dig("stage"),
            "attempt_id" => fact["attempt_id"],
            "task_generation" => fact["task_generation"],
            "ownership_generation" => fact["ownership_generation"],
            "commit_generation" => fact["commit_generation"],
            "reason" => fact["reason"], "evidence" => fact["evidence"],
            "provenance" => fact["provenance"],
            "payload" => fact.fetch("payload", {}).merge(
              "condition" => fact["condition"],
              "state" => fact["original_state"] || fact["state"]
            ),
            "__attempt" => attempt,
            "__attempt_lineage" => attempts
          }
        end
        records.concat(checkpoint_identity_records(data, attempts, task))
        records.concat(checkpoint_operator_records(data, task))
        if data.dig("compatibility", "baseline_present")
          records << checkpoint_envelope(
            data, task, event_id: "checkpoint-legacy-baseline", event_type: "legacy_baseline"
          )
        end
        records
      end

      def checkpoint_identity_records(data, attempts, task)
        identity = data.fetch("implementation_identity", {})
        records = Array(identity["history"]).map do |entry|
          checkpoint_identity_envelope(
            data, attempts, task, entry, "implementation_identity_captured"
          )
        end
        records.concat(identity.fetch("stages", {}).values.map do |entry|
          checkpoint_identity_envelope(
            data, attempts, task, entry, "implementation_stage_resolved"
          )
        end)
        records.concat(Array(identity["fallback_warnings"]).map do |warning|
          checkpoint_envelope(
            data, task, event_id: warning["event_id"],
            event_type: "implementation_identity_fallback",
            generation: warning["generation"], reason: warning["reason"]
          )
        end)
        current_attempt = data.dig("identity", "attempt_id")
        if current_attempt
          records << checkpoint_envelope(
            data, task, event_id: "checkpoint-attempt-#{current_attempt}",
            event_type: "activity_recorded",
            payload: { "activity_kind" => "attempt_admitted" },
            attempt_id: current_attempt
          ).merge("__attempt_lineage" => attempts)
        end
        records
      end

      def checkpoint_identity_envelope(data, attempts, task, entry, event_type)
        payload = entry.reject { |key, _| %w[event_id resolved_attempt].include?(key) }
        checkpoint_envelope(
          data, task, event_id: entry["event_id"], event_type: event_type,
          generation: entry["generation"], attempt_id: entry["resolved_attempt"],
          payload: { "identity" => payload }
        ).merge("__attempt_lineage" => attempts)
      end

      def checkpoint_operator_records(data, task)
        Array(data["condition_overrides"]).map do |entry|
          checkpoint_envelope(
            data, task, event_id: entry["event_id"], event_type: "operator_action",
            generation: entry["task_generation"], attempt_id: entry["attempt_id"],
            reason: entry["reason"], payload: entry.slice(
              "transition", "from_stage", "to_stage", "source_command", "waived_diagnostics"
            )
          )
        end
      end

      def checkpoint_envelope(data, task, event_id:, event_type:, generation: nil,
                              attempt_id: nil, reason: "checkpoint_seed", payload: {})
        {
          "schema" => Hive::TaskJournal::Envelope::SCHEMA,
          "schema_version" => Hive::TaskJournal::Envelope::SCHEMA_VERSION,
          "event_id" => event_id, "event_type" => event_type,
          "occurred_at" => "1970-01-01T00:00:00.000000Z",
          "observed_at" => "1970-01-01T00:00:00.000000Z",
          "task" => task, "stage" => nil,
          "attempt_id" => attempt_id || data.dig("identity", "attempt_id"),
          "task_generation" => generation || data.dig("identity", "task_generation"),
          "commit_generation" => data.dig("identity", "commit_generation"),
          "reason" => reason, "evidence" => [],
          "provenance" => { "source" => "checkpoint" }, "payload" => payload
        }
      end

      def journal_suffix(cursor, limit)
        path_stat = File.lstat(journal_path)
        raise IOError, "journal is not a regular file" unless path_stat.file? && !path_stat.symlink?

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(journal_path, flags) do |io|
          before = io.stat
          raise IOError, "journal descriptor changed" unless
            before.dev == path_stat.dev && before.ino == path_stat.ino
          return [ "", before.size, true ] if before.size < cursor

          suffix = before.size == cursor ? "" : io.pread(limit + 1, cursor).to_s
          after = io.stat
          raise IOError, "journal changed during bounded read" unless
            before.dev == after.dev && before.ino == after.ino && before.size == after.size &&
              before.mtime == after.mtime
          over = suffix.bytesize > limit || before.size - cursor > limit
          [ suffix.byteslice(0, limit).to_s, before.size, over ]
        end
      end

      def degraded_from_projection(projection, reason:, state:, cursor:, truncated: false, details: {})
        BoundedRead.new(
          projection: projection, state: state,
          diagnostics: [ bounded_diagnostic(reason, details) ],
          truncated: truncated, journal_cursor: cursor, journal_records: []
        )
      end

      def degraded_bounded_read(reason:, state:, snapshot_limit:, error: nil,
                                truncated: false, details: {})
        projection = bounded_snapshot_projection(snapshot_limit)
        safe_details = details.dup
        safe_details["error_class"] = error.class.name if error
        BoundedRead.new(
          projection: projection, state: state,
          diagnostics: [ bounded_diagnostic(reason, safe_details) ],
          truncated: truncated,
          journal_cursor: projection&.to_h&.dig("journal", "cursor") || 0,
          journal_records: []
        )
      end

      def bounded_snapshot_projection(limit)
        document = read_json_descriptor(snapshot_path, limit)
        Hive::TaskProjection.from_data(document)
      rescue JSON::ParserError, Hive::TaskProjection::Error, SystemCallError, IOError, ArgumentError
        nil
      end

      def bounded_diagnostic(reason, details = {})
        {
          "source" => "task_projection",
          "reason" => reason.to_s,
          "message" => "bounded task projection is #{reason.to_s.tr('_', ' ')}",
          "details" => details
        }
      end

      def read_json_descriptor(path, limit)
        JSON.parse(read_binary_descriptor(path, limit))
      end

      def read_binary_descriptor(path, limit)
        path_stat = File.lstat(path)
        raise IOError, "source is not a regular file" unless path_stat.file? && !path_stat.symlink?

        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |io|
          before = io.stat
          raise IOError, "source descriptor changed" unless
            before.file? && before.dev == path_stat.dev && before.ino == path_stat.ino
          raise IOError, "source exceeds bounded read limit" if before.size > limit

          bytes = io.read(limit + 1).to_s
          after = io.stat
          raise IOError, "source changed during bounded read" unless
            before.dev == after.dev && before.ino == after.ino && before.size == after.size &&
              before.mtime == after.mtime
          raise IOError, "source exceeds bounded read limit" if bytes.bytesize > limit

          bytes
        end
      end

      def with_journal_read_lock
        lock_path = File.join(task_folder, Hive::TaskJournal::LOCK_BASENAME)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        lock = File.open(lock_path, flags)
      rescue Errno::ENOENT
        yield
      else
        begin
          lock.flock(File::LOCK_SH)
          yield
        ensure
          lock&.flock(File::LOCK_UN)
          lock&.close
        end
      end

      def replay(binding, marker:)
        @projector.project(
          records: binding.fetch("records"),
          cursor: binding.fetch("cursor"), journal_hash: binding.fetch("hash"), marker: marker
        )
      end

      def journal_binding(bytes = journal_bytes)
        if bytes.empty? && !File.exist?(journal_path)
          return {
            "cursor" => 0, "hash" => ::Digest::SHA256.hexdigest(""),
            "event_id" => nil, "records" => []
          }
        end

        replay = Hive::TaskProjection.replay_journal(bytes, attempt_store: @attempt_store)
        {
          "cursor" => replay.cursor,
          "hash" => replay.ledger_hash,
          "event_id" => replay.record_id,
          "records" => replay.records
        }
      end

      def read_snapshot
        JSON.parse(File.binread(snapshot_path))
      rescue Errno::ENOENT, JSON::ParserError, SystemCallError
        nil
      end

      def journal_bytes
        File.binread(journal_path)
      rescue Errno::ENOENT
        ""
      end

      def attempt_bindings_valid?(snapshot)
        bindings = snapshot.dig("journal", "attempts")
        return false unless bindings.is_a?(Array)

        bindings.all? do |binding|
          next false unless binding.is_a?(Hash) && @attempt_store

          attempt = fetch_attempt_binding(binding["attempt_id"])
          task = binding["task"]
          attempt && task.is_a?(Hash) &&
            attempt["task_slug"] == task["slug"] &&
            (task["id"].nil? || attempt["task_id"].to_s == task["id"].to_s) &&
            attempt["intended_stage"] == binding["stage"] &&
            attempt_value(attempt, :task_input_epoch) == binding["task_generation"] &&
            attempt_value(attempt, :state) == binding["state"] &&
            attempt_value(attempt, :outcome) == binding["outcome"] &&
            attempt_value(attempt, :lease_version) == binding["lease_version"] &&
            attempt["accepted_at"] == binding["accepted_at"] &&
            attempt["predecessor_attempt_id"] == binding["predecessor_attempt_id"] &&
            (binding["ownership_generation"].nil? ||
             attempt_value(attempt, :ownership_generation) == binding["ownership_generation"])
        end
      rescue Hive::Error, SystemCallError, IOError
        false
      end

      def fetch_attempt_binding(attempt_id)
        if @attempt_store.respond_to?(:fetch_projection_binding)
          @attempt_store.fetch_projection_binding(attempt_id)
        else
          @attempt_store.fetch(attempt_id)
        end
      end

      def attempt_value(attempt, name)
        attempt.respond_to?(name) ? attempt.public_send(name) : attempt[name.to_s]
      end

      def durable_handoff_snapshot?(snapshot)
        return false unless snapshot.is_a?(Hash)

        ids = [ snapshot.dig("identity", "attempt_id") ] +
              Array(snapshot.dig("journal", "attempts")).filter_map do |binding|
                binding["attempt_id"] if binding.is_a?(Hash)
              end
        ids.any? do |attempt_id|
          !attempt_id.to_s.empty? && attempt_id != Hive::TaskJournal::LEGACY_ATTEMPT_ID
        end
      end

      def durable_handoff_marker?(marker)
        return false unless marker

        name = marker.respond_to?(:name) ? marker.name : marker.fetch("name", nil)
        return false unless name.to_s.start_with?("execute_")

        attrs = marker.respond_to?(:attrs) ? marker.attrs : marker.fetch("attrs", {})
        attempt_id = attrs.to_h["attempt_id"] || attrs.to_h[:attempt_id]
        !attempt_id.to_s.empty? && attempt_id != Hive::TaskJournal::LEGACY_ATTEMPT_ID
      end

      def ensure_journal_after_handoff!(snapshot:, marker:, bytes:)
        return unless bytes.empty?
        return unless durable_handoff_snapshot?(snapshot) || durable_handoff_marker?(marker)

        raise Hive::TaskProjection::InvalidJournal,
              "authoritative task journal is missing or empty after durable handoff"
      end

      def default_attempt_store
        root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
        return Hive::Attempts::Store.new(create_directories: false) if root.empty?

        Hive::Attempts::Store.new(root: root, create_directories: false)
      end
    end
  end
end
