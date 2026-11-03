require "hive/attempts/generation"
require "hive/attempts/record"
require "hive/markers"

module Hive
  module Attempts
    # Task-local terminal evidence. Neither a baseline nor a valid WAITING
    # document proves that a stage accepted an agent result.
    module FailedEdit
      # Supervised commands use the existing dispatch request/result rows as
      # custody. Their owner records launch identity before spawn and terminal
      # outcome after wait; an abandoned claim has no terminal failure evidence.
      SupervisedRecord = Data.define(:launch, :receipt, :state) do
        def [](key) = launch["source_binding"][key] || (key == "provider" ? "unknown" : nil)
        def attempt_id = self["attempt_id"]
        def task_generation = self["task_generation"]
        def ownership_generation = self["ownership_generation"]
        def task_input_epoch = self["task_input_epoch"]
        def checkpoint
          { "edit_resume_task_binding" => launch["task_binding"],
            "edit_resume_input_binding" => launch["input_binding"] }
        end
        def outcome = receipt && receipt["outcome"]
        def live? = state != "terminal"
      end

      module_function

      def task_binding(generation)
        {
          "project" => generation.project, "task_id" => generation.task_id.to_s,
          "intended_stage" => generation.intended_stage,
          "task_locator" => generation.task_locator
        }
      end

      def input_binding(generation)
        { "task_input_epoch" => generation.task_input_epoch,
          "progress_token" => generation.progress_token }
      end

      def source_binding(record)
        {
          "project" => record["project"], "task_id" => record["task_id"].to_s,
          "intended_stage" => record["intended_stage"],
          "task_locator" => "id:#{record['task_id']}",
          "request_id" => record["request_id"], "attempt_id" => record.attempt_id,
          "task_generation" => record.task_generation,
          "ownership_generation" => record.ownership_generation,
          "task_input_epoch" => record.task_input_epoch,
          "progress_token" => record["progress_token"]
        }
      end

      def accepted?(record)
        record.state == "terminal" &&
          (record.outcome == "succeeded" ||
           record.receipt.dig("final_checkpoint", "stage_result", "accepted") == true)
      end

      def matches_task?(record, binding)
        source_binding(record).slice(*binding.keys) == binding
      end

      def valid_source?(record, evidence)
        source = evidence.fetch("source_binding")
        return false unless source_binding(record) == source && record.state == "terminal"
        receipt = record.receipt
        return false unless [Record::LEGACY_RECEIPT_VERSION, Record::RECEIPT_VERSION].include?(receipt["receipt_version"])
        return false if receipt["receipt_version"] < evidence.fetch("source_receipt_version")
        version_key = record.is_a?(SupervisedRecord) ? "dispatch_revision" : "terminal_lease_version"
        source_version_key = record.is_a?(SupervisedRecord) ? "source_dispatch_revision" : "source_terminal_lease_version"
        version = receipt[version_key]
        expected = evidence[source_version_key]
        return false unless version.is_a?(Integer) && expected.is_a?(Integer) && version >= expected
        return false if accepted?(record)

        record.outcome == "failed" && receipt["exit_status"].to_i != 0 &&
          receipt.dig("final_checkpoint", "stage_result", "handled") != true
      end

      def observe(task:, generation:, records:)
        binding = task_binding(generation)
        return nil if binding["task_id"].empty?
        marker = Hive::Markers.current(task.state_file)
        return nil unless marker.name == :waiting || marker.none?
        bound = records.select { |record| matches_task?(record, binding) }
        return nil if bound.any?(&:live?)
        candidates = bound.filter_map do |record|
          next unless record.state == "terminal" && record.outcome == "failed"
          launch_bound = record.checkpoint["edit_resume_task_binding"] == binding &&
            record.checkpoint["edit_resume_input_binding"] == {
              "task_input_epoch" => record.task_input_epoch, "progress_token" => record["progress_token"]
            }
          unchanged_input = record.task_generation == generation.task_generation &&
            record.ownership_generation == generation.ownership_generation &&
            record.task_input_epoch == generation.task_input_epoch &&
            record["progress_token"] == generation.progress_token
          next unless launch_bound || unchanged_input
          receipt = record.receipt
          evidence = {
            "task_binding" => binding, "source_binding" => source_binding(record),
            "input_binding" => input_binding(generation),
            "source_receipt_version" => receipt.fetch("receipt_version"),
            "failed_at" => receipt.fetch("ended_at"),
            "reason" => "edit_resume_dispatch_failed", "provider" => record["provider"],
            "status_code" => receipt["exit_status"].to_s
          }
          if record.is_a?(SupervisedRecord)
            evidence["source_dispatch_revision"] = receipt.fetch("dispatch_revision")
          else
            evidence["source_terminal_lease_version"] = receipt.fetch("terminal_lease_version")
          end
          provider_failure = receipt["failure"] || receipt["provider_evidence"]
          if provider_failure.is_a?(Hash)
            if %w[account_quota exhausted_credits].include?(provider_failure["failure_class"])
              evidence["reason"] = "limits_reached"
            end
            %w[reason provider status_code message].each do |key|
              value = provider_failure[key]
              evidence[key] = value.to_s[0, 512] unless value.nil? || value.to_s.empty?
            end
          end
          next unless valid_source?(record, evidence)
          next if bound.any? do |other|
            other.state == "terminal" && other.attempt_id != record.attempt_id &&
              other.receipt.dig("final_checkpoint", "edit_resume_source_binding") == evidence["source_binding"]
          end
          # Only a proven successor defeats this source. Lease counters of
          # independent attempts have no ordering relationship.
          next if bound.any? do |other|
            accepted?(other) && (other.attempt_id == record.attempt_id ||
              other.receipt.dig("final_checkpoint", "edit_resume_source_binding") == evidence["source_binding"])
          end
          evidence
        end
        # Ambiguous historical failure chains need operator attribution.
        candidates.one? ? candidates.first : nil
      end
    end
  end
end
