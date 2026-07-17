require "digest"
require "hive/conditions/generation_tracker"

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
                       task_generation: nil, ownership_generation: nil, task_input_epoch: nil)
        task_id = task.respond_to?(:id) ? task.id : nil
        slug = task.slug.to_s
        locator = task_id.nil? ? "project:#{project}/slug:#{slug}" : "id:#{task_id}"
        progress = progress_token || artifact_token(task)
        generation = ownership_generation || task_generation || ::Digest::SHA256.hexdigest(
          [ "hive-task-generation-v1", locator, intended_stage.to_s, progress ].join("\0")
        )
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
            0
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

      def self.artifact_token(task)
        digest = ::Digest::SHA256.new
        digest << "hive-progress-v1\0"
        digest << task.state_file.to_s
        if File.file?(task.state_file)
          File.open(task.state_file, "rb") do |file|
            digest << file.read(64 * 1024) until file.eof?
          end
        else
          digest << "\0missing"
        end
        digest.hexdigest
      rescue SystemCallError, IOError => e
        ::Digest::SHA256.hexdigest("hive-progress-v1\0unreadable\0#{e.class}\0#{task.state_file}")
      end
    end
  end
end
