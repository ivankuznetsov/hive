require "digest"
require "hive/dependency_snapshot"
require "hive/conditions/generation_tracker"
require "hive/markers"
require "hive/paths"
require "hive/task_projection/reader"

module Hive
  module Attempts
    # Stable identity for one task's intended workflow step. The opaque
    # progress token is evidence of the current stage artifact, not a commit
    # count and never by itself proof that the stage succeeded.
    Generation = Data.define(
      :task_id, :project, :task_slug, :intended_stage, :task_locator,
      :progress_token, :task_generation, :ownership_generation, :task_input_epoch
    ) do
      def self.resolve(task:, project:, intended_stage:, progress_token: nil,
                       task_generation: nil, ownership_generation: nil, task_input_epoch: nil,
                       admission_context: nil)
        task_id = task.respond_to?(:id) ? task.id : nil
        slug = task.slug.to_s
        locator = task_id.nil? ? "project:#{project}/slug:#{slug}" : "id:#{task_id}"
        progress = progress_token || artifact_token(
          task, admission_context: admission_context
        )
        derived = ::Digest::SHA256.hexdigest(
          [ "hive-task-generation-v1", locator, intended_stage.to_s, progress ].join("\0")
        )
        supplied = ownership_generation || task_generation
        if supplied && internal_pr_review_applicable?(task) && supplied.to_s != derived
          require "hive/attempts/contracts"
          raise Hive::Attempts::StaleTaskSource,
                "supplied task_generation does not match current internal PR checkout generation"
        end
        generation = supplied || derived
        input_epoch = if task_input_epoch.nil?
          if intended_stage.to_s == "4-execute" # coding-scoped: increment 1 tracks input epochs for coding execute only
            workflow_policy = if task.respond_to?(:workflow)
              task.workflow&.stage_named("execute")&.condition_policy&.to_h || {}
            else
              {}
            end
            Hive::Conditions::GenerationTracker.new.resolve(
              task: task, workflow_policy: workflow_policy
            ).task_generation
          else
            current_task_input_epoch(task)
          end
        else
          Integer(task_input_epoch)
        end
        new(
          task_id: task_id,
          project: project.to_s,
          task_slug: slug,
          intended_stage: intended_stage.to_s,
          task_locator: locator,
          progress_token: progress,
          task_generation: generation,
          ownership_generation: generation,
          task_input_epoch: input_epoch
        )
      end

      def self.artifact_token(task, state_file_content: nil, admission_context: nil)
        if internal_pr_review_applicable?(task)
          require "hive/internal_pr_checkout"
          snapshot = Hive::InternalPrCheckout.read_only_snapshot(task) do |snap|
            compute_artifact_token_bytes(
              task,
              state_file_content: state_file_content,
              admission_context: admission_context,
              checkout_digest: snap.head_transition_digest
            )
          end
          if snapshot.blocked?
            raise Hive::InternalPrCheckout::Error.new(
              snapshot.reason, snapshot.guidance, retryable: snapshot.retryable
            )
          end
          if snapshot.busy?
            raise Hive::ConcurrentRunError, snapshot.guidance
          end
          return snapshot.sampled_value if snapshot.applicable?
        end

        compute_artifact_token_bytes(
          task,
          state_file_content: state_file_content,
          admission_context: admission_context,
          checkout_digest: nil
        )
      rescue SystemCallError, IOError => e
        ::Digest::SHA256.hexdigest("hive-progress-v2\0unreadable\0#{e.class}\0#{task.state_file}")
      end

      def self.compute_artifact_token_bytes(task, state_file_content:, admission_context:, checkout_digest:)
        digest = ::Digest::SHA256.new
        digest << "hive-progress-v2\0"
        digest << task.state_file.to_s
        if !state_file_content.nil?
          digest << state_file_content.to_s
        elsif File.file?(task.state_file)
          File.open(task.state_file, "rb") do |file|
            digest << file.read(64 * 1024) until file.eof?
          end
        else
          digest << "\0missing"
        end
        if task.respond_to?(:project_root) && task.respond_to?(:slug)
          digest << "\0dependency-admission\0"
          fingerprint_options = {}
          if admission_context
            fingerprint_options[:admission_context] = admission_context
          end
          digest << Hive::DependencySnapshot.admission_fingerprint(
            task, **fingerprint_options
          )
        end
        # R12: Legacy implicit generation 1 and initial gen 1 contribute zero
        # bytes and no delimiter, preserving pre-deploy attempt identity.
        if checkout_digest
          digest << "\0internal-pr-checkout\0"
          digest << checkout_digest.to_s
        end
        digest.hexdigest
      end
      private_class_method :compute_artifact_token_bytes

      def self.internal_pr_review_applicable?(task)
        return false unless task && task.respond_to?(:folder) && !task.folder.to_s.empty?

        stage = task.respond_to?(:stage_name) ? task.stage_name.to_s : File.basename(File.dirname(task.folder.to_s))
        return false unless %w[review 6-review].include?(stage)

        require "hive/internal_pr_checkout"
        Hive::InternalPrCheckout.applicable?(task)
      end
      private_class_method :internal_pr_review_applicable?

      def self.current_task_input_epoch(task)
        folder = if task.respond_to?(:folder) && task.folder
          task.folder
        else
          File.dirname(task.state_file)
        end
        workflow = task.respond_to?(:workflow) ? task.workflow : nil
        marker = if workflow.respond_to?(:controller?) && workflow.controller?
          Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
        elsif workflow
          Hive::Markers.current(task.state_file)
        end
        bounded = Hive::TaskProjection::Reader.new(
          task_folder: folder, task: task
        ).read_routine(marker: marker)
        unless bounded.current?
          reason = bounded.diagnostics.first&.fetch("reason", nil) || bounded.state
          raise Hive::TaskProjection::InvalidJournal, "task journal is unavailable (#{reason})"
        end

        Integer(bounded.projection.to_h.dig("identity", "task_generation") || 0)
      rescue ArgumentError, TypeError => e
        raise Hive::TaskProjection::InvalidJournal, e.message
      end
    end
  end
end
