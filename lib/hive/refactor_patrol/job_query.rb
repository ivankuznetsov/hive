require "base64"
require "json"
require "time"
require "hive/refactor_patrol/job_store"

module Hive
  module RefactorPatrol
    # Read-only, versioned projection over the authoritative JobStore. Querying
    # never enqueues, claims, replays, or resumes a job.
    class JobQuery
      SCHEMA = "hive-refactor-patrol-jobs".freeze
      SCHEMA_VERSION = 1
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 100
      PUBLICATION_ATTEMPTS_KEY = "publication_attempts".freeze
      PATCH_RECEIPT_PATTERN = /\Apatch(?:_\d+)?\z/
      SUPERSEDED_PATCH_PATTERN = /\Apatch_superseded_[a-f0-9]{64}\z/

      class UsageError < Hive::Error
        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      class NotFound < Hive::Error
        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def self.normalize_limit(limit)
        return DEFAULT_LIMIT if limit.nil?

        value = if limit.is_a?(Integer)
          limit
        elsif limit.is_a?(String) && limit.match?(/\A[1-9]\d*\z/)
          limit.to_i
        end
        unless value && value.between?(1, MAX_LIMIT)
          raise UsageError, "refactor patrol query --limit must be an integer between 1 and #{MAX_LIMIT}"
        end

        value
      end

      def self.validate_job_id!(job_id)
        id = job_id.to_s
        unless id.match?(Hive::RefactorPatrol::JobStore::ID_PATTERN)
          raise UsageError, "refactor patrol --show requires a valid job id"
        end

        id
      end

      def self.decode_cursor(cursor)
        return nil if cursor.nil?
        if cursor.to_s.bytesize > 512
          raise UsageError, "refactor patrol query --cursor is invalid"
        end

        payload = JSON.parse(Base64.urlsafe_decode64(cursor.to_s))
        unless payload.is_a?(Hash) &&
               payload.keys.sort == %w[after_sequence generation through_sequence] &&
               payload["generation"].to_s.match?(/\A[a-f0-9]{32}\z/) &&
               payload["after_sequence"].is_a?(Integer) &&
               payload["through_sequence"].is_a?(Integer) &&
               payload["after_sequence"].positive? &&
               payload["through_sequence"] >= payload["after_sequence"]
          raise UsageError, "refactor patrol query --cursor is invalid"
        end
        payload
      rescue ArgumentError, JSON::ParserError
        raise UsageError, "refactor patrol query --cursor is invalid"
      end

      def initialize(store)
        @store = store
      end

      def list_envelope(project:, project_root:, limit: nil, cursor: nil)
        page_limit = self.class.normalize_limit(limit)
        cursor_state = self.class.decode_cursor(cursor)
        indexed = @store.job_query_page(limit: page_limit, cursor: cursor_state)
        jobs = indexed.fetch("jobs")
        has_more = indexed.fetch("has_more")
        next_cursor = has_more ? encode_cursor(indexed) : nil

        success_envelope(project, project_root, "list").merge(
          "count" => indexed.fetch("total"),
          "page" => {
            "cursor" => cursor,
            "limit" => page_limit,
            "returned" => jobs.size,
            "total" => indexed.fetch("total"),
            "has_more" => has_more,
            "next_cursor" => next_cursor
          },
          "jobs" => jobs.map { |job| summary(job) }
        )
      rescue Hive::RefactorPatrol::JobQueryIndex::CursorError
        raise UsageError, "refactor patrol query --cursor is invalid"
      end

      def show_envelope(project:, project_root:, job_id:, limit: nil, full: false)
        id = self.class.validate_job_id!(job_id)
        history_limit = full ? nil : self.class.normalize_limit(limit)
        aggregate = @store.read_job(id)
        success_envelope(project, project_root, "show").merge(
          "job" => detail(aggregate, history_limit: history_limit, full: full == true)
        )
      rescue Hive::RefactorPatrol::JobStore::RecordNotFound
        raise NotFound, "refactor patrol job #{job_id.inspect} was not found"
      end

      def self.error_envelope(error, action:)
        Hive::Schemas::ErrorEnvelope.build(
          schema: SCHEMA,
          error: error,
          error_kind: error_kind(error),
          extras: { "action" => action }
        )
      end

      def text(payload)
        if payload.fetch("action") == "list"
          page = payload.fetch("page")
          lines = [
            "hive refactor-patrol jobs: #{payload.fetch('project')} " \
              "count=#{payload.fetch('count')} returned=#{page.fetch('returned')} " \
              "has_more=#{page.fetch('has_more')}"
          ]
          payload.fetch("jobs").each do |job|
            lines << [
              job.fetch("job_id"),
              "state=#{job.fetch('state')}",
              "pr=#{job.dig('source', 'number')}",
              "pending_actions=#{job.dig('counts', 'pending_actions')}",
              "updated=#{job.fetch('updated_at')}"
            ].join(" ")
          end
          lines << "next_cursor=#{page.fetch('next_cursor')}" if page.fetch("has_more")
          return lines.join("\n")
        end

        job = payload.fetch("job")
        history = job.fetch("history")
        [
          "hive refactor-patrol job: #{job.fetch('job_id')}",
          "state=#{job.fetch('state')} complete=#{job.fetch('complete')}",
          "source_pr=#{job.dig('source', 'number')} #{job.dig('source', 'url')}",
          "attempts=#{history.dig('attempts', 'total')} actions=#{job.fetch('actions').size} " \
            "pending_actions=#{job.dig('counts', 'pending_actions')}",
          "history=#{history.fetch('full') ? 'full' : "latest-#{history.fetch('limit')}"} " \
            "truncated=#{history_truncated?(history)}",
          "updated=#{job.fetch('updated_at')}"
        ].join("\n")
      end

      private

      def success_envelope(project, project_root, action)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "ok" => true,
          "action" => action,
          "project" => project.to_s,
          "project_root" => project_root.to_s
        }
      end

      def summary(job)
        {
          "job_id" => job.fetch("job_id"),
          "state" => job.fetch("state"),
          "complete" => job.fetch("complete"),
          "source" => source_summary(job.fetch("source")),
          "analysis_sha" => job.fetch("analysis_sha").to_s,
          "counts" => counts(job),
          "blockers" => blockers(job),
          "created_at" => job.fetch("created_at"),
          "updated_at" => job.fetch("updated_at")
        }
      end

      def detail(job, history_limit:, full:)
        history = history_projection(job, limit: history_limit, full: full)
        summary(job).merge(
          "source" => json_copy(job.fetch("source")),
          "policy" => json_copy(job.fetch("policy")),
          "dispositions" => json_copy(job.fetch("dispositions")),
          "feature_results" => json_copy(job.fetch("feature_results")),
          "review_errors" => json_copy(job.fetch("review_errors")),
          "zero_reason" => job.fetch("zero_reason"),
          "attempts" => history.fetch("attempt_values"),
          "actions" => history.fetch("action_values"),
          "history" => history.fetch("metadata")
        )
      end

      def history_projection(job, limit:, full:)
        attempt_values, attempt_metadata = array_history(job.fetch("attempts"), limit, full)
        action_metadata = []
        action_values = job.fetch("actions").map do |action|
          value = json_copy(action)
          claims, claims_metadata = array_history(Array(value["claims"]), limit, full)
          value["claims"] = claims if value.key?("claims")

          publication_attempts = value.dig("receipts", PUBLICATION_ATTEMPTS_KEY)
          publication_values, publication_metadata = publication_history(
            publication_attempts, value.fetch("receipts"), limit, full
          )
          bound_publication_receipts!(
            value.fetch("receipts"),
            publication_attempts: publication_attempts,
            selected_attempts: publication_values,
            full: full
          )
          if publication_attempts
            value.fetch("receipts")[PUBLICATION_ATTEMPTS_KEY] = publication_values
          end
          action_metadata << {
            "canonical_action_id" => action.fetch("canonical_action_id"),
            "claims" => claims_metadata,
            "publication_attempts" => publication_metadata
          }
          value
        end

        {
          "attempt_values" => attempt_values,
          "action_values" => action_values,
          "metadata" => {
            "full" => full,
            "limit" => limit,
            "attempts" => attempt_metadata,
            "actions" => action_metadata
          }
        }
      end

      def array_history(values, limit, full)
        selected = full ? values : values.last(limit)
        [ json_copy(selected), history_metadata(values.size, selected.size) ]
      end

      def publication_history(attempts, receipts, limit, full)
        values = attempts || {}
        unless values.any?
          total = receipts.keys.count { |key| key.match?(PATCH_RECEIPT_PATTERN) }
          returned = if full
            total
          else
            PublicationAttempt.active_patch_key(receipts) ? 1 : 0
          end
          return [ {}, history_metadata(total, returned) ]
        end

        ordered = values.sort_by do |attempt_id, attempt|
          recorded_at = attempt.dig("descriptor", "recorded_at")
          [ Time.iso8601(recorded_at.to_s).utc, attempt_id ]
        end
        selected = full ? ordered : ordered.last(limit)
        [ json_copy(selected.to_h), history_metadata(ordered.size, selected.size) ]
      end

      def bound_publication_receipts!(receipts, publication_attempts:, selected_attempts:, full:)
        return receipts if full

        namespaced = publication_attempts.is_a?(Hash) && publication_attempts.any?
        retained_patches = if namespaced
          selected_attempts.values.filter_map do |attempt|
            attempt.dig("descriptor", "patch_receipt_key") if attempt.is_a?(Hash)
          end
        else
          [ PublicationAttempt.active_patch_key(receipts) ].compact
        end
        receipts.keys.each do |key|
          if key.match?(PATCH_RECEIPT_PATTERN)
            receipts.delete(key) unless retained_patches.include?(key)
          elsif key.match?(SUPERSEDED_PATCH_PATTERN)
            receipts.delete(key)
          end
        end
        receipts
      end

      def history_metadata(total, returned)
        { "total" => total, "returned" => returned, "truncated" => returned < total }
      end

      def history_truncated?(history)
        history.dig("attempts", "truncated") || history.fetch("actions").any? do |action|
          action.dig("claims", "truncated") ||
            action.dig("publication_attempts", "truncated")
        end
      end

      def counts(job)
        actions = job.fetch("actions")
        {
          "features" => job.fetch("feature_results").size,
          "accepted" => job.dig("dispositions", "accepted").size,
          "flagged" => job.dig("dispositions", "flagged").size,
          "suppressed" => job.dig("dispositions", "suppressed").size,
          "review_errors" => job.fetch("review_errors").size,
          "actions" => actions.size,
          "pending_actions" => actions.count { |action| action.fetch("terminal") == false }
        }
      end

      def blockers(job)
        lifecycle = []
        attempt = job.fetch("attempts").last
        if job.fetch("complete") == false && attempt &&
          %w[blocked released].include?(attempt["state"])
          scope = case attempt["kind"]
          when "action_block"
            if %w[blocked classified].include?(job.fetch("state")) &&
               !action_block_superseded?(job, attempt)
              "action"
            end
          when "discovery_block", "discovery_claim"
            "discovery" if job.fetch("state") == "blocked"
          end
          blocker = {
            "scope" => scope,
            "reason" => first_string(attempt["reason"], attempt["outcome"])
          }
          next_eligible_at = first_string(attempt["next_eligible_at"])
          blocker["next_eligible_at"] = next_eligible_at if next_eligible_at
          lifecycle << blocker if scope
        end
        actions = job.fetch("actions").filter_map do |action|
          next if action.fetch("terminal")

          claim = Array(action["claims"]).last
          reason = if claim&.fetch("state", nil) == "released"
            first_string(claim["outcome"], action["outcome"])
          elsif claim.nil? && action["outcome"] == "authority_revoked"
            action["outcome"]
          end
          next unless reason

          {
            "scope" => "action",
            "canonical_action_id" => action.fetch("canonical_action_id"),
            "reason" => reason,
            "next_eligible_at" => claim && first_string(claim["next_eligible_at"])
          }.compact
        end
        lifecycle + actions
      end

      def action_block_superseded?(job, attempt)
        generation_snapshot = attempt["action_claim_generations"]
        if generation_snapshot.is_a?(Hash) && generation_snapshot.all? do |action_id, generation|
          action_id.is_a?(String) && generation.is_a?(Integer) && generation >= 0
        end
          return job.fetch("actions").any? do |action|
            latest = Array(action["claims"]).filter_map { |claim| claim["generation"] }.max.to_i
            latest > generation_snapshot.fetch(action.fetch("canonical_action_id"), 0)
          end
        end

        finished_at = attempt["finished_at"]
        return false if finished_at.to_s.empty?

        blocked_at = Time.iso8601(finished_at.to_s)
        job.fetch("actions").any? do |action|
          Array(action["claims"]).any? do |claim|
            claimed_at = claim["claimed_at"]
            claimed_at && Time.iso8601(claimed_at.to_s) > blocked_at
          end
        end
      rescue ArgumentError
        false
      end

      def first_string(*values)
        values.find { |value| value.is_a?(String) }
      end

      def source_summary(source)
        json_copy(
          source.slice(
            "url", "number", "repository", "registration", "base_branch",
            "merge_sha", "merged_at"
          )
        )
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def encode_cursor(page)
        Base64.urlsafe_encode64(
          JSON.generate(
            "generation" => page.fetch("generation"),
            "after_sequence" => page.fetch("next_after_sequence"),
            "through_sequence" => page.fetch("through_sequence")
          ),
          padding: false
        )
      end

      def self.error_kind(error)
        case error
        when NotFound then "not_found"
        when UsageError then "usage"
        when Hive::ConfigError then "config"
        else "error"
        end
      end
    end
  end
end
