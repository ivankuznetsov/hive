require "digest"
require "json"
require "securerandom"
require "yaml"
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
      #
      # meta.yml's `depends_on` is excluded too. It is scheduling metadata
      # that admission gates on its own, and when plan.md declares a
      # dependency admission forces meta.yml to match the reviewed plan
      # exactly. Including it meant that adopting a revised plan's dependency
      # at promotion (or an operator copying it by hand) staled the review it
      # completed and restarted the whole critique cycle.
      def task_generation(task)
        generation_digest(task, dependency_free_meta_digest(meta_bytes(task)))
      end

      # The pre-exclusion formula: a digest of the raw meta.yml bytes. Reviews
      # recorded before the change carry it, and stay current while meta.yml
      # is byte-identical.
      def legacy_task_generation(task)
        generation_digest(task, Digest::SHA256.hexdigest(meta_bytes(task)))
      end

      def task_generation_current?(task, recorded)
        recorded = recorded.to_s
        recorded == task_generation(task).to_s || recorded == legacy_task_generation(task).to_s
      end

      def meta_bytes(task)
        meta_path = task.respond_to?(:meta_yml_path) ? task.meta_yml_path : nil
        meta_path && File.file?(meta_path) && !File.symlink?(meta_path) ?
          File.binread(meta_path) : ""
      end

      # Unparseable or non-mapping metadata falls back to its raw bytes, so a
      # corrupt meta.yml still changes the generation.
      def dependency_free_meta_digest(bytes)
        data = YAML.safe_load(bytes)
        return Digest::SHA256.hexdigest(bytes) unless data.is_a?(Hash)

        Hive::CanonicalJSON.digest(data.except("depends_on"))
      rescue Psych::Exception, JSON::GeneratorError
        Digest::SHA256.hexdigest(bytes)
      end

      def generation_digest(task, meta_digest)
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
          "meta_digest" => meta_digest
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
