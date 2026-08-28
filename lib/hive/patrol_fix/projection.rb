require "hive/patrol_fix"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/receipt_store"
require "json"
require "time"

module Hive
  module PatrolFix
    class Projection
      SCHEMA = "hive-patrol-fix-projection".freeze
      SCHEMA_VERSION = 1
      MAX_DIAGNOSTIC_BYTES = 512
      STAGE_DIRS = %w[1-inbox 2-fix 3-validate 4-review 5-publish 6-done].freeze # not-a-stage-ref: Patrol Fix workflow stages
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
        last_decision = receipts.reverse.find { |receipt| receipt["kind"] == "decision" }
        validation = current.reverse.find { |receipt| receipt["kind"] == "validation" }
        if validation.nil?
          carried = current.reverse.find do |receipt|
            receipt["kind"] == "reopen" && %w[review publish].include?(receipt["stage"])
          end
          validation_id = Array(carried&.dig("payload", "carried_receipts"))[1]
          validation = receipts.find { |receipt| receipt["receipt_id"] == validation_id }
        end
        fix = current.reverse.find { |receipt| receipt["kind"] == "fix" }
        publication = current.reverse.find { |receipt| receipt["kind"] == "publication" }
        publication_block = current.reverse.find do |receipt|
          receipt["kind"] == "publication_block" && receipt["stage"] == "publish"
        end
        outcome = parked_outcome(decision) || publication_block_outcome(publication_block)
        done = stage == "6-done" # not-a-stage-ref: Patrol Fix workflow stage
        closure = done && publication.nil? && valid_evidence_closure?
        missing_terminal_authority = done && publication.nil? && !closure
        state = missing_terminal_authority ? "invalid" : "current"
        diagnostic = if missing_terminal_authority
          { "summary" => "Patrol-fix done requires an exact current pull-request receipt or valid evidence-closure receipt." }
        elsif publication_block
          {
            "code" => publication_block.dig("payload", "code"),
            "summary" => publication_block.dig("payload", "summary")
          }
        elsif !closure
          publication_diagnostic
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
          "review" => last_decision && last_decision["stage"] == "review" ? last_decision.fetch("payload") : nil,
          "publication" => publication&.fetch("payload", nil),
          "timing" => timing_projection(receipts, current, outcome),
          "archived" => done && state == "current",
          "diagnostic" => diagnostic,
          "action" => action_for(
            state: state, done: done, outcome: outcome,
            decision: decision, fix: fix, validation: validation,
            publication: publication
          )
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

      def publication_block_outcome(receipt)
        return unless receipt

        {
          "kind" => "publication_blocked",
          "receipt_id" => receipt.fetch("receipt_id"),
          "rationale" => receipt.dig("payload", "summary"),
          "blocker_owner" => receipt.dig("payload", "owner")
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

      def timing_projection(receipts, current, outcome)
        starts = receipts.map { |receipt| receipt.fetch("recorded_at") }
        parked_seconds = 0
        parked_since = nil
        parked = {}
        receipts.each do |receipt|
          if (receipt["kind"] == "decision" &&
              PARKED_ROUTES.include?(receipt.dig("payload", "route"))) ||
             receipt["kind"] == "publication_block"
            parked[receipt.fetch("receipt_id")] = receipt.fetch("recorded_at")
          elsif receipt["kind"] == "reopen"
            opened = parked.delete(receipt.dig("payload", "outcome_receipt_id"))
            parked_seconds += elapsed_seconds(opened, receipt.fetch("recorded_at")) if opened
          end
        end
        if outcome
          active = current.find { |receipt| receipt["receipt_id"] == outcome["receipt_id"] }
          parked_since = active&.fetch("recorded_at", nil)
        end
        {
          "started_at" => starts.min,
          "stage_started_at" => stage_started_at(current),
          "parked_seconds" => parked_seconds,
          "parked_since" => parked_since,
          "rework_count" => receipts.count do |receipt|
            (receipt["kind"] == "decision" &&
              receipt.dig("payload", "route") == "rework") ||
              (receipt["kind"] == "reopen" &&
                receipt.dig("payload", "operator") == "operator:publication_policy")
          end
        }
      end

      def stage_started_at(receipts)
        boundary = case stage
        when "2-fix" then receipts.reverse.find { |receipt| receipt["kind"] == "decision" && receipt["stage"] == "inbox" }
        when "3-validate" then receipts.reverse.find { |receipt| receipt["kind"] == "fix" }
        when "4-review" then receipts.reverse.find { |receipt| receipt["kind"] == "validation" } # not-a-stage-ref: Patrol Fix workflow stage
        when "5-publish" then receipts.reverse.find { |receipt| receipt["kind"] == "decision" && receipt["stage"] == "review" }
        when "6-done" then receipts.reverse.find { |receipt| receipt["kind"] == "publication" } # not-a-stage-ref: Patrol Fix workflow stage
        end
        boundary&.fetch("recorded_at", nil)
      end

      def elapsed_seconds(started_at, finished_at)
        [ (Time.iso8601(finished_at) - Time.iso8601(started_at)).to_i, 0 ].max
      end

      def action_for(state:, done:, outcome:, decision:, fix:, validation:, publication:)
        return action("invalid", runnable: false) if state == "invalid"
        return action("done", runnable: false) if done
        return action("parked", runnable: false) if outcome
        ready = case stage
        when "1-inbox" then decision&.dig("payload", "route") == "fix" # not-a-stage-ref: Patrol Fix workflow stage
        when "2-fix" then !fix.nil?
        when "3-validate" then !validation.nil?
        when "4-review" then decision&.dig("payload", "route") == "publish" # not-a-stage-ref: Patrol Fix workflow stage
        when "5-publish" then !publication.nil?
        else false
        end
        return action("advance", runnable: true) if ready

        action("ready", runnable: true)
      end

      def action(kind, runnable:) = { "kind" => kind, "runnable" => runnable }

      def stage_name
        stage.split("-", 2).last
      end

      def valid_evidence_closure?
        require "hive/task"
        require "hive/task_closure"
        task = Hive::Task.new(task_folder)
        Hive::TaskClosure.read(task, quarantine: false).valid?
      rescue Hive::Error, SystemCallError, IOError
        false
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
            "timing" => {
              "started_at" => nil, "stage_started_at" => nil,
              "parked_seconds" => 0, "parked_since" => nil, "rework_count" => 0
            },
            "archived" => false, "diagnostic" => { "summary" => summary },
            "action" => { "kind" => "invalid", "runnable" => false }
          }
        )
      end

      def publication_diagnostic
        path = File.join(task_folder, "patrol-fix-publication-diagnostic.json")
        return unless File.exist?(path) || File.symlink?(path)

        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        bytes = File.open(path, flags) do |file|
          raise ReceiptStore::InvalidReceipt, "publication diagnostic must be a regular file" unless
            file.stat.file? && file.stat.nlink == 1
          file.read(4_097).to_s
        end
        raise ReceiptStore::InvalidReceipt, "publication diagnostic is oversized" if bytes.bytesize > 4_096
        document = JSON.parse(bytes)
        fields = %w[schema schema_version code summary recorded_at]
        unless document.is_a?(Hash) && document.keys.sort == fields.sort &&
               document["schema"] == "hive-patrol-fix-publication-diagnostic" &&
               document["schema_version"] == 1 && document["code"] == "cleanup_failed" &&
               document["summary"].is_a?(String) && document["summary"].bytesize <= MAX_DIAGNOSTIC_BYTES
          raise ReceiptStore::InvalidReceipt, "publication diagnostic is invalid"
        end
        Time.iso8601(document.fetch("recorded_at"))
        { "code" => document.fetch("code"), "summary" => document.fetch("summary") }
      rescue SystemCallError, IOError, JSON::ParserError, ArgumentError => e
        raise ReceiptStore::InvalidReceipt, "publication diagnostic is invalid: #{e.class}"
      end
    end
  end
end
