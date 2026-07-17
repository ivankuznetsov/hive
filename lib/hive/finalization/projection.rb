require "hive/finalization/event"

module Hive
  module Finalization
    module Projection
      module_function

      def project(records:)
        data = empty_projection
        Array(records).each do |record|
          next unless Hive::Finalization::Event.finalization?(record)

          fold!(data, record)
        end
        data["safe_action"] = safe_action(data)
        deep_copy(data)
      end

      def empty_projection
        {
          "state" => "unfinalized",
          "task_generation" => 0,
          "finalize_attempt_id" => nil,
          "job_id" => nil,
          "repository" => nil,
          "pr_number" => nil,
          "pr_url" => nil,
          "head_sha" => nil,
          "head_generation" => nil,
          "claim_fence" => nil,
          "updated_at" => nil,
          "blocker" => nil,
          "evidence" => {
            "finalized_event_id" => nil,
            "merge_ready_event_id" => nil,
            "terminal_event_id" => nil,
            "terminal_kind" => nil,
            "merged_at" => nil,
            "archive_ready_event_id" => nil,
            "cleanup_event_id" => nil
          },
          "safe_action" => nil
        }
      end

      def fold!(data, record)
        payload = record.fetch("payload", {})
        type = record.fetch("event_type")
        copy_coordinates!(data, record, payload)
        data["updated_at"] = record["observed_at"] || record["occurred_at"]
        data["claim_fence"] = record.dig("producer", "claim_fence") || data["claim_fence"]

        case type
        when "finalized"
          reset_lifecycle!(data)
          data["state"] = "finalized"
          data["evidence"]["finalized_event_id"] = record["event_id"]
        when "finalize_attempt_adopted"
          data["finalize_attempt_id"] = payload["finalize_attempt_id"]
        when "babysitter_activated", "babysitter_active"
          data["state"] = "babysitter_active"
          data["blocker"] = nil
        when "babysitter_blocked"
          data["state"] = "blocked"
          data["blocker"] = bounded_blocker(payload["blocker"])
        when "head_superseded"
          data["state"] = "babysitter_active"
          data["blocker"] = nil
          data["evidence"]["merge_ready_event_id"] = nil
          clear_terminal!(data)
        when "merge_ready"
          data["state"] = "merge_ready"
          data["blocker"] = nil
          data["evidence"]["merge_ready_event_id"] = record["event_id"]
        when "merged"
          data["state"] = "merged"
          data["blocker"] = nil
          data["evidence"]["terminal_event_id"] = record["event_id"]
          data["evidence"]["terminal_kind"] = "merged"
          data["evidence"]["merged_at"] = payload["merged_at"]
        when "no_pr_approved"
          data["state"] = "approved_no_pr"
          data["blocker"] = nil
          data["evidence"]["terminal_event_id"] = record["event_id"]
          data["evidence"]["terminal_kind"] = payload["outcome"]
        when "finalization_rearmed"
          data["state"] = payload["active"] == false ? "finalized" : "babysitter_active"
          data["blocker"] = nil
          clear_terminal!(data)
          data["evidence"]["archive_ready_event_id"] = nil
        when "archive_ready"
          data["state"] = "archive_ready"
          data["evidence"]["archive_ready_event_id"] = record["event_id"]
        when "cleanup_completed"
          data["evidence"]["cleanup_event_id"] = record["event_id"]
        end
      end

      def copy_coordinates!(data, record, payload)
        data["task_generation"] = record["task_generation"] if record["task_generation"].is_a?(Integer)
        Hive::Finalization::Event::COORDINATES.each do |key|
          data[key] = payload[key] if payload.key?(key)
        end
      end

      def reset_lifecycle!(data)
        data["blocker"] = nil
        data["claim_fence"] = nil
        data["evidence"] = empty_projection.fetch("evidence")
      end

      def clear_terminal!(data)
        data["evidence"]["terminal_event_id"] = nil
        data["evidence"]["terminal_kind"] = nil
        data["evidence"]["merged_at"] = nil
      end

      def bounded_blocker(value)
        return nil unless value.is_a?(Hash)

        {
          "code" => value["code"].to_s[0, 64],
          "needs_human" => value["needs_human"] == true,
          "detail" => value["detail"].to_s.gsub(/\s+/, " ")[0, 300],
          "source" => value["source"].to_s[0, 64]
        }
      end

      def safe_action(data)
        code, label, target, confirmation = case data.fetch("state")
        when "unfinalized"
          [ "rerun_finalize", "Run finalize to establish watching", "task", false ]
        when "finalized"
          [ "retry_babysitter", "Start or repair babysitter", "job", false ]
        when "babysitter_active"
          [ "inspect_pr", "Inspect pull request", "pr", false ]
        when "merge_ready"
          [ "wait_for_merge", "Wait for human or auto-merge", "pr", false ]
        when "blocked"
          if data.dig("blocker", "needs_human")
            [ "confirm_terminal_outcome", "Resolve or confirm terminal outcome", "task", true ]
          else
            [ "retry_babysitter", "Retry babysitter", "job", false ]
          end
        when "merged", "approved_no_pr"
          [ "wait_for_archive", "Wait for archive reconciliation", "task", false ]
        when "archive_ready"
          [ "archive", "Archive task", "task", false ]
        end
        { "code" => code, "label" => label, "target" => target, "confirmation_required" => confirmation }
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, child| [ key, deep_copy(child) ] }
        when Array then value.map { |child| deep_copy(child) }
        else value
        end
      end
    end
  end
end
