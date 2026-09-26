module Hive
  module Daemon
    QuiescenceResult = Data.define(
      :status, :paused, :reason, :phase, :admission_open, :generation,
      :lifecycle_revision, :interrupted_attempt_ids, :remaining,
      :checkpoint, :proof, :capability, :details
    ) do
      def to_h
        {
          "status" => status, "paused" => paused, "reason" => reason,
          "phase" => phase, "admission_open" => admission_open,
          "generation" => generation, "lifecycle_revision" => lifecycle_revision,
          "interrupted_attempt_ids" => interrupted_attempt_ids,
          "remaining" => remaining, "checkpoint" => checkpoint,
          "proof" => proof, "capability" => capability&.to_h,
          "details" => details
        }
      end
    end

    ResumeResult = Data.define(
      :status, :resumed, :reason, :phase, :admission_open, :admission_reopened,
      :generation, :lifecycle_revision, :reconciled_attempt_ids,
      :remaining, :services, :details
    ) do
      def to_h
        {
          "status" => status, "resumed" => resumed, "reason" => reason,
          "phase" => phase, "admission_open" => admission_open,
          "admission_reopened" => admission_reopened, "generation" => generation,
          "lifecycle_revision" => lifecycle_revision,
          "reconciled_attempt_ids" => reconciled_attempt_ids,
          "remaining" => remaining, "services" => services, "details" => details
        }
      end
    end

    module LifecycleResultBuilder
      module_function

      def quiescence(**attributes) = QuiescenceResult.new(**attributes)
      def resume(**attributes) = ResumeResult.new(**attributes)
    end
  end
end
