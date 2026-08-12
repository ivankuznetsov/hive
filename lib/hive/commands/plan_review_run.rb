require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/plan_review/automation"
require "hive/task_resolver"

module Hive
  module Commands
    # Internal/publicly inspectable automation verb used by status and the
    # daemon. Unlike `hive plan-review`, it exposes no operator authority.
    class PlanReviewRun
      def initialize(target, project: nil, resolver: nil, automation: nil,
                     committer: nil)
        @target = target
        @project = project
        @resolver = resolver || lambda do
          Hive::TaskResolver.new(
            @target, project_filter: @project, stage_filter: "3-plan"
          ).resolve
        end
        @automation = automation || Hive::PlanReview::Automation.method(:run!)
        @committer = committer || method(:commit!)
      end

      def call
        task = @resolver.call
        projection = @automation.call(task:)
        @committer.call(task, projection)
        puts "hive: plan review #{projection.record.state} for #{task.slug}"
        projection.summary
      end

      private

      def commit!(task, _projection)
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          Hive::GitOps.new(task.project_root).hive_commit(
            stage_name: "#{task.stage_index}-#{task.stage_name}", slug: task.slug,
            action: "run plan review automation"
          )
        end
      end
    end
  end
end
