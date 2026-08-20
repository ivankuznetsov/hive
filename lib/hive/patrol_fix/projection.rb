require "hive/patrol_fix"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/receipt_store"

module Hive
  module PatrolFix
    class Projection
      SCHEMA = "hive-patrol-fix-projection".freeze
      SCHEMA_VERSION = 1
      MAX_DIAGNOSTIC_BYTES = 512
      STAGE_DIRS = %w[1-inbox 2-fix 3-validate 4-review 5-publish 6-done].freeze
      PARKED_ROUTES = %w[reject blocked escalate].freeze

      attr_reader :task_folder, :stage

      def initialize(task_folder:, stage:)
        @task_folder = File.expand_path(task_folder)
        @stage = stage.to_s
      end

      def to_h
        raise TaskManifest::InvalidManifest, "unknown patrol-fix stage #{stage.inspect}" unless STAGE_DIRS.include?(stage)

        manifest = TaskManifest.new(task_folder: task_folder).read
        receipts = ReceiptStore.new(task_folder: task_folder).read_all
        project(manifest, receipts)
      rescue TaskManifest::InvalidManifest, ReceiptStore::InvalidReceipt, KeyError, TypeError => e
        invalid_projection(e.message)
      end

      private

      def project(manifest, receipts)
        current = receipts.select { |receipt| current_receipt?(receipt, manifest) }
        decision = current_decision(current)
        last_decision = current.reverse.find { |receipt| receipt["kind"] == "decision" }
        validation = current.reverse.find { |receipt| receipt["kind"] == "validation" }
        publication = current.reverse.find { |receipt| receipt["kind"] == "publication" }
        outcome = parked_outcome(decision)
        done = stage == "6-done"
        missing_publication = done && publication.nil?
        state = missing_publication ? "invalid" : "current"
        diagnostic = if missing_publication
          { "summary" => "Patrol-fix done requires an exact current pull-request receipt." }
        end

        data = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "state" => state,
          "stage" => stage,
          "task_generation" => manifest.dig("task", "generation"),
          "evidence_revision" => manifest.fetch("evidence_revision"),
          "sources" => manifest.fetch("sources"),
          "aliases" => manifest.fetch("aliases"),
          "issues" => manifest.dig("relations", "issues"),
          "successor" => manifest.dig("relations", "successor"),
          "decision" => decision_projection(last_decision),
          "outcome" => outcome,
          "blocker_owner" => outcome&.fetch("blocker_owner", nil),
          "validation" => validation&.fetch("payload", nil),
          "review" => decision && decision["stage"] == "review" ? decision.fetch("payload") : nil,
          "publication" => publication&.fetch("payload", nil),
          "archived" => done && publication && state == "current" ? true : false,
          "diagnostic" => diagnostic,
          "action" => action_for(state: state, done: done, outcome: outcome)
        }
        PatrolFix.deep_freeze(data)
      end

      def current_receipt?(receipt, manifest)
        receipt.dig("task", "slug") == manifest.dig("task", "slug") &&
          receipt.dig("task", "generation") == manifest.dig("task", "generation") &&
          receipt.fetch("evidence_revision") == manifest.fetch("evidence_revision")
      end

      def current_decision(receipts)
        relevant_stage = stage_name
        decisions = receipts.select do |receipt|
          receipt["stage"] == relevant_stage && %w[decision reopen].include?(receipt["kind"])
        end
        decisions.reduce(nil) do |current, receipt|
          if receipt["kind"] == "decision"
            receipt
          elsif current && receipt.dig("payload", "outcome_receipt_id") == current["receipt_id"]
            nil
          else
            current
          end
        end
      end

      def parked_outcome(decision)
        return nil unless decision
        route = decision.dig("payload", "route")
        return nil unless PARKED_ROUTES.include?(route)

        {
          "kind" => { "reject" => "rejected", "escalate" => "escalated" }.fetch(route, route),
          "receipt_id" => decision.fetch("receipt_id"),
          "rationale" => decision.dig("payload", "rationale"),
          "blocker_owner" => decision.dig("payload", "blocker_owner")
        }
      end

      def decision_projection(receipt)
        return nil unless receipt

        {
          "receipt_id" => receipt.fetch("receipt_id"),
          "stage" => receipt.fetch("stage"),
          "payload" => receipt.fetch("payload")
        }
      end

      def action_for(state:, done:, outcome:)
        return action("invalid", runnable: false, reopen: false) if state == "invalid"
        return action("done", runnable: false, reopen: false) if done
        return action("parked", runnable: false, reopen: true) if outcome

        action("ready", runnable: true, reopen: false)
      end

      def action(kind, runnable:, reopen:)
        {
          "kind" => kind,
          "runnable" => runnable,
          "reopen_eligible" => reopen,
          "generation" => nil
        }.tap do |value|
          value["generation"] = manifest_generation if reopen
        end
      end

      def manifest_generation
        @manifest_generation ||= TaskManifest.new(task_folder: task_folder).read.dig("task", "generation")
      end

      def stage_name
        stage.split("-", 2).last
      end

      def invalid_projection(message)
        summary = message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
        summary = summary.byteslice(0, MAX_DIAGNOSTIC_BYTES).to_s
        PatrolFix.deep_freeze(
          {
            "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
            "state" => "invalid", "stage" => stage, "task_generation" => nil,
            "evidence_revision" => nil, "sources" => [], "aliases" => [], "issues" => [],
            "successor" => nil, "decision" => nil, "outcome" => nil, "blocker_owner" => "hive",
            "validation" => nil, "review" => nil, "publication" => nil,
            "archived" => false, "diagnostic" => { "summary" => summary },
            "action" => {
              "kind" => "invalid", "runnable" => false,
              "reopen_eligible" => false, "generation" => nil
            }
          }
        )
      end
    end
  end
end
