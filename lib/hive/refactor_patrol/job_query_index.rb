require "json"
require "securerandom"

module Hive
  module RefactorPatrol
    # Immutable sequence projection for bounded, snapshot-stable job listing.
    # New-job writers reserve membership before the authoritative job write and
    # publish only a contiguous ready prefix afterward. Rebuilds prepare a new
    # generation off to the side and atomically swap the active state last.
    class JobQueryIndex
      class CursorError < ArgumentError; end

      SCHEMA_VERSION = 1
      STATE_SCHEMA = "hive-refactor-patrol-job-query-index".freeze
      ENTRY_SCHEMA = "hive-refactor-patrol-job-query-entry".freeze
      STATE_KEYS = %w[
        schema schema_version generation high_water allocated_high_water
      ].freeze
      ENTRY_KEYS = %w[schema schema_version generation sequence job_id].freeze
      GENERATION_PATTERN = /\A[a-f0-9]{32}\z/

      def initialize(files:, id_pattern:, corrupt_record:,
                     inconsistent_record:, max_entries:)
        @files = files
        @root = File.join("indexes", "job-query")
        @id_pattern = id_pattern
        @corrupt_record = corrupt_record
        @inconsistent_record = inconsistent_record
        @max_entries = Integer(max_entries)
        raise ArgumentError, "job query index capacity must be positive" unless
          @max_entries.positive?
      rescue ArgumentError, TypeError
        raise ArgumentError, "job query index capacity must be positive"
      end

      # The caller holds the per-job lock. This index lock spans reservation,
      # authoritative write, and high-water publication, fencing rebuilds and
      # concurrent registrations around the complete cross-file transaction.
      def with_registration(job_id, existing:, migration_job_ids:)
        id = validate_job_id!(job_id)
        with_lock do
          state = load_state
          if state.nil? && jobs_exist?
            state = rebuild_locked!(migration_job_ids.call)
          end
          state ||= publish_empty_generation!

          pointer = load_pointer(id, state)
          state = recover_unpublished_allocation!(state, pointer) if pointer
          if existing && pointer.nil?
            state = rebuild_locked!(migration_job_ids.call)
            pointer = load_pointer(id, state)
            inconsistent!("existing job is absent from the rebuilt query index", job_path(id)) unless pointer
          end
          unless pointer
            if state.fetch("allocated_high_water") >= @max_entries &&
               state.fetch("high_water") <
                 state.fetch("allocated_high_water")
              state = rebuild_locked!(migration_job_ids.call)
              pointer = load_pointer(id, state)
            end
          end
          unless pointer
            inconsistent!(
              "job query index capacity is exhausted",
              state_path
            ) if state.fetch("allocated_high_water") >= @max_entries
            sequence = state.fetch("allocated_high_water") + 1
            write_membership!(state, sequence, id)
            state["allocated_high_water"] = sequence
            write_state(state)
          end

          result = yield
          unless @files.job_exists?(id)
            inconsistent!("job query membership was not followed by its authoritative job", job_path(id))
          end
          publish_ready_prefix!(state)
          result
        end
      end

      # Explicit writer-side recovery. The authoritative scan executes under
      # the same lock as registrations, and the supplied order is preserved.
      def rebuild!
        with_lock { rebuild_locked!(yield) }
      end

      # Read-only bounded page. Only limit+1 sidecars and the selected full jobs
      # are opened; no scan, repair, lock creation, or index write is permitted.
      def page(limit:, cursor: nil)
        page_limit = Integer(limit)
        raise ArgumentError, "job query page limit must be positive" unless page_limit.positive?

        state = load_state
        return empty_page if state.nil? && cursor.nil? && !jobs_exist?
        corrupt!("job query index is missing", state_path) unless state

        after, through = cursor_bounds(cursor, state)
        last = [ after + page_limit + 1, through ].min
        memberships = if after < through
          ((after + 1)..last).map do |sequence|
            entry = read_json(entry_path(state.fetch("generation"), sequence))
            validate_entry!(entry, sequence, state.fetch("generation"))
            unless @files.job_exists?(entry.fetch("job_id"))
              inconsistent!("job query index references a missing job", job_path(entry.fetch("job_id")))
            end
            entry
          end
        else
          []
        end
        has_more = memberships.size > page_limit
        selected = memberships.first(page_limit)
        next_after = selected.empty? ? after : selected.last.fetch("sequence")
        {
          "generation" => state.fetch("generation"),
          "after_sequence" => after,
          "through_sequence" => through,
          "next_after_sequence" => next_after,
          "total" => through,
          "has_more" => has_more,
          "job_ids" => selected.map { |entry| entry.fetch("job_id") }
        }
      end

      private

      def rebuild_locked!(job_ids)
        seen = {}
        ids = []
        Array(job_ids).each do |job_id|
          id = validate_job_id!(job_id)
          next if seen[id]

          seen[id] = true
          ids << id
          inconsistent!(
            "job query index capacity is exhausted",
            state_path
          ) if ids.size > @max_entries
        end
        state = initial_state
        ids.each_with_index do |id, index|
          unless @files.job_exists?(id)
            inconsistent!("job query index cannot reference a missing job", job_path(id))
          end
          write_membership!(state, index + 1, id)
        end
        state["high_water"] = ids.size
        state["allocated_high_water"] = ids.size
        write_state(state)
        state
      end

      def publish_empty_generation!
        state = initial_state
        write_state(state)
        state
      end

      def publish_ready_prefix!(state)
        changed = false
        while state.fetch("high_water") < state.fetch("allocated_high_water")
          sequence = state.fetch("high_water") + 1
          entry = read_json(entry_path(state.fetch("generation"), sequence))
          validate_entry!(entry, sequence, state.fetch("generation"))
          break unless @files.job_exists?(entry.fetch("job_id"))

          state["high_water"] = sequence
          changed = true
        end
        write_state(state) if changed
        state
      end

      def write_membership!(state, sequence, job_id)
        payload = entry_payload(state, sequence, job_id)
        write_immutable(entry_path(state.fetch("generation"), sequence), payload)
        write_immutable(pointer_path(state.fetch("generation"), job_id), payload)
      end

      def entry_payload(state, sequence, job_id)
        {
          "schema" => ENTRY_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "generation" => state.fetch("generation"),
          "sequence" => sequence,
          "job_id" => job_id
        }
      end

      def load_pointer(job_id, state)
        path = pointer_path(state.fetch("generation"), job_id)
        return nil unless @files.regular?(path)

        payload = read_json(path)
        validate_entry!(
          payload, payload["sequence"], state.fetch("generation"), job_id
        )
        entry = read_json(entry_path(state.fetch("generation"), payload.fetch("sequence")))
        validate_entry!(entry, payload.fetch("sequence"), state.fetch("generation"), job_id)
        inconsistent!("job query index membership sidecars disagree", path) unless entry == payload
        payload
      end

      # Membership is intentionally durable before the allocation state. If a
      # process dies in that narrow window, the exact job retry adopts only the
      # next contiguous, cross-validated sidecar pair before writing the job.
      def recover_unpublished_allocation!(state, pointer)
        sequence = pointer.fetch("sequence")
        return state if sequence <= state.fetch("allocated_high_water")
        unless sequence == state.fetch("allocated_high_water") + 1
          inconsistent!("job query index has a non-contiguous unpublished allocation", state_path)
        end

        state["allocated_high_water"] = sequence
        write_state(state)
        state
      end

      def validate_entry!(entry, sequence, generation, expected_job_id = nil)
        valid = entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS.sort &&
                entry["schema"] == ENTRY_SCHEMA && entry["schema_version"] == SCHEMA_VERSION &&
                entry["generation"] == generation && entry["sequence"] == sequence &&
                sequence.is_a?(Integer) &&
                sequence.between?(1, @max_entries) &&
                entry["job_id"].is_a?(String) && entry["job_id"].match?(@id_pattern) &&
                (!expected_job_id || entry["job_id"] == expected_job_id)
        path = sequence.is_a?(Integer) ? entry_path(generation, sequence) : @root
        corrupt!("job query index entry is invalid", path) unless valid
        entry
      end

      def cursor_bounds(cursor, state)
        return [ 0, state.fetch("high_water") ] unless cursor
        unless cursor.is_a?(Hash) && cursor.keys.sort == %w[after_sequence generation through_sequence] &&
               cursor["generation"] == state.fetch("generation") &&
               cursor["after_sequence"].is_a?(Integer) &&
               cursor["through_sequence"].is_a?(Integer)
          raise CursorError, "cursor does not match the current job index"
        end
        after = cursor.fetch("after_sequence")
        through = cursor.fetch("through_sequence")
        unless after >= 0 && through >= after && through <= state.fetch("high_water")
          raise CursorError, "cursor sequence bounds are invalid"
        end
        [ after, through ]
      end

      def empty_page
        {
          "generation" => nil,
          "after_sequence" => 0,
          "through_sequence" => 0,
          "next_after_sequence" => 0,
          "total" => 0,
          "has_more" => false,
          "job_ids" => []
        }
      end

      def initial_state
        {
          "schema" => STATE_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "generation" => SecureRandom.hex(16),
          "high_water" => 0,
          "allocated_high_water" => 0
        }
      end

      def load_state
        state = read_json(state_path, missing: true)
        return nil unless state
        valid = state.is_a?(Hash) && state.keys.sort == STATE_KEYS.sort &&
                state["schema"] == STATE_SCHEMA && state["schema_version"] == SCHEMA_VERSION &&
                state["generation"].to_s.match?(GENERATION_PATTERN) &&
                state["high_water"].is_a?(Integer) && state["high_water"] >= 0 &&
                state["allocated_high_water"].is_a?(Integer) &&
                state["allocated_high_water"] >= state["high_water"] &&
                state["allocated_high_water"] <= @max_entries
        corrupt!("job query index high-water is invalid", state_path) unless valid
        state
      end

      def write_state(state)
        write_json(state_path, state)
      end

      def write_immutable(path, payload)
        if @files.regular?(path)
          existing = read_json(path)
          inconsistent!("job query index membership is immutable", path) unless existing == payload
          return path
        end
        write_json(path, payload)
      end

      def write_json(path, payload)
        @files.write_json(path, payload)
      end

      def read_json(path, missing: false)
        @files.read_json(path, missing: missing)
      rescue JSON::ParserError, EncodingError, SystemCallError, IOError => e
        corrupt!("cannot read job query index (#{e.class}: #{e.message})", path)
      end

      def with_lock
        @files.directory.with_lock(lock_path) { yield }
      end

      def validate_job_id!(job_id)
        id = job_id.to_s
        inconsistent!("job query index job id is invalid", @root) unless id.match?(@id_pattern)
        id
      end

      def jobs_exist?
        @files.each_job_id.any?
      end

      def corrupt!(message, path)
        raise @corrupt_record.new(
          message,
          path: @files.absolute_path(path)
        )
      end

      def inconsistent!(message, path)
        raise @inconsistent_record.new(
          message,
          path: @files.absolute_path(path)
        )
      end

      def state_path = File.join(@root, "active.json")
      def lock_path = File.join(@root, "index.lock")
      def generation_dir(generation) = File.join(@root, "generations", generation)
      def entries_dir(generation) = File.join(generation_dir(generation), "entries")
      def pointers_dir(generation) = File.join(generation_dir(generation), "by-job")
      def entry_path(generation, sequence) = File.join(entries_dir(generation), format("%020d.json", sequence))
      def pointer_path(generation, job_id) = File.join(pointers_dir(generation), "#{job_id}.json")
      def job_path(job_id) = File.join("jobs", "#{job_id}.json")
    end
  end
end
