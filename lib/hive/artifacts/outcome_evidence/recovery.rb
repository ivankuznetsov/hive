require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/artifacts/outcome_evidence/document"
require "hive/artifacts/outcome_evidence/proof"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Controller-owned recovery epoch. It advances only after a caller proves
      # it observed the exact immutable blocked package currently presented to
      # the operator. A repeated request for that same blocked digest is
      # idempotent; stale generations and digests fail closed.
      class Recovery
        SCHEMA = "hive-outcome-evidence-recovery".freeze
        VERSION = 1
        MAX_BYTES = 16 * 1024

        def initialize(task:, project:, clock: -> { Time.now.utc })
          @task = task
          @project = project.to_s
          @clock = clock
        end

        def epoch(task_generation:)
          record = read
          return 0 unless record
          unless record.fetch("task_generation") == task_generation.to_s
            return 0
          end

          record.fetch("epoch")
        end

        def advance!(pointer:, task_generation:, expected_generation:,
                     expected_digest:)
          pointer = pointer.to_h.transform_keys(&:to_s)
          generation = valid_digest!(expected_generation, "expected generation")
          digest = valid_digest!(expected_digest, "expected recovery digest")
          unless pointer["status"] == "blocked" &&
                 pointer["generation"].to_s == generation &&
                 pointer["recovery_digest"].to_s == digest
            raise StoreError, "outcome-evidence recovery observation is stale"
          end
          pointer_epoch = Integer(pointer.fetch("recovery_epoch"))
          raise StoreError, "blocked recovery epoch is invalid" if pointer_epoch.negative?
          task_generation = task_generation.to_s
          raise StoreError, "controller task generation is required" if task_generation.empty?

          existing = read
          if existing && existing.values_at("task_generation", "blocked_generation", "blocked_digest") ==
             [ task_generation, generation, digest ]
            return existing
          end
          current_epoch = if existing && existing.fetch("task_generation") == task_generation
            existing.fetch("epoch")
          else
            0
          end
          unless pointer_epoch == current_epoch
            raise StoreError, "blocked recovery epoch is stale"
          end

          document = {
            "schema" => SCHEMA,
            "schema_version" => VERSION,
            "task" => @task.slug.to_s,
            "project" => @project,
            "task_generation" => task_generation,
            "epoch" => current_epoch + 1,
            "blocked_generation" => generation,
            "blocked_digest" => digest,
            "advanced_at" => iso_time(@clock.call)
          }
          Hive::AtomicFile.write(path, JSON.generate(document) << "\n", mode: 0o600)
          read
        rescue ArgumentError, TypeError, KeyError => e
          raise StoreError, "outcome-evidence recovery is invalid: #{e.message}"
        end

        private

        def path
          File.join(@task.folder, "outcome-evidence", "recovery.json")
        end

        def read
          source = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            raise StoreError, "outcome-evidence recovery must be a regular file" unless file.stat.file?

            value = file.read(MAX_BYTES + 1)
            raise StoreError, "outcome-evidence recovery is oversized" if value.bytesize > MAX_BYTES
            value
          end
          value = JSON.parse(
            source, object_class: Document::StrictHash, allow_duplicate_key: true
          )
          expected = %w[
            advanced_at blocked_digest blocked_generation epoch project schema
            schema_version task task_generation
          ]
          unless value.is_a?(Hash) && value.keys.sort == expected &&
                 value["schema"] == SCHEMA && value["schema_version"] == VERSION &&
                 value["task"] == @task.slug.to_s && value["project"] == @project &&
                 value["task_generation"].is_a?(String) && !value["task_generation"].empty? &&
                 value["epoch"].is_a?(Integer) && value["epoch"].positive?
            raise StoreError, "outcome-evidence recovery document is malformed"
          end
          valid_digest!(value.fetch("blocked_generation"), "blocked generation")
          valid_digest!(value.fetch("blocked_digest"), "blocked digest")
          Time.iso8601(value.fetch("advanced_at"))
          value
        rescue Errno::ENOENT
          nil
        rescue Errno::ELOOP
          raise StoreError, "outcome-evidence recovery must not be a symlink"
        rescue JSON::ParserError, ArgumentError, KeyError => e
          raise StoreError, "outcome-evidence recovery document is malformed: #{e.message}"
        end

        def valid_digest!(value, label)
          digest = value.to_s.downcase
          raise StoreError, "#{label} is invalid" unless digest.match?(Proof::DIGEST)

          digest
        end

        def iso_time(value)
          value.respond_to?(:utc) ? value.utc.iso8601(6) : Time.parse(value.to_s).utc.iso8601(6)
        end
      end
    end
  end
end
