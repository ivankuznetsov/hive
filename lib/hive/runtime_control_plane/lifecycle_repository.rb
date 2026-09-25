require "hive/runtime_control_plane"
require "hive/runtime_control_plane/codec"

module Hive
  module RuntimeControlPlane
    Lifecycle = Data.define(
      :phase, :generation, :revision, :mutation_sequence, :boot_id,
      :deadline_monotonic, :shutdown_grace_sec, :interrupted_attempt_ids,
      :quiesce_started_at, :paused_at, :resumed_at, :updated_at
    ) do
      def admission_open? = phase == "running"
      def paused? = phase == "paused"
      def closed? = !admission_open?
    end

    class LifecycleRepository
      attr_reader :database

      def initialize(database:, clock: -> { Time.now.utc })
        @database = database
        @clock = clock
      end

      def current
        row = database.read { |db| db[:runtime_lifecycle].first }
        raise IntegrityError.new("runtime lifecycle row is missing", code: :lifecycle_missing) unless row
        build(row)
      end

      def ensure_admission_open_in!(db)
        row = db[:runtime_lifecycle].first
        return true if row&.fetch(:phase) == "running"

        raise AdmissionClosed.new(
          "runtime admission is closed while lifecycle is #{row&.fetch(:phase) || 'unknown'}",
          details: { phase: row&.fetch(:phase), generation: row&.fetch(:generation) }
        )
      end

      def begin_quiesce!(deadline_monotonic:, boot_id:, shutdown_grace_sec:, now: @clock.call,
                         timeout_sec: nil)
        existing = current
        return existing if existing.phase == "quiescing"
        unless existing.phase == "running"
          raise StaleLifecycle.new("cannot quiesce while lifecycle is #{existing.phase}")
        end

        mutate(
          expected: existing, from: "running", privileged: false, timeout_sec: timeout_sec
        ) do |row|
          {
            phase: "quiescing", generation: row.fetch(:generation) + 1,
            boot_id: boot_id.to_s, deadline_monotonic: Float(deadline_monotonic),
            shutdown_grace_sec: Float(shutdown_grace_sec),
            interrupted_attempt_ids_json: "[]", quiesce_started_at: dump_time(now),
            paused_at: nil, resumed_at: nil
          }
        end
      rescue AdmissionClosed
        raced = current
        return raced if raced.phase == "quiescing"
        raise
      end

      def mark_paused!(generation:, expected_revision:, interrupted_attempt_ids:, now: @clock.call,
                       authority: nil, timeout_sec: nil)
        expected = current
        validate_expected!(expected, generation: generation, revision: expected_revision,
                           phases: [ "quiescing" ])
        mutate(
          expected: expected, from: "quiescing", authority: authority,
          timeout_sec: timeout_sec
        ) do
          {
            phase: "paused", paused_at: dump_time(now),
            interrupted_attempt_ids_json: Codec.dump_json(Array(interrupted_attempt_ids).map(&:to_s).uniq)
          }
        end
      end

      # A paused row is only a durable candidate until the external
      # finalization proof has been flushed. Checkpoint/proof failure and a
      # retry after a controller crash move that candidate back to quiescing
      # without changing its generation or reopening admission.
      def return_to_quiescing!(generation:, expected_revision:, now: @clock.call,
                               authority: nil, timeout_sec: nil)
        expected = current
        validate_expected!(expected, generation: generation, revision: expected_revision,
                           phases: [ "paused" ])
        mutate(
          expected: expected, from: "paused", authority: authority,
          timeout_sec: timeout_sec
        ) do
          { phase: "quiescing", paused_at: nil, updated_at: dump_time(now) }
        end
      end

      def begin_resume!(generation:, now: @clock.call, authority: nil, timeout_sec: nil)
        expected = current
        validate_expected!(expected, generation: generation, phases: %w[quiescing paused resuming])
        return expected if expected.phase == "resuming"

        mutate(
          expected: expected, from: expected.phase, authority: authority,
          timeout_sec: timeout_sec
        ) do
          { phase: "resuming", resumed_at: dump_time(now), paused_at: nil }
        end
      end

      def reopen!(generation:, expected_revision:, now: @clock.call, authority: nil,
                  timeout_sec: nil)
        expected = current
        validate_expected!(expected, generation: generation, revision: expected_revision,
                           phases: [ "resuming" ])
        mutate(
          expected: expected, from: "resuming", authority: authority,
          timeout_sec: timeout_sec
        ) do
          {
            phase: "running", boot_id: nil, deadline_monotonic: nil,
            shutdown_grace_sec: nil, interrupted_attempt_ids_json: "[]",
            quiesce_started_at: nil, paused_at: nil, resumed_at: dump_time(now)
          }
        end
      end

      private

      def mutate(expected:, from:, privileged: true, authority: nil, timeout_sec: nil)
        operation = lambda do |db|
          row = db[:runtime_lifecycle].where(
            installation_id: installation_id(db), phase: from,
            generation: expected.generation, revision: expected.revision
          )
          updates = yield(row.first).merge(
            revision: Sequel[:revision] + 1, updated_at: dump_time(@clock.call)
          )
          changed = row.update(updates)
          raise StaleLifecycle.new unless changed == 1
          build(db[:runtime_lifecycle].first)
        end

        if privileged
          authority ? database.transaction(
            authority: authority, timeout_sec: timeout_sec, &operation
          ) : database.controller_transaction(timeout_sec: timeout_sec, &operation)
        else
          database.transaction(timeout_sec: timeout_sec, &operation)
        end
      end

      def validate_expected!(state, generation:, revision: nil, phases:)
        valid = state.generation == Integer(generation) && phases.include?(state.phase)
        valid &&= state.revision == Integer(revision) unless revision.nil?
        raise StaleLifecycle.new unless valid
      end

      def installation_id(db) = db[:installations].get(:installation_id)
      def dump_time(value) = Codec.dump_time(value.is_a?(Time) ? value : Time.at(value).utc)

      def build(row)
        Lifecycle.new(
          phase: row.fetch(:phase), generation: row.fetch(:generation),
          revision: row.fetch(:revision), mutation_sequence: row.fetch(:mutation_sequence),
          boot_id: row[:boot_id], deadline_monotonic: row[:deadline_monotonic],
          shutdown_grace_sec: row[:shutdown_grace_sec],
          interrupted_attempt_ids: Codec.load_json(row.fetch(:interrupted_attempt_ids_json)),
          quiesce_started_at: row[:quiesce_started_at], paused_at: row[:paused_at],
          resumed_at: row[:resumed_at], updated_at: row[:updated_at]
        )
      end
    end
  end
end
