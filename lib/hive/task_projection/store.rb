require "digest"
require "json"
require "hive/atomic_file"
require "hive/attempts/store"
require "hive/paths"
require "hive/task_projection"
require "hive/task_journal"
require "hive/task_workspace/limits"
require "hive/workflows"

module Hive
  class TaskProjection
    class Store
      SNAPSHOT_BASENAME = "task-projection.json".freeze
      CHECKPOINT_BASENAME = "task-projection.checkpoint.json".freeze
      CHECKPOINT_SCHEMA = "hive-task-projection-checkpoint".freeze
      CHECKPOINT_SCHEMA_VERSION = 1
      CHECKPOINT_ANCHOR_BYTES = 4 * 1024
      PRISTINE_FORBIDDEN_ENTRIES = %w[
        .lock closure.json handoff.yml patrol-fix-worktree.json worktree.yml
      ].freeze

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

        def current?
          state == "current" || state == "pristine"
        end

        def repair_required?
          state == "repair_required"
        end
      end

      RepairResult = Data.define(:projection, :bounded)

      def self.pristine_task?(task, marker, held_task_lock: false)
        return false unless task.respond_to?(:workflow) && task.respond_to?(:stage_index) &&
                            task.respond_to?(:stage_name) && task.respond_to?(:folder) &&
                            task.respond_to?(:log_dir)

        workflow = task.workflow
        return false unless workflow && workflow.respond_to?(:stages)

        first_stage = workflow.stages.first
        return false unless first_stage &&
                            first_stage.dir == "#{task.stage_index}-#{task.stage_name}"

        workflow_id = workflow.id if workflow.respond_to?(:id)
        expected_marker = if Hive::Workflows.coding_id?(workflow_id) ||
                             first_stage.kind == :human
          :waiting
        else
          :none
        end
        return false unless marker.name == expected_marker
        PRISTINE_FORBIDDEN_ENTRIES.each do |basename|
          next if basename == ".lock" && held_task_lock

          begin
            File.lstat(File.join(task.folder, basename))
            return false
          rescue Errno::ENOENT
            nil
          end
        end

        log_stat = begin
          File.lstat(task.log_dir)
        rescue Errno::ENOENT
          nil
        end
        return true unless log_stat
        return false unless log_stat.directory? && !log_stat.symlink?

        Dir.empty?(task.log_dir)
      rescue SystemCallError, IOError
        false
      end

      # Counts exact predecessor point reads while the bounded journal suffix
      # is validated. Primary attempt IDs are collected from the checkpoint and
      # suffix before replay, so an attempt referenced by a journal event never
      # consumes the separate predecessor budget.
      class BoundedAttemptStore
        attr_reader :failure

        def initialize(store:, primary_attempt_ids:, predecessor_limit:)
          @store = store
          @primary_attempt_ids = primary_attempt_ids.to_h { |attempt_id| [ attempt_id, true ] }
          @predecessor_limit = predecessor_limit
          @predecessor_ids = {}
          @failure = nil
        end

        def fetch(attempt_id)
          bounded_fetch(attempt_id, preferred_method: :fetch)
        end

        def fetch_projection_binding(attempt_id)
          bounded_fetch(attempt_id, preferred_method: :fetch_projection_binding)
        end

        private

        def bounded_fetch(attempt_id, preferred_method:)
          id = attempt_id.to_s
          unless @primary_attempt_ids[id] || @predecessor_ids[id]
            if @predecessor_ids.length >= @predecessor_limit
              @failure ||= {
                "reason" => "predecessor_fetches_exhausted",
                "details" => {
                  "cap" => "predecessor_fetches",
                  "observed_count" => @predecessor_ids.length + 1,
                  "limit" => @predecessor_limit
                }
              }
              return nil
            end
            @predecessor_ids[id] = true
          end

          method = if preferred_method == :fetch_projection_binding &&
                      @store.respond_to?(:fetch_projection_binding)
            preferred_method
          else
            :fetch
          end
          @store.public_send(method, attempt_id)
        end
      end
      private_constant :BoundedAttemptStore

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

      # Routine daemon consumers require a valid checkpoint. Unlike the
      # single-task workspace reader, this API never reconstructs a projection
      # from the complete journal when the checkpoint is unavailable.
      def read_routine(marker: nil, pristine: false,
                       limits: Hive::TaskWorkspace::Limits.new)
        result = read_bounded(
          marker: marker, limits: limits,
          require_checkpoint: true, pristine: pristine
        )
        return result if result.current?

        reclassify_bounded_read(result, state: "repair_required")
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

      # Canonical task creators publish a zero-history checkpoint before the
      # task becomes visible. This is not a repair path: any pre-existing
      # journal or derived projection is refused, leaving historical tasks to
      # the explicit exact-task repair command.
      def initialize_pristine!(marker: nil,
                               limits: Hive::TaskWorkspace::Limits.new)
        with_journal_write_lock do
          existing = [ journal_path, snapshot_path, checkpoint_path ].select do |path|
            path_entry?(path)
          end
          unless existing.empty?
            raise Hive::TaskProjection::InvalidJournal,
                  "pristine projection initialization requires empty task projection storage"
          end

          publish_zero_history!(marker: marker, limits: limits).projection
        end
      end

      # Explicit exact-task repair owns the only routine-external full replay.
      # The exclusive journal lock prevents a concurrent append from binding
      # the new derived files to two different authoritative cursors.
      def repair!(marker: nil, limits: Hive::TaskWorkspace::Limits.new,
                  pristine: false, historical_zero_history: false)
        with_journal_write_lock do
          stat = begin
            File.lstat(journal_path)
          rescue Errno::ENOENT
            nil
          end
          return publish_zero_history!(marker: marker, limits: limits) if
            stat.nil? && pristine
          if stat.nil? && historical_zero_history &&
             zero_history_storage?("checkpoint_missing")
            ensure_journal_after_handoff!(snapshot: nil, marker: marker, bytes: "")
            return publish_zero_history!(marker: marker, limits: limits)
          end
          unless stat && stat.file? && !stat.symlink? && stat.size.positive?
            raise Hive::TaskProjection::InvalidJournal,
                  "authoritative task journal is missing, empty, or not a regular file"
          end
          projection = rebuild!(marker: marker)
          bounded = read_bounded_unlocked(
            marker: marker, limits: limits, require_checkpoint: true, pristine: false
          )
          RepairResult.new(projection: projection, bounded: bounded)
        end
      end

      # Workspace reads use a separately bounded checkpoint and only replay
      # the append-only suffix. The lifecycle-facing #read and #rebuild!
      # methods intentionally retain their historical behavior.
      def read_bounded(marker: nil, limits: Hive::TaskWorkspace::Limits.new,
                       snapshot_max_bytes: nil, journal_suffix_max_bytes: nil,
                       journal_event_limit: nil, require_checkpoint: false,
                       pristine: false)
        snapshot_limit = snapshot_max_bytes || limits.fetch(:projection_snapshot_bytes)
        with_journal_read_lock do
          read_bounded_unlocked(
            marker: marker, limits: limits,
            snapshot_max_bytes: snapshot_max_bytes,
            journal_suffix_max_bytes: journal_suffix_max_bytes,
            journal_event_limit: journal_event_limit,
            require_checkpoint: require_checkpoint, pristine: pristine
          )
        end
      rescue Hive::TaskProjection::RoutineLockInvalid => e
        degraded_bounded_read(
          reason: "journal_lock_invalid", state: "repair_required", error: e,
          snapshot_limit: snapshot_limit
        )
      rescue Hive::TaskProjection::RoutineLockUnavailable => e
        degraded_bounded_read(
          reason: "journal_lock_busy", state: "partial", error: e,
          snapshot_limit: snapshot_limit
        )
      rescue Hive::TaskProjection::Error, Hive::TaskJournal::Error,
             JSON::ParserError, KeyError, TypeError, ArgumentError,
             SystemCallError, IOError => e
        degraded_bounded_read(
          reason: "bounded_projection_failed", state: "partial", error: e,
          snapshot_limit: snapshot_limit
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

      def publish_zero_history!(marker:, limits:)
        binding = journal_binding("")
        projection = replay(binding, marker: marker)
        publish(projection)
        publish_checkpoint(binding: binding, bytes: "", projection: projection)
        bounded = read_bounded_unlocked(
          marker: marker, limits: limits, require_checkpoint: true,
          pristine: false
        )
        unless bounded.current?
          reason = bounded.diagnostics.first&.fetch("reason", bounded.state) ||
                   bounded.state
          raise Hive::TaskProjection::InvalidJournal,
                "zero-history projection publication did not produce a current checkpoint (#{reason})"
        end

        RepairResult.new(projection: projection, bounded: bounded)
      end

      def read_bounded_unlocked(marker:, limits:, snapshot_max_bytes: nil,
                                journal_suffix_max_bytes: nil,
                                journal_event_limit: nil,
                                require_checkpoint:, pristine:)
        snapshot_limit = snapshot_max_bytes || limits.fetch(:projection_snapshot_bytes)
        suffix_limit = journal_suffix_max_bytes || limits.fetch(:journal_suffix_bytes)
        event_limit = journal_event_limit || limits.fetch(:journal_events)
        attempt_limit = limits.fetch(:attempt_ids)
        predecessor_limit = limits.fetch(:predecessor_fetches)
        checkpoint = read_checkpoint(snapshot_limit)
        unless checkpoint.fetch("valid")
          if require_checkpoint
            return pristine_bounded_read(marker: marker) if
              pristine && zero_history_storage?(checkpoint.fetch("reason"))

            return degraded_bounded_read(
              reason: checkpoint.fetch("reason"), state: "repair_required",
              snapshot_limit: snapshot_limit
            )
          end

          return read_without_checkpoint(
            marker: marker, suffix_limit: suffix_limit, event_limit: event_limit,
            snapshot_limit: snapshot_limit, checkpoint_reason: checkpoint.fetch("reason")
          )
        end

        read_from_checkpoint(
          checkpoint.fetch("document"), marker: marker,
          suffix_limit: suffix_limit, event_limit: event_limit,
          attempt_limit: attempt_limit, predecessor_limit: predecessor_limit
        )
      end

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

      def read_from_checkpoint(checkpoint, marker:, suffix_limit:, event_limit:,
                               attempt_limit:, predecessor_limit:)
        journal = checkpoint.fetch("journal")
        cursor = Integer(journal.fetch("cursor"))
        snapshot = checkpoint.fetch("snapshot")
        base_projection = Hive::TaskProjection.from_data(snapshot)
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
        suffix_attempt_ids, event_count = journal_summary(suffix)
        attempt_ids = (checkpoint_attempt_ids(snapshot) + suffix_attempt_ids).uniq
        budget_failure = attempt_budget_failure(
          attempt_ids, attempt_limit: attempt_limit
        )
        if budget_failure
          return degraded_from_projection(
            base_projection, reason: budget_failure.fetch("reason"), state: "partial",
            cursor: cursor, truncated: true, details: budget_failure.fetch("details")
          )
        end
        attempts = refreshed_attempt_bindings(snapshot)
        raise Hive::TaskProjection::InvalidJournal, "checkpoint attempt bindings are unavailable" unless attempts
        if suffix.empty? && attempts == snapshot.dig("journal", "attempts")
          projection = marker ? base_projection.with_marker(marker) : base_projection
          return BoundedRead.new(
            projection: projection, state: "current", diagnostics: [],
            truncated: false, journal_cursor: current_size, journal_records: []
          )
        end
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

        bounded_attempt_store = BoundedAttemptStore.new(
          store: @attempt_store,
          primary_attempt_ids: attempt_ids,
          predecessor_limit: predecessor_limit
        )
        replayed_records = if suffix.empty?
          []
        else
          begin
            Hive::TaskProjection.replay_journal(
              suffix, attempt_store: bounded_attempt_store
            ).records
          rescue Hive::TaskProjection::InvalidJournal
            raise unless bounded_attempt_store.failure

            return degraded_from_projection(
              base_projection,
              reason: bounded_attempt_store.failure.fetch("reason"), state: "partial",
              cursor: cursor, truncated: true,
              details: bounded_attempt_store.failure.fetch("details")
            )
          end
        end
        records = checkpoint_seed_records(base_projection, attempts: attempts) + replayed_records
        projection = @projector.project(
          records: records,
          cursor: current_size,
          # The exact full-file digest belongs to the checkpoint at its
          # cursor. A suffix replay does not fabricate a replacement digest.
          journal_hash: suffix.empty? ? journal["hash"] : nil,
          marker: marker
        )
        projection_data = projection.to_h
        projection_data["journal"]["event_id"] = snapshot.dig("journal", "event_id") if
          suffix.empty?
        projection_data["provenance"]["authoritative_event_count"] =
          base_projection.to_h.dig("provenance", "authoritative_event_count").to_i +
          replayed_records.length
        projection_data["provenance"]["legacy_event_count"] =
          base_projection.to_h.dig("provenance", "legacy_event_count").to_i
        projection = Hive::TaskProjection.from_data(projection_data)
        BoundedRead.new(
          projection: projection, state: "current", diagnostics: [],
          truncated: false, journal_cursor: current_size,
          journal_records: replayed_records.map do |record|
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
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        File.open(journal_path, flags) do |io|
          stat = io.stat
          return false unless stat.file? && stat.size >= cursor &&
            stat.dev == path_stat.dev && stat.ino == path_stat.ino
          return false unless journal["device"].nil? || stat.dev == journal["device"]
          return false unless journal["inode"].nil? || stat.ino == journal["inode"]
          if stat.size == cursor
            checkpoint_stat = File.lstat(checkpoint_path)
            return false unless checkpoint_stat.file? && !checkpoint_stat.symlink?
            return false unless stat.mtime <= checkpoint_stat.mtime
            return false unless stat.ctime <= checkpoint_stat.ctime
          end

          head = io.pread([ cursor, CHECKPOINT_ANCHOR_BYTES ].min, 0).to_s
          tail_offset = [ cursor - CHECKPOINT_ANCHOR_BYTES, 0 ].max
          tail = io.pread(cursor - tail_offset, tail_offset).to_s
          ::Digest::SHA256.hexdigest(head) == journal["head_hash"] &&
            ::Digest::SHA256.hexdigest(tail) == journal["tail_hash"]
        end
      rescue Errno::ENOENT
        empty_hash = ::Digest::SHA256.hexdigest("")
        cursor.zero? && journal["device"].nil? && journal["inode"].nil? &&
          journal["hash"] == empty_hash && journal["head_hash"] == empty_hash &&
          journal["tail_hash"] == empty_hash
      rescue SystemCallError, IOError
        false
      end

      def checkpoint_seed_records(projection, attempts: nil)
        data = projection.to_h
        attempts ||= Array(data.dig("journal", "attempts"))
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
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
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
      rescue Errno::ENOENT
        raise unless cursor.zero?

        [ "", 0, false ]
      end

      def degraded_from_projection(projection, reason:, state:, cursor:, truncated: false, details: {})
        BoundedRead.new(
          projection: projection, state: state,
          diagnostics: [ bounded_diagnostic(reason, details) ],
          truncated: truncated, journal_cursor: cursor, journal_records: []
        )
      end

      def reclassify_bounded_read(read, state:)
        BoundedRead.new(
          projection: read.projection, state: state,
          diagnostics: read.diagnostics, truncated: read.truncated,
          journal_cursor: read.journal_cursor, journal_records: read.journal_records
        )
      end

      def pristine_bounded_read(marker:)
        projection = @projector.project(
          records: [], cursor: 0, journal_hash: ::Digest::SHA256.hexdigest(""), marker: marker
        )
        BoundedRead.new(
          projection: projection, state: "pristine", diagnostics: [],
          truncated: false, journal_cursor: 0, journal_records: []
        )
      end

      def zero_history_storage?(checkpoint_reason)
        checkpoint_reason == "checkpoint_missing" &&
          !path_entry?(journal_path) && !path_entry?(snapshot_path) &&
          !path_entry?(checkpoint_path)
      end

      def path_entry?(path)
        File.lstat(path)
        true
      rescue Errno::ENOENT
        false
      end

      def attempt_budget_failure(attempt_ids, attempt_limit:)
        if attempt_ids.length > attempt_limit
          {
            "reason" => "attempt_ids_exhausted",
            "details" => {
              "cap" => "attempt_ids", "observed_count" => attempt_ids.length,
              "limit" => attempt_limit
            }
          }
        end
      end

      def checkpoint_attempt_ids(snapshot)
        Array(snapshot.dig("journal", "attempts")).filter_map do |binding|
          next unless binding.is_a?(Hash)

          attempt_id = binding["attempt_id"].to_s
          attempt_id unless attempt_id.empty?
        end
      end

      def journal_summary(bytes)
        attempt_ids = {}
        event_count = 0
        bytes.each_line do |line|
          next if line.strip.empty?

          event_count += 1
          record = JSON.parse(line)
          next unless record.is_a?(Hash)

          attempt_id = record["attempt_id"].to_s
          attempt_ids[attempt_id] = true unless attempt_id.empty?
        end
        [ attempt_ids.keys, event_count ]
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
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
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
        path_stat = File.lstat(lock_path)
        unless path_stat.file? && !path_stat.symlink?
          raise Hive::TaskProjection::RoutineLockInvalid,
                "task journal lock is not a regular file"
        end
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        lock = File.open(lock_path, flags)
      rescue Errno::ENOENT
        yield
      else
        begin
          opened = lock.stat
          unless opened.file? && opened.dev == path_stat.dev && opened.ino == path_stat.ino
            raise Hive::TaskProjection::RoutineLockInvalid,
                  "task journal lock descriptor changed"
          end
          unless lock.flock(File::LOCK_SH | File::LOCK_NB)
            raise Hive::TaskProjection::RoutineLockUnavailable,
                  "task journal lock is busy"
          end
          yield
        ensure
          lock&.flock(File::LOCK_UN)
          lock&.close
        end
      end

      def with_journal_write_lock
        lock_path = File.join(task_folder, Hive::TaskJournal::LOCK_BASENAME)
        path_stat = begin
          File.lstat(lock_path)
        rescue Errno::ENOENT
          nil
        end
        if path_stat && (!path_stat.file? || path_stat.symlink?)
          raise Hive::TaskProjection::InvalidJournal,
                "task journal lock is not a regular file"
        end
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        flags |= File::NONBLOCK if defined?(File::NONBLOCK)
        File.open(lock_path, flags, 0o644) do |lock|
          opened = lock.stat
          unless opened.file? && (!path_stat ||
            (opened.dev == path_stat.dev && opened.ino == path_stat.ino))
            raise Hive::TaskProjection::InvalidJournal,
                  "task journal lock descriptor changed"
          end
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Hive::TaskProjection::InvalidJournal,
                  "task journal lock is busy; retry the exact-task repair"
          end
          yield
        ensure
          lock&.flock(File::LOCK_UN)
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

        refreshed = refreshed_attempt_bindings(snapshot)
        refreshed && bindings.zip(refreshed).all? do |expected, current|
          expected.values_at("state", "outcome", "lease_version") ==
            current.values_at("state", "outcome", "lease_version")
        end
      end

      def refreshed_attempt_bindings(snapshot)
        bindings = snapshot.dig("journal", "attempts")
        return nil unless bindings.is_a?(Array)
        return [] if bindings.empty?
        return nil unless @attempt_store

        bindings.map do |binding|
          return nil unless binding.is_a?(Hash)
          next binding if Hive::Attempts::Record::FINAL_STATES.include?(binding["state"])

          attempt = fetch_attempt_binding(binding["attempt_id"])
          return nil unless attempt

          current = Hive::TaskProjection.durable_attempt_metadata(attempt)
          return nil unless same_attempt_identity?(binding, current)

          current
        end
      rescue Hive::Error, SystemCallError, IOError
        nil
      end

      def same_attempt_identity?(expected, current)
        expected_task = expected["task"]
        current_task = current["task"]
        expected_task.is_a?(Hash) && current_task.is_a?(Hash) &&
          expected["attempt_id"] == current["attempt_id"] &&
          expected_task["slug"] == current_task["slug"] &&
          (expected_task["id"].nil? || expected_task["id"].to_s == current_task["id"].to_s) &&
          expected["stage"] == current["stage"] &&
          expected["task_generation"] == current["task_generation"] &&
          (expected["ownership_generation"].nil? ||
           expected["ownership_generation"] == current["ownership_generation"]) &&
          expected["accepted_at"] == current["accepted_at"] &&
          expected["predecessor_attempt_id"] == current["predecessor_attempt_id"]
      end

      def fetch_attempt_binding(attempt_id)
        if @attempt_store.respond_to?(:fetch_projection_binding)
          @attempt_store.fetch_projection_binding(attempt_id)
        else
          @attempt_store.fetch(attempt_id)
        end
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
        Hive::Attempts::Store.runtime(create_directories: false)
      end
    end
  end
end
