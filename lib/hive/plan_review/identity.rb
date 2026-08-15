require "digest"
require "json"
require "securerandom"
require "hive/canonical_json"
require "hive/plan_review"

module Hive
  module PlanReview
    module Identity
      module_function

      def logical(task_id:, plan_generation:, policy_fingerprint:, prior_review_id: nil)
        stable_id("pr", task_id:, plan_generation:, policy_fingerprint:, prior_review_id:)
      end

      def attempt(review_id)
        "pra-#{Digest::SHA256.hexdigest([ review_id, SecureRandom.uuid ].join("\0"))}"
      end

      def decision(review_id:, target_fingerprint:, action:, value:)
        stable_id(
          "prd",
          review_id:,
          target_fingerprint:,
          action: action.to_s,
          value: normalize(value)
        )
      end

      def coverage(review_id:, name:, policy_fingerprint:)
        stable_id("prc", review_id:, name: name.to_s, policy_fingerprint:)
      end

      # Stable across a task-folder move. Stage location is deliberately not
      # part of the identity: the exact review selected at 3-plan must still
      # be verifiable after the folder is atomically renamed to 4-execute.
      def task_generation(task)
        meta_path = task.respond_to?(:meta_yml_path) ? task.meta_yml_path : nil
        meta = meta_path && File.file?(meta_path) && !File.symlink?(meta_path) ?
          File.binread(meta_path) : ""
        task_id = if task.respond_to?(:id)
          task.id || task.slug
        else
          task.slug
        end
        workflow_id = task.respond_to?(:workflow) ? task.workflow.id : "unknown"
        Digest::SHA256.hexdigest(JSON.generate(
          "task_id" => task_id.to_s,
          "slug" => task.slug.to_s,
          "workflow" => workflow_id.to_s,
          "meta_digest" => Digest::SHA256.hexdigest(meta)
        ))
      end

      def stable_id(prefix, attributes)
        "#{prefix}-#{Hive::CanonicalJSON.digest(attributes)}"
      end

      def normalize(value)
        Hive::CanonicalJSON.normalize(value)
      end
    end
  end
end
