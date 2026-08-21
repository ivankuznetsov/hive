require "hive/attempts/generation"
require "hive/config"
require "hive/modules/event_ledger"
require "hive/refactor_patrol/pr_manifest"

module Hive
  module Modules
    # Producer-side persistence used by commands and existing daemon
    # reconcilers. It intentionally does not execute hooks; the daemon drains
    # the strict ledger and remains the sole autonomous dispatcher.
    class EventPublisher
      def initialize(ledger_factory: nil, clock: -> { Time.now.utc })
        @ledger_factory = ledger_factory || lambda do |entry|
          EventLedger.new(root: File.join(entry.fetch("hive_state_path"), "module-runtime"))
        end
        @clock = clock
      end

      def project_registered(entry)
        ledger(entry).record(
          project_id: entry.fetch("project_id"), project: entry.fetch("name"),
          event_name: "project.registered", occurred_at: entry.fetch("registered_at"),
          source: { "type" => "project_registry", "id" => entry.fetch("registration_id") },
          idempotency_key: "project-registered:#{entry.fetch('registration_id')}",
          payload: { "path" => entry.fetch("path") }, recorded_at: @clock.call
        )
      end

      def task_completed(task)
        entry = project_entry(task.project_name, task.project_root)
        token = Hive::Attempts::Generation.artifact_token(task)
        task_id = task.id || task.slug
        ledger(entry).record(
          project_id: entry.fetch("project_id"), project: entry.fetch("name"),
          event_name: "task.completed", occurred_at: File.mtime(task.state_file).utc,
          source: { "type" => "task", "id" => task_id.to_s },
          idempotency_key: "task:#{task_id}:#{token}:completed",
          payload: {
            "task_id" => task.id, "slug" => task.slug, "workflow" => task.workflow.id.to_s,
            "terminal_stage" => task.workflow.stages.last.dir, "task_generation" => token
          },
          recorded_at: @clock.call
        )
      end

      def pull_request_merged(entry, manifest)
        manifest = Hive::RefactorPatrol::PrManifest.validate!(manifest)
        source = manifest.fetch("source")
        post_merge = manifest.fetch("schema_version") == Hive::RefactorPatrol::PrManifest::SCHEMA_VERSION
        idempotency_key = "pull-request:#{source.fetch('repository')}:#{source.fetch('number')}:#{source.fetch('merge_sha')}"
        idempotency_key = "#{idempotency_key}:#{manifest.fetch('job_id')}" if post_merge
        payload = {
          "repository" => source.fetch("repository"), "number" => source.fetch("number"),
          "merge_commit" => source.fetch("merge_sha"),
          "manifest_digest" => manifest.fetch("manifest_checksum"),
          "job_id" => manifest.fetch("job_id")
        }
        payload["post_merge"] = post_merge_event_projection(manifest) if post_merge
        ledger(entry).record(
          project_id: entry.fetch("project_id"), project: entry.fetch("name"),
          event_name: "pull_request.merged", occurred_at: source.fetch("merged_at"),
          source: {
            "type" => "github_pull_request",
            "id" => "#{source.fetch('repository')}##{source.fetch('number')}"
          },
          idempotency_key: idempotency_key, payload: payload,
          recorded_at: @clock.call
        )
      end

      private

      # The immutable manifest remains the exact provenance authority. Events
      # carry every merge identity plus a digest/count for its bounded path
      # mapping so split batches have distinct, inspectable delivery without
      # copying up to 512 long paths into EventLedger's 64 KiB envelope.
      def post_merge_event_projection(manifest)
        classification = manifest.fetch("classification")
        provenance = manifest.fetch("provenance")
        merges = provenance.fetch("merges")
        {
          "lane" => manifest.fetch("lane"),
          "classification" => classification.slice(
            "occurrence_id", "snapshot_digest", "changed_paths_digest",
            "decision", "classified_at", "model_receipt"
          ),
          "provenance_digest" => Hive::RefactorPatrol::PrManifest.checksum(provenance),
          "path_count" => merges.sum { |merge| merge.fetch("path_mappings").size },
          "merges" => merges.map do |merge|
            merge.slice(
              "repository", "number", "merge_sha", "merged_at",
              "classification_occurrence_id"
            )
          end
        }
      end

      def ledger(entry) = @ledger_factory.call(entry)

      def project_entry(name, root)
        entry = Hive::Config.registered_projects.find do |candidate|
          candidate.fetch("name") == name.to_s && candidate.fetch("path") == File.expand_path(root)
        end
        raise Hive::ConfigError, "module event project registration is unavailable" unless entry
        unless entry["project_id"]
          raise Hive::ConfigError, "module event project identity is unavailable"
        end
        entry
      end
    end
  end
end
