require "digest"
require "json"
require "time"
require "hive/daily_digest"
require "hive/gh"
require "hive/task_journal"

module Hive
  module DailyDigest
    # One closed classifier for every authoritative task-journal activity kind.
    # It deliberately emits only a privacy-safe subset of each source record;
    # renderers never receive prompt, answer, error, or arbitrary evidence text.
    module Materiality
      Result = Data.define(:disposition, :value)

      MATRIX = {
        "attempt_admitted" => :noise,
        "context_launch_captured" => :noise,
        "context_selection_reported" => :noise,
        "session_started" => :noise,
        "session_finished" => :conditional_session,
        "usage_observed" => :noise,
        "resource_limit_observed" => :fact,
        "stage_transition" => :fact,
        "question_asked" => :fact,
        "answer_recorded" => :fact,
        "approval_recorded" => :fact,
        "rejection_recorded" => :fact,
        "decision_recorded" => :fact,
        "retry_requested" => :conditional_change,
        "recovery_recorded" => :fact,
        "hold_recorded" => :fact,
        "context_revision" => :noise,
        "commit_observed" => :fact,
        "push_observed" => :fact,
        "pr_observed" => :fact,
        "check_observed" => :fact,
        "review_observed" => :fact,
        "merge_observed" => :fact,
        "operator_action" => :fact,
        "correction" => :fact,
        "activity_gap" => :gap
      }.freeze

      # Producer coverage is deliberately explicit. `instrumented` entries
      # name the durable owner whose source contains the journal kind; legacy
      # vocabulary without a current authoritative owner is declared instead
      # of being mistaken for observed coverage.
      PRODUCER_COVERAGE = {
        "session_finished" => [ "instrumented", "lib/hive/agent_observation.rb" ],
        "resource_limit_observed" => [ "instrumented", "lib/hive/agent_observation.rb" ],
        "stage_transition" => [ "instrumented", "lib/hive/stages/base.rb" ],
        "question_asked" => [ "instrumented", "lib/hive/stages/base.rb" ],
        "answer_recorded" => [ "instrumented", "lib/hive/commands/answer.rb" ],
        "approval_recorded" => [ "instrumented", "lib/hive/commands/approve.rb" ],
        "rejection_recorded" => [ "instrumented", "lib/hive/commands/approve.rb" ],
        "decision_recorded" => [ "instrumented", "lib/hive/commands/decide.rb" ],
        "retry_requested" => [ "instrumented", "lib/hive/recovery/api.rb" ],
        "recovery_recorded" => [ "instrumented", "lib/hive/recovery/api.rb" ],
        "pr_observed" => [ "instrumented", "lib/hive/stages/open_pr.rb" ],
        "check_observed" => [ "instrumented", "lib/hive/task_workspace/publication_activity.rb" ],
        "review_observed" => [ "instrumented", "lib/hive/task_workspace/publication_activity.rb" ],
        "merge_observed" => [ "instrumented", "lib/hive/stages/open_pr.rb" ],
        "activity_gap" => [ "instrumented", "lib/hive/task_activity.rb" ],
        "hold_recorded" => [ "instrumented", "lib/hive/daily_digest/hold_observer.rb" ],
        "commit_observed" => [ "unsupported_legacy", nil ],
        "push_observed" => [ "unsupported_legacy", nil ],
        "operator_action" => [ "unsupported_legacy", nil ],
        "correction" => [ "unsupported_legacy", nil ]
      }.freeze

      DETAIL_KEYS = {
        "stage_transition" => %w[transition marker to_stage],
        "question_asked" => %w[question_id],
        "answer_recorded" => %w[question_id],
        "approval_recorded" => %w[approval decision],
        "rejection_recorded" => %w[decision],
        "decision_recorded" => %w[decision],
        "recovery_recorded" => %w[outcome retry_at],
        "hold_recorded" => %w[hold_kind state provider retry_at],
        "resource_limit_observed" => %w[resource_kind kind unit state provider retry_at],
        "session_finished" => %w[health outcome timed_out provider actual_provider actual_model],
        "commit_observed" => %w[commit_oid branch],
        "push_observed" => %w[commit_oid branch],
        "pr_observed" => %w[pr_number pr_state pr_url commit_oid head_oid draft],
        "check_observed" => %w[pr_number pr_state pr_url draft check_state conclusion commit_oid head_oid],
        "review_observed" => %w[pr_number review_state pr_state pr_url commit_oid head_oid draft],
        "merge_observed" => %w[pr_number merge_state pr_state pr_url commit_oid head_oid merge_oid merged_at],
        "operator_action" => %w[action outcome],
        "correction" => %w[corrected_fact_id correction_kind]
      }.freeze

      LABELS = {
        "stage_transition" => "Task stage changed",
        "question_asked" => "Task needs input",
        "answer_recorded" => "Task input answered",
        "approval_recorded" => "Task approved",
        "rejection_recorded" => "Task rejected",
        "decision_recorded" => "Task decision recorded",
        "recovery_recorded" => "Task recovered",
        "hold_recorded" => "Task hold changed",
        "resource_limit_observed" => "Capacity hold changed",
        "session_finished" => "Task execution failed",
        "commit_observed" => "Commit observed",
        "push_observed" => "Push observed",
        "pr_observed" => "Pull request changed",
        "check_observed" => "Pull request checks changed",
        "review_observed" => "Pull request review changed",
        "merge_observed" => "Pull request merged",
        "operator_action" => "Operator action recorded",
        "correction" => "Historical fact corrected"
      }.freeze

      module_function

      def classify(record, project:, observed_at: nil)
        row = stringify(record)
        return Result.new(disposition: :noise, value: nil) unless row["event_type"] == "activity_recorded"

        payload = stringify(row["payload"] || {})
        kind = payload["activity_kind"].to_s
        policy = MATRIX[kind]
        return Result.new(disposition: :noise, value: nil) unless policy

        policy = :noise if policy == :conditional_session && !failed_session?(payload)
        policy = payload["durable_outcome_changed"] == true ? :fact : :noise if policy == :conditional_change
        case policy
        when :noise then Result.new(disposition: :noise, value: nil)
        when :gap then Result.new(disposition: :gap, value: gap(row, payload, project))
        else
          Result.new(
            disposition: :fact,
            value: fact(row, payload, kind, project, fallback_observed_at: observed_at)
          )
        end
      rescue JSON::GeneratorError, TypeError, ArgumentError
        Result.new(
          disposition: :gap,
          value: invalid_record_gap(record, project, observed_at: observed_at)
        )
      end

      def build_gap(source:, scope:, reason_code:, reason:, observed_at:, freshness_at: nil,
                    project_id: nil, task_slug: nil)
        normalized = {
          "source" => bounded(source, 80, fallback: "unknown"),
          "scope" => bounded(scope, 160, fallback: "global"),
          "reason_code" => bounded(reason_code, 80, fallback: "unavailable"),
          "reason" => bounded(reason, 240, fallback: "source unavailable"),
          "observed_at" => iso_time(observed_at),
          "freshness_at" => freshness_at && iso_time(freshness_at),
          "project_id" => nullable_bounded(project_id, 160),
          "task_slug" => nullable_bounded(task_slug, 128)
        }
        identity = normalized.slice("source", "scope", "reason_code", "project_id", "task_slug")
        normalized["gap_id"] = "gap:#{Digest::SHA256.hexdigest(canonical_json(identity))}"
        normalized
      end

      def creation_fact(receipt)
        row = stringify(receipt)
        {
          "fact_id" => "creation:#{row.fetch('creation_id')}",
          "kind" => "task_created",
          "category" => "progress",
          "summary" => "Task created",
          "project_id" => row.fetch("project_id"),
          "project" => row.fetch("project_name"),
          "task_id" => row["task_id"],
          "task_slug" => row.fetch("task_slug"),
          "stage" => row.fetch("stage"),
          "occurred_at" => row.fetch("created_at"),
          "observed_at" => row.fetch("created_at"),
          "source" => "task_creation_receipt",
          "details" => { "workflow" => row.fetch("workflow") }
        }
      end

      def fact(row, payload, kind, project, fallback_observed_at: nil)
        project = stringify(project)
        event_time = row["occurred_at"]
        event_time = row["observed_at"] || row.dig("provenance", "ingested_at") ||
          fallback_observed_at if event_time.nil? || event_time.to_s.empty?
        occurred_at = iso_time(event_time)
        observed_at = iso_time(row["observed_at"] || row.dig("provenance", "ingested_at") || occurred_at)
        event_id = bounded(row["event_id"], 256, fallback: payload["operation_id"] || kind)
        details = safe_details(kind, payload)
        identity = {
          "event_id" => event_id, "kind" => kind,
          "project_id" => project["project_id"],
          "task" => row["task"], "details" => details
        }
        normalized = {
          "fact_id" => "fact:#{Digest::SHA256.hexdigest(canonical_json(identity))}",
          "kind" => kind,
          "category" => category(kind, payload),
          "summary" => LABELS.fetch(kind, "Task activity changed"),
          "project_id" => bounded(project["project_id"], 160, fallback: "unknown-project"),
          "project" => bounded(project["name"], 160, fallback: "unknown"),
          "task_id" => nullable_bounded(row.dig("task", "id"), 128),
          "task_slug" => nullable_bounded(row.dig("task", "slug"), 128),
          "stage" => nullable_bounded(row["stage"], 80),
          "occurred_at" => occurred_at,
          "observed_at" => observed_at,
          "source" => bounded(row.dig("provenance", "source"), 80, fallback: "task_journal"),
          "details" => details
        }
        pr = pull_request(kind, details)
        normalized["pr"] = pr if pr
        normalized
      end
      private_class_method :fact

      def gap(row, payload, project)
        project = stringify(project)
        build_gap(
          source: row.dig("provenance", "source") || "task_journal",
          scope: payload["scope"] || project["name"] || "project",
          reason_code: payload["reason_code"] || "activity_gap",
          reason: payload["reason"] || row["reason"] || "activity evidence unavailable",
          observed_at: row["observed_at"] || row["occurred_at"],
          freshness_at: payload["freshness_at"],
          project_id: project["project_id"], task_slug: row.dig("task", "slug")
        )
      end
      private_class_method :gap

      def invalid_record_gap(record, project, observed_at: nil)
        row = record.is_a?(Hash) ? stringify(record) : {}
        project = project.is_a?(Hash) ? stringify(project) : {}
        task = row["task"].is_a?(Hash) ? row["task"] : {}
        build_gap(
          source: "task_journal", scope: project["name"] || "project",
          reason_code: "malformed_activity", reason: "activity record could not be normalized",
          observed_at: safe_observation_time(row, observed_at),
          project_id: project["project_id"], task_slug: task["slug"]
        )
      end
      private_class_method :invalid_record_gap

      def safe_observation_time(row, fallback)
        [ fallback, row["observed_at"], row["occurred_at"] ].compact.each do |candidate|
          return iso_time(candidate)
        rescue ArgumentError, TypeError
          next
        end
        iso_time(Time.now.utc)
      end
      private_class_method :safe_observation_time

      def pull_request(kind, details)
        return nil unless %w[pr_observed check_observed review_observed merge_observed].include?(kind)

        parsed = Hive::Gh.parse_pull_request_url(details["pr_url"])
        number = Integer(details["pr_number"], exception: false)
        number ||= parsed && parsed.fetch("number")
        {
          "number" => number,
          "url" => parsed && parsed.fetch("url"),
          "state" => details["pr_state"] || details["merge_state"],
          "draft" => details.key?("draft") ? details["draft"] == true : nil,
          "head_revision" => details["head_oid"] || details["commit_oid"],
          "checks" => details["check_state"] || details["conclusion"],
          "review" => details["review_state"],
          "merged_at" => details["merged_at"]
        }
      end
      private_class_method :pull_request

      def failed_session?(payload)
        %w[failed error timeout timed_out interrupted resource_exhausted].include?(payload["outcome"].to_s) ||
          %w[failed unhealthy].include?(payload["health"].to_s) || payload["timed_out"] == true
      end
      private_class_method :failed_session?

      def category(kind, payload)
        return "failure" if kind == "session_finished"
        return "recovery" if kind == "recovery_recorded"
        return "attention" if %w[question_asked rejection_recorded hold_recorded resource_limit_observed].include?(kind)
        return "completion" if kind == "merge_observed"
        return "completion" if kind == "stage_transition" && %w[completed archived].include?(payload["transition"].to_s)

        "progress"
      end
      private_class_method :category

      def safe_details(kind, payload)
        Array(DETAIL_KEYS[kind]).each_with_object({}) do |key, out|
          value = payload[key]
          next if value.nil?

          out[key] = case value
          when TrueClass, FalseClass, Integer then value
          else bounded(value, 256, fallback: nil)
          end
        end.compact
      end
      private_class_method :safe_details

      def stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, child), out| out[key.to_s] = stringify(child) }
        when Array then value.map { |child| stringify(child) }
        else value
        end
      end
      private_class_method :stringify

      def canonical_json(value)
        JSON.generate(value.is_a?(Hash) ? value.keys.sort.to_h { |key| [ key, value[key] ] } : value)
      end
      private_class_method :canonical_json

      def iso_time(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc.iso8601(6)
      end
      private_class_method :iso_time

      def bounded(value, max, fallback:)
        text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                    .gsub(/[\u0000-\u001f\u007f]/, " ").strip
        text = fallback.to_s if text.empty? && !fallback.nil?
        text.byteslice(0, max).to_s.force_encoding(Encoding::UTF_8).scrub
      end
      private_class_method :bounded

      def nullable_bounded(value, max)
        return nil if value.nil?

        bounded(value, max, fallback: nil)
      end
      private_class_method :nullable_bounded
    end
  end
end
